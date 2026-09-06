#!/usr/bin/env bash
# =============================================================================
#  setup.sh - Server Initialization Suite
#
#  Bootstraps a fresh Debian or Ubuntu machine - Proxmox VM or container, KVM
#  guest, VPS, dedicated box, or a laptop serving as one: system updates, the
#  login account, firewall, fail2ban, performance tuning, Docker, Dokploy, and
#  unattended security updates.
#
#  This file is the framework: options, console output, journal logging, the
#  helpers every component relies on, preflight, and the summary. The
#  components themselves live one per file in setup/<name>.sh. Only the
#  modules for the components that will run are fetched, all of them before
#  any component runs, so a missing or broken module aborts the run while the
#  machine is still untouched.
#
#    curl -fsSL https://lilsnibbi.dev/scripts/setup.sh | sudo bash -s -- [options]
#
#  It deliberately does NOT harden sshd. The only sshd setting it writes is
#  Port, and it generates no keys. Rewriting authentication from an unattended
#  script is how a host ends up unreachable with nobody watching the console.
#
#  Designed to run unattended on first boot. Every step is idempotent and safe
#  to re-run.
# =============================================================================

set -Eeuo pipefail

# The script is started more ways than one - through sudo, from a Proxmox
# 'pct exec', from cloud-init, from a bare root shell - and not all of them put
# the sbin directories on PATH. sshd, ufw, sysctl and swapon all live there.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

SCRIPT_VERSION="3.1.0"
SCRIPT_NAME="Server Initialization Suite"

# Where the component modules come from; setup/<name>.sh is appended. In
# order of precedence: --base=..., the SETUP_BASE environment variable, the
# setup/ directory beside this file when run from a checkout, this default.
SETUP_BASE_DEFAULT="https://lilsnibbi.dev/scripts"
SETUP_BASE="${SETUP_BASE:-}"

# Bumped only when a helper that modules depend on changes incompatibly. Every
# module declares the API it was written against, and a mismatch aborts the run
# before anything is touched rather than failing halfway through.
#
# 2: added ui_allow_list, which the dokploy module calls.
SETUP_API=2

# -----------------------------------------------------------------------------
# Non-interactive environment.
#
# NEEDRESTART_MODE=a stops the "which services should be restarted?" dialog that
# Ubuntu 22.04+ shows during apt upgrades. That dialog is the single most common
# reason an unattended run hangs forever.
# -----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export UCF_FORCE_CONFOLD=1

APT_OPTS=(
  -y
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
)

# -----------------------------------------------------------------------------
# Options (defaults)
# -----------------------------------------------------------------------------
OPT_USERNAME="root"
OPT_SSH_PORT="22"
OPT_PUBKEY=""
OPT_HOSTNAME=""
# UTC by default rather than whatever the image happens to ship. Timestamps
# from a fleet are only comparable if every host agrees on the zone, and a
# server has no reason to prefer a local one. --timezone=keep opts out.
OPT_TIMEZONE="UTC"
OPT_TIMEZONE_SET=0
OPT_UI_ALLOW=""
OPT_UI_PUBLIC=0
OPT_UI_LOCAL=0
OPT_AUTO_REBOOT=""
OPT_EXCLUDE=""
OPT_ONLY=""
OPT_BASE=""
OPT_RESET_FIREWALL=0
OPT_REINSTALL_DOKPLOY=0
OPT_REMOVE_SNAPD=0
OPT_DRY_RUN=0
OPT_VERBOSE=0
OPT_NO_COLOR=0

# -----------------------------------------------------------------------------
# Components, in execution order. "name:description". Each one is implemented
# by setup/<name>.sh, which must define fn_<name>.
# -----------------------------------------------------------------------------
COMPONENTS=(
  "update:Refresh apt indexes and apply every pending upgrade"
  "base:Install base utilities (curl, git, jq, iproute2, ...)"
  "ssh:Create the login account and set the SSH port"
  "firewall:Configure the UFW firewall"
  "fail2ban:Install and pre-configure fail2ban for SSH"
  "hardening:Kernel network hardening, journald limits, root password lock"
  "tuning:Performance tuning: network stack, limits, power, CPU governor"
  "swap:Create a swapfile when RAM is small and no swap exists"
  "docker:Install Docker CE with container log rotation"
  "dokploy:Install the Dokploy PaaS platform"
  "cloudflared:Install the Cloudflare Zero Trust tunnel daemon"
  "bun:Install the Bun JavaScript runtime"
  "unattended:Enable automatic security updates"
  "verify:Check sshd, the firewall and the login account"
)

# -----------------------------------------------------------------------------
# Runtime state
# -----------------------------------------------------------------------------
# No log file is ever written. Everything goes to the systemd journal under
# this tag; LOG_HINT is the command a human types to read it back.
LOG_TAG="server-init"
LOG_HINT="journalctl -t server-init"
LOG_READY=0
APT_UPDATED=0
CURRENT_STEP="startup"
STEP_INDEX=0
STEP_TOTAL=0
TTY=0
START_TIME=$SECONDS

MODULE_DIR=""
declare -a TO_RUN=()
declare -a SKIPPED=()

SSH_USER_HOME=""
SSH_KEY_SOURCE="none"
DOKPLOY_INSTALLED=0

declare -a WARNINGS=()
declare -a STEP_TIMES=()  # "title|seconds", one entry per completed step
STEP_TITLE=""
STEP_T0=0

OS_ID=""
OS_CODENAME=""
OS_VERSION_ID=""
OS_PRETTY=""
ARCH=""
PUBLIC_IP=""

# -----------------------------------------------------------------------------
# Output styling. Colour is disabled when stdout is not a terminal, when
# NO_COLOR is set, or via --no-color.
# -----------------------------------------------------------------------------
NC='' BOLD='' DIM=''
C_TITLE='' C_STEP='' C_OK='' C_WARN='' C_ERR='' C_INFO='' C_MUTED='' C_RULE='' C_BADGE=''

# How many colours the terminal can actually show. Emitting 256-colour codes at
# a 16-colour serial console prints the escape sequence as literal text, which
# is worse than no colour at all.
#
#   3 = 24-bit truecolor   2 = 256 colours   1 = 16 colours   0 = none
color_depth() {
  case "${COLORTERM:-}" in
    truecolor|24bit) printf '3'; return 0 ;;
  esac
  local n
  n="$(tput colors 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=8
  if   [ "$n" -ge 256 ]; then printf '2'
  elif [ "$n" -ge 8 ];   then printf '1'
  else                        printf '0'
  fi
}

# The palette. Roles, not colours: C_TITLE is whatever the eye should land on
# first, C_RULE is whatever should recede into the background. Each tier is a
# deliberate translation of the same eight roles, so the layout reads the same
# on a truecolor terminal and on a 16-colour one.
setup_colors() {
  [ -t 1 ] && TTY=1
  detect_width
  if [ -n "${NO_COLOR:-}" ] || [ "$OPT_NO_COLOR" -eq 1 ] || [ "$TTY" -eq 0 ]; then
    return
  fi

  local depth
  depth="$(color_depth)"
  [ "$depth" = "0" ] && return 0

  NC=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'

  case "$depth" in
    3)
      C_TITLE=$'\033[38;2;241;245;249m'   # soft white - headings, the loudest thing
      C_STEP=$'\033[38;2;34;211;238m'     # cyan       - step badges, product name
      C_INFO=$'\033[38;2;56;189;248m'     # sky        - in-progress, addresses
      C_OK=$'\033[38;2;74;222;128m'       # green      - completed
      C_WARN=$'\033[38;2;251;191;36m'     # amber      - warnings
      C_ERR=$'\033[38;2;248;113;113m'     # rose       - failures
      C_MUTED=$'\033[38;2;148;163;184m'   # slate      - secondary detail
      C_RULE=$'\033[38;2;71;85;105m'      # deep slate - dividers and frames
      # A filled chip: cyan background, near-black text. Legible on a light
      # terminal as well as a dark one, because both halves are set here.
      C_BADGE=$'\033[48;2;34;211;238;38;2;8;20;30;1m'
      ;;
    2)
      C_TITLE=$'\033[38;5;255m'
      C_STEP=$'\033[38;5;45m'
      C_INFO=$'\033[38;5;45m'
      C_OK=$'\033[38;5;78m'
      C_WARN=$'\033[38;5;214m'
      C_ERR=$'\033[38;5;203m'
      C_MUTED=$'\033[38;5;250m'
      C_RULE=$'\033[38;5;60m'
      C_BADGE=$'\033[48;5;45;38;5;16;1m'
      ;;
    *)
      C_TITLE=$'\033[97m'
      C_STEP=$'\033[96m'
      C_INFO=$'\033[96m'
      C_OK=$'\033[92m'
      C_WARN=$'\033[93m'
      C_ERR=$'\033[91m'
      C_MUTED=$'\033[37m'
      C_RULE=$'\033[90m'
      C_BADGE=$'\033[46;30;1m'
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Terminal geometry.
#
# Every transient line the script draws is truncated to TERM_COLS. A line that
# wraps is the reason a spinner turns into hundreds of repeated rows: after a
# wrap, \r returns to the start of the *last* screen row, not the row the line
# began on, so the next frame is appended instead of overwriting.
# -----------------------------------------------------------------------------
TERM_COLS=80
RULE=""

# Repeat the box-drawing dash N times. Built with a counted loop rather than
# string slicing because ${#s} counts bytes under a C locale, and each dash is
# three bytes.
rule_of() {
  local n="$1" i out=""
  for ((i = 0; i < n; i++)); do out+="─"; done
  printf '%s' "$out"
}

# Heavy rule. Reserved for the two bookends of a run - the opening banner and
# the completion bar - so they read as a different weight from the light rules
# that merely separate steps.
rule_heavy() {
  local n="$1" i out=""
  for ((i = 0; i < n; i++)); do out+="━"; done
  printf '%s' "$out"
}

detect_width() {
  local cols=""
  if [ "$TTY" -eq 1 ]; then
    cols="$(tput cols 2>/dev/null || true)"
    [ -n "$cols" ] || cols="$(stty size </dev/tty 2>/dev/null | awk '{print $2}' || true)"
  fi
  [[ "$cols" =~ ^[0-9]+$ ]] || cols="${COLUMNS:-80}"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  # Clamped: narrow terminals still get a usable layout, wide ones do not get a
  # rule stretching halfway across a 4K monitor.
  [ "$cols" -ge 48 ] || cols=48
  [ "$cols" -le 96 ] || cols=96
  TERM_COLS="$cols"
  RULE="$(rule_of $((TERM_COLS - 3)))"
}

# -----------------------------------------------------------------------------
# Logging and console output.
#
# The console (fd 3) and the log are deliberately separate streams: command
# output goes to the systemd journal (fd 4), so a run reads as a list of
# outcomes rather than a wall of apt and docker chatter, and nothing is ever
# written to a file. journald timestamps every line itself.
# -----------------------------------------------------------------------------
strip_ansi() { printf '%s' "$1" | sed -e 's/\x1b\[[0-9;]*m//g'; }

log() {
  [ "$LOG_READY" -eq 1 ] || return 0
  printf '%s\n' "$*" >&4 2>/dev/null || true
}

ui() { printf '%b\n' "$*" >&3; }

say() {
  ui "$*"
  log "[ui] $(strip_ansi "$*")"
}

info()   { say "   ${C_INFO}${BOLD}›${NC} $*"; }
# Wraps, but only when it has to. Several callers pass deliberately indented
# text - a command to copy, say - and running that through the wrapper
# unconditionally would eat the indent it was given for a reason.
detail() {
  local avail=$(( TERM_COLS - 6 ))
  [ "$avail" -ge 24 ] || avail=24
  if [ "$(dwidth "$*")" -le "$avail" ]; then
    say "     ${C_MUTED}$*${NC}"
    return 0
  fi
  log "[ui] $(strip_ansi "$*")"
  local out
  while IFS= read -r out; do
    ui "     ${C_MUTED}${out}${NC}"
  done < <(wrap_text "$avail" "$*")
  return 0
}
ok()     { say "   ${C_OK}${BOLD}✔${NC} ${C_TITLE}$*${NC}"; }

LABEL_W=9

# Columns a string occupies on screen.
#
# ${#var} counts bytes under a C locale and characters under a UTF-8 one, and
# the script cannot rely on which it got. Folding the only two multibyte glyphs
# it puts into measured text down to one byte each makes the count correct
# either way: under UTF-8 the length is unchanged, under C it loses exactly the
# extra bytes.
dwidth() {
  local s="${1//·/.}"
  s="${s//—/-}"
  printf '%s' "${#s}"
}

# Greedy word wrap to a column budget. One wrapped line per output line.
# Always invoked via process substitution, so set -f is confined to the
# subshell; without it a message containing a glob ('*.conf', say) would be
# expanded against the working directory.
wrap_text() {
  set -f
  local width="$1"; shift
  local line="" word
  for word in $*; do
    if [ -z "$line" ]; then
      line="$word"
    elif [ $(( $(dwidth "$line") + 1 + $(dwidth "$word") )) -le "$width" ]; then
      line="$line $word"
    else
      printf '%s\n' "$line"
      line="$word"
    fi
  done
  [ -n "$line" ] && printf '%s\n' "$line"
  return 0
}

# row <label> <value colour> <line>...
#
# The label is printed once; every line after the first is indented to the
# value column so a block reads as one entry rather than several. Values are
# wrapped rather than allowed to run off the right edge.
row() {
  local label="$1" col="$2"; shift 2
  local avail=$(( TERM_COLS - 5 - LABEL_W ))
  [ "$avail" -ge 24 ] || avail=24
  local first=1 item out
  for item in "$@"; do
    [ -n "$item" ] || continue
    log "[ui] ${label}: $item"
    while IFS= read -r out; do
      if [ "$first" -eq 1 ]; then
        printf '   %b%-*s%b %b%s%b\n' "$C_MUTED" "$LABEL_W" "$label" "$NC" "$col" "$out" "$NC" >&3
        first=0
      else
        printf '   %*s %b%s%b\n' "$LABEL_W" "" "$col" "$out" "$NC" >&3
      fi
    done < <(wrap_text "$avail" "$item")
  done
  return 0
}

# Indented full-width prose. No label column, so a long flowing line - a list of
# what got installed, say - reads as one paragraph rather than a ragged table.
para() {
  local col="$1"; shift
  [ -n "$*" ] || return 0
  local out
  while IFS= read -r out; do
    ui "   ${col}${out}${NC}"
  done < <(wrap_text $(( TERM_COLS - 5 )) "$*")
  return 0
}

# Warnings are the longest lines the script emits, and the only ones that
# routinely overrun the terminal. Wrapping them under a hanging indent keeps
# them as one visual block instead of spilling back to column zero.
warn() {
  WARNINGS+=("$(strip_ansi "$*")")
  log "[ui] ! $(strip_ansi "$*")"
  local avail=$(( TERM_COLS - 6 ))
  [ "$avail" -ge 24 ] || avail=24
  local first=1 out
  while IFS= read -r out; do
    if [ "$first" -eq 1 ]; then
      ui "   ${C_WARN}${BOLD}!${NC} ${C_WARN}${out}${NC}"
      first=0
    else
      ui "     ${C_WARN}${out}${NC}"
    fi
  done < <(wrap_text "$avail" "$*")
  return 0
}

die() {
  ui ""
  ui "${C_ERR}${BOLD}  ✖ $1${NC}"
  [ "$LOG_READY" -eq 1 ] && ui "${C_MUTED}    Log: ${LOG_HINT}${NC}"
  ui ""
  log "FATAL: $(strip_ansi "$1")"
  exit "${2:-1}"
}

# A step header is "[n/N] Title" followed by a rule that fills whatever space
# the title leaves, so the heading always reaches the right margin.
step() {
  step_finish
  STEP_INDEX=$((STEP_INDEX + 1))
  CURRENT_STEP="$1"
  STEP_TITLE="$1"
  STEP_T0=$SECONDS
  local count="${STEP_INDEX}/${STEP_TOTAL}"
  # The chip renders as " n/N " - one pad column either side of the count.
  local used=$(( 1 + ${#count} + 2 + 1 + ${#1} + 1 ))
  local fill=$(( TERM_COLS - used - 1 ))
  [ "$fill" -ge 0 ] || fill=0
  # One blank line, and only here. Steps are the unit a reader scans by, so the
  # air goes between steps rather than inside them.
  ui ""
  ui " ${C_BADGE} ${count} ${NC} ${C_TITLE}${BOLD}$1${NC} ${C_RULE}$(rule_of "$fill")${NC}"
  log "=== STEP ${STEP_INDEX}/${STEP_TOTAL}: $1 ==="
}

# Close the open step and record its duration for the summary's timing line.
step_finish() {
  [ -n "$STEP_TITLE" ] || return 0
  STEP_TIMES+=("${STEP_TITLE}|$((SECONDS - STEP_T0))")
  STEP_TITLE=""
  return 0
}

# -----------------------------------------------------------------------------
# Error handling and cleanup
# -----------------------------------------------------------------------------
on_error() {
  local rc=$1 line=$2
  trap - ERR
  if [ "${BASHPID:-$$}" != "$$" ]; then
    log "command substitution failed (rc=$rc) near line $line"
    exit "$rc"
  fi
  ui ""
  ui "${C_ERR}${BOLD}  ✖ Failed during: ${CURRENT_STEP}${NC}"
  ui "${C_ERR}    exit ${rc} at line ${line}${NC}"
  if [ "$LOG_READY" -eq 1 ] && have journalctl; then
    # Let systemd-cat drain what is still sitting in the pipe before asking
    # journald to flush, or the last lines are exactly the ones missing.
    sleep 0.3
    journalctl --sync 2>/dev/null || true
    ui ""
    ui "${C_MUTED}    Last 20 log lines:${NC}"
    journalctl -t "$LOG_TAG" -n 20 --no-pager -o cat 2>/dev/null | sed 's/^/      /' >&3 || true
  fi
  ui ""
  ui "    Full log: ${BOLD}${LOG_HINT}${NC}"
  ui ""
  exit "$rc"
}
trap 'on_error $? $LINENO' ERR

cleanup() {
  show_cursor
  # Only the main shell owns the module directory; a subshell that happens to
  # run this trap must not pull the files out from under it.
  if [ "${BASHPID:-$$}" = "$$" ] && [ -n "$MODULE_DIR" ]; then
    rm -rf "$MODULE_DIR"
  fi
  return 0
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Command execution helpers
# -----------------------------------------------------------------------------
run() {
  local rc=0
  log "+ $*"
  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    log "  (dry-run: not executed)"
    return 0
  fi
  "$@" >&4 2>&1 || rc=$?
  [ $rc -eq 0 ] || log "  ! exited $rc"
  return $rc
}

run_sh() {
  local rc=0
  log "+ bash -c: $1"
  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    log "  (dry-run: not executed)"
    return 0
  fi
  bash -c "$1" >&4 2>&1 || rc=$?
  [ $rc -eq 0 ] || log "  ! exited $rc"
  return $rc
}

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
CURSOR_HIDDEN=0

hide_cursor() {
  if [ "$TTY" -eq 1 ] && [ "$CURSOR_HIDDEN" -eq 0 ]; then
    printf '\033[?25l' >&3 2>/dev/null || true
    CURSOR_HIDDEN=1
  fi
  return 0
}

show_cursor() {
  if [ "$CURSOR_HIDDEN" -eq 1 ]; then
    printf '\033[?25h' >&3 2>/dev/null || true
    CURSOR_HIDDEN=0
  fi
  return 0
}

# Draw one transient spinner frame. The message is truncated so the rendered
# line always fits on a single row; without this a long message wraps and every
# subsequent frame is printed as a new line instead of overwriting the old one.
spin_draw() {
  local frame="$1" msg="$2" suffix="$3"
  local budget=$(( TERM_COLS - 8 - ${#suffix} ))
  [ "$budget" -ge 12 ] || budget=12
  if [ "${#msg}" -gt "$budget" ]; then
    msg="${msg:0:$((budget - 1))}…"
  fi
  printf '\r\033[2K     %b%s%b %s%b%s%b' \
    "$C_INFO" "$frame" "$NC" "$msg" "$C_MUTED" "$suffix" "$NC" >&3
}

# Long-running command with a spinner on a terminal, plain line otherwise.
# Honours --dry-run; spin() below is the same thing for work that must happen
# even then, such as fetching the modules a dry run needs to describe.
run_spin() {
  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    detail "$1 (dry-run)"
    log "+ ${*:2}"
    return 0
  fi
  spin "$@"
}

spin() {
  local msg="$1"; shift
  local rc=0

  if [ "$TTY" -eq 0 ] || [ "$OPT_VERBOSE" -eq 1 ]; then
    detail "$msg"
    log "+ $*"
    "$@" >&4 2>&1 || rc=$?
    [ $rc -eq 0 ] || log "  ! exited $rc"
    return $rc
  fi

  log "+ $*"
  hide_cursor
  "$@" >&4 2>&1 &
  local pid=$! i=0 started=$SECONDS elapsed=0 suffix=""
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$((SECONDS - started))
    suffix=""
    # The elapsed counter only appears once a step is slow enough to worry
    # about, so short steps stay visually quiet.
    [ "$elapsed" -ge 5 ] && suffix="  ${elapsed}s"
    spin_draw "${SPIN_FRAMES[i % 10]}" "$msg" "$suffix"
    i=$((i + 1))
    sleep 0.2
  done
  wait "$pid" || rc=$?
  elapsed=$((SECONDS - started))
  printf '\r\033[2K' >&3
  show_cursor
  if [ $rc -eq 0 ]; then
    if [ "$elapsed" -ge 5 ]; then
      detail "$msg (${elapsed}s)"
    else
      detail "$msg"
    fi
  else
    log "  ! exited $rc"
  fi
  return $rc
}

# Retry with linear backoff. Used for every network-dependent operation, which
# is where unattended first-boot runs fail most often.
retry() {
  local max=3 n=1 rc=0
  while :; do
    rc=0
    "$@" >&4 2>&1 || rc=$?
    [ $rc -eq 0 ] && return 0
    if [ $n -ge $max ]; then
      log "  ! giving up after $n attempts (rc=$rc): $*"
      return $rc
    fi
    log "  ! attempt $n failed (rc=$rc), retry in $((n * 5))s: $*"
    sleep $((n * 5))
    n=$((n + 1))
  done
}

# apt_install <human label> <package>...
#
# The label is what the console shows; the full package list goes to the log
# only. Printing the list on the console produced a status line far wider than
# the terminal, which is what made the spinner repeat itself.
apt_install() {
  local label="$1"; shift
  log "packages: $*"
  run_spin "Installing $label" retry apt-get install "${APT_OPTS[@]}" "$@"
}

apt_update() {
  run_spin "Refreshing package indexes" retry apt-get update "${APT_OPTS[@]}"
  local rc=$?
  [ $rc -eq 0 ] && APT_UPDATED=1
  return $rc
}

# Any component may run on its own via --only, and --exclude=update is allowed,
# so a component that installs packages cannot assume the indexes were already
# refreshed. On a fresh image /var/lib/apt/lists is empty and every install
# would fail.
apt_ensure_lists() {
  [ "$APT_UPDATED" -eq 1 ] && return 0
  apt_update
}

have() { command -v "$1" >/dev/null 2>&1; }

# LXC (Proxmox CT), Docker, systemd-nspawn and friends. Several things a VM or
# a physical machine owns - the clock, swap, the CPU governor, power management
# - belong to the host in a container, and the components skip them there.
in_container() { systemd-detect-virt --container >/dev/null 2>&1; }

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local b
  b="${f}.bak-$(date +%Y%m%d-%H%M%S)"
  run cp -a "$f" "$b"
  log "backup: $f -> $b"
}

# Write a file only when its content would change. Keeps re-runs quiet and
# avoids needless service restarts.
write_file() {
  local path="$1" mode="$2" content="$3"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
    log "unchanged: $path"
    return 1
  fi
  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    log "would write: $path"
    return 0
  fi
  log "writing: $path"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" >"$path"
  chmod "$mode" "$path"
  return 0
}

# -----------------------------------------------------------------------------
# Login account helpers, shared by the ssh, hardening, bun and verify
# components and by the summary.
# -----------------------------------------------------------------------------
resolve_user_home() {
  [ -n "$SSH_USER_HOME" ] && return 0
  SSH_USER_HOME="$(getent passwd "$OPT_USERNAME" 2>/dev/null | cut -d: -f6 || true)"
  if [ -z "$SSH_USER_HOME" ] && [ "$OPT_DRY_RUN" -eq 1 ]; then
    SSH_USER_HOME="/home/$OPT_USERNAME"
  fi
  return 0
}

ssh_authorized_keys_path() {
  printf '%s/.ssh/authorized_keys' "$SSH_USER_HOME"
}

ssh_count_keys() {
  local f n
  f="$(ssh_authorized_keys_path)"
  [ -f "$f" ] || { echo 0; return 0; }
  # grep -c prints 0 and exits 1 when nothing matches, so swallow the status
  # instead of appending a second line of output.
  n="$(grep -cE '^(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null || true)"
  echo "${n:-0}"
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
  setup_colors
  exec 3>&1
  ui ""
  ui " ${C_STEP}${BOLD}${SCRIPT_NAME}${NC} ${C_MUTED}v${SCRIPT_VERSION}${NC}"
  ui " ${C_RULE}${RULE}${NC}"
  ui ""
  ui " ${C_TITLE}${BOLD}Usage:${NC} curl -fsSL ${SETUP_BASE_DEFAULT}/setup.sh | sudo bash -s -- [options]"
  ui "        sudo ./setup.sh [options]"
  ui ""
  ui " ${C_TITLE}${BOLD}Account and SSH${NC}"
  ui "   ${C_INFO}--username=NAME${NC}      Login account to configure. Default: ${BOLD}root${NC}."
  ui "                        A non-root name is created with passwordless sudo."
  ui "                        Root SSH login is left as the system had it."
  ui "   ${C_INFO}--ssh-port=N${NC}         Port for sshd, and the port opened in the firewall."
  ui "                        Default: ${BOLD}22${NC}. This is the ${BOLD}only${NC} sshd setting the"
  ui "                        script writes; authentication is left alone."
  ui "   ${C_INFO}--pubkey=\"ssh-... \"${NC}  Append this public key to the account's authorized_keys."
  ui "                        Optional. Existing keys are never removed."
  ui ""
  ui " ${C_TITLE}${BOLD}System${NC}"
  ui "   ${C_INFO}--hostname=NAME${NC}      Set the system hostname."
  ui "   ${C_INFO}--timezone=ZONE${NC}      Set the timezone. Default: ${BOLD}UTC${NC}, so timestamps"
  ui "                        from a fleet are comparable. Use ${BOLD}keep${NC} to leave the"
  ui "                        image's own setting alone."
  ui "   ${C_INFO}--ui-allow=CIDR${NC}      Allow these sources (comma separated) to reach the"
  ui "                        Dokploy UI on port 3000. Without it the port is"
  ui "                        closed to the network and reachable only over an"
  ui "                        SSH or Cloudflare tunnel."
  ui "   ${C_INFO}--local${NC}              Allow the private ranges (10/8, 172.16/12,"
  ui "                        192.168/16) to reach the Dokploy UI on port 3000."
  ui "                        The shorthand for reaching it from your own LAN"
  ui "                        without naming a subnet. Adds to --ui-allow."
  ui "   ${C_INFO}--ui-public${NC}          Expose the Dokploy UI to the whole internet."
  ui "                        ${C_WARN}The first visitor to reach it becomes the admin.${NC}"
  ui "   ${C_INFO}--auto-reboot=HH:MM${NC}  Let unattended-upgrades reboot in this window when a"
  ui "                        patch needs it. Default: never reboot on its own,"
  ui "                        which means kernel patches stay inactive."
  ui "   ${C_INFO}--remove-snapd${NC}       Purge snapd and hold the package (Ubuntu). Off by"
  ui "                        default; a Docker host does not need it, but removing"
  ui "                        a package manager should be asked for, not assumed."
  ui "   ${C_INFO}--reset-firewall${NC}     Wipe existing UFW rules before applying the baseline."
  ui "   ${C_INFO}--reinstall-dokploy${NC}  Reinstall Dokploy even if it is already present."
  ui "                        ${C_WARN}Destructive: leaves and re-initialises Docker Swarm.${NC}"
  ui ""
  ui " ${C_TITLE}${BOLD}Selection${NC}"
  ui "   ${C_INFO}--exclude=a,b${NC}        Skip these components."
  ui "   ${C_INFO}--only=a,b${NC}           Run only these components."
  ui "   ${C_INFO}--list${NC}               List components and exit."
  ui ""
  ui " ${C_TITLE}${BOLD}Behaviour${NC}"
  ui "   ${C_INFO}--base=URL${NC}           Fetch component modules from URL/setup/<name>.sh."
  ui "                        Also accepts an absolute directory. Default:"
  ui "                        ${SETUP_BASE_DEFAULT}, or the setup/"
  ui "                        directory beside the script when run from a checkout."
  ui "   ${C_INFO}--dry-run${NC}            Show what would happen, change nothing."
  ui "   ${C_INFO}--verbose${NC}            Disable the spinner, print each action as a line."
  ui "   ${C_INFO}--no-color${NC}           Disable coloured output."
  ui "   ${C_INFO}--version${NC}            Print the script version and exit."
  ui "   ${C_INFO}--help${NC}               Show this help and exit."
  ui ""
  ui " ${C_TITLE}${BOLD}Examples${NC}"
  ui "   ${C_MUTED}curl -fsSL ${SETUP_BASE_DEFAULT}/setup.sh | sudo bash -s -- --pubkey=\"\$(cat ~/.ssh/id_ed25519.pub)\"${NC}"
  ui "   ${C_MUTED}sudo ./setup.sh --username=deploy --ssh-port=2222 --ui-allow=203.0.113.9/32${NC}"
  ui "   ${C_MUTED}sudo ./setup.sh --local${NC}"
  ui "   ${C_MUTED}sudo ./setup.sh --exclude=bun,cloudflared${NC}"
  ui "   ${C_MUTED}sudo ./setup.sh --only=ssh,firewall,fail2ban${NC}"
  ui ""
  exit 0
}

list_components() {
  setup_colors
  exec 3>&1
  ui ""
  ui " ${C_TITLE}${BOLD}Available components${NC}"
  ui " ${C_RULE}${RULE}${NC}"
  local entry name desc
  for entry in "${COMPONENTS[@]}"; do
    name="${entry%%:*}"
    desc="${entry#*:}"
    printf '   %b%-13s%b %s\n' "$BOLD" "$name" "$NC" "$desc" >&3
  done
  ui ""
  exit 0
}

# -----------------------------------------------------------------------------
# Argument parsing. Unknown flags are a hard error: silently ignoring a typo in
# --exclude is how the previous version quietly did the wrong thing.
# -----------------------------------------------------------------------------
parse_args() {
  local arg value
  while [ $# -gt 0 ]; do
    arg="$1"
    value="${arg#*=}"
    case "$arg" in
      --help|-h)             usage ;;
      --list)                list_components ;;
      --version)             echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0 ;;
      --username=*)          OPT_USERNAME="$value" ;;
      --ssh-port=*)          OPT_SSH_PORT="$value" ;;
      --pubkey=*)            OPT_PUBKEY="$value" ;;
      --hostname=*)          OPT_HOSTNAME="$value" ;;
      --timezone=*)          OPT_TIMEZONE="$value"; OPT_TIMEZONE_SET=1 ;;
      --ui-allow=*)          OPT_UI_ALLOW="$value" ;;
      --ui-public)           OPT_UI_PUBLIC=1 ;;
      --local)               OPT_UI_LOCAL=1 ;;
      --auto-reboot=*)       OPT_AUTO_REBOOT="$value" ;;
      --exclude=*)           OPT_EXCLUDE="$value" ;;
      --only=*)              OPT_ONLY="$value" ;;
      --base=*)              OPT_BASE="$value" ;;
      --reset-firewall)      OPT_RESET_FIREWALL=1 ;;
      --reinstall-dokploy)   OPT_REINSTALL_DOKPLOY=1 ;;
      --remove-snapd)        OPT_REMOVE_SNAPD=1 ;;
      --dry-run)             OPT_DRY_RUN=1 ;;
      --verbose)             OPT_VERBOSE=1 ;;
      --no-color)            OPT_NO_COLOR=1 ;;
      *)
        setup_colors
        exec 3>&1
        die "Unknown option: $arg   (run with --help)"
        ;;
    esac
    shift
  done
}

validate_args() {
  local name known entry

  if ! [[ "$OPT_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$OPT_SSH_PORT" -lt 1 ] || [ "$OPT_SSH_PORT" -gt 65535 ]; then
    die "--ssh-port must be a number between 1 and 65535 (got: $OPT_SSH_PORT)"
  fi

  if ! [[ "$OPT_USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    die "--username must be a valid Linux user name (got: $OPT_USERNAME)"
  fi

  if [ -n "$OPT_PUBKEY" ] && ! [[ "$OPT_PUBKEY" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-|sk-)[A-Za-z0-9@.-]*[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
    die "--pubkey does not look like an OpenSSH public key"
  fi

  if [ -n "$OPT_EXCLUDE" ] && [ -n "$OPT_ONLY" ]; then
    die "--exclude and --only cannot be combined"
  fi

  # Reject unknown component names in --exclude / --only.
  local list
  for list in "$OPT_EXCLUDE" "$OPT_ONLY"; do
    [ -n "$list" ] || continue
    for name in ${list//,/ }; do
      known=0
      for entry in "${COMPONENTS[@]}"; do
        [ "${entry%%:*}" = "$name" ] && known=1 && break
      done
      [ $known -eq 1 ] || die "Unknown component: '$name'   (run with --list)"
    done
  done

  if [ -n "$OPT_BASE" ] && ! [[ "$OPT_BASE" =~ ^(https?://[^[:space:]]+|/[^[:space:]]*)$ ]]; then
    die "--base must be an http(s) URL or an absolute directory (got: $OPT_BASE)"
  fi

  # Only a zone the caller actually asked for is worth dying over. The default
  # is the script's own choice, and an image without tzdata has no zoneinfo at
  # all - failing there would mean a default that breaks the run.
  if [ "$OPT_TIMEZONE_SET" -eq 1 ] && [ "$OPT_TIMEZONE" != "keep" ] \
     && [ ! -f "/usr/share/zoneinfo/$OPT_TIMEZONE" ]; then
    die "Unknown timezone: $OPT_TIMEZONE   (or 'keep' to leave it alone)"
  fi

  if [ -n "$OPT_UI_ALLOW" ] && [ "$OPT_UI_PUBLIC" -eq 1 ]; then
    die "--ui-allow and --ui-public cannot be combined"
  fi

  # --local narrows, --ui-public opens to everything: asking for both is asking
  # for two different answers. --local with --ui-allow is fine and adds up.
  if [ "$OPT_UI_LOCAL" -eq 1 ] && [ "$OPT_UI_PUBLIC" -eq 1 ]; then
    die "--local and --ui-public cannot be combined"
  fi

  # A malformed CIDR would otherwise surface much later, as an iptables error
  # inside the boot-time firewall unit - with port 3000 left open. Fail here.
  if [ -n "$OPT_UI_ALLOW" ]; then
    local cidr
    for cidr in ${OPT_UI_ALLOW//,/ }; do
      if ! [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; then
        die "--ui-allow contains an invalid IPv4 address or CIDR: $cidr"
      fi
    done
  fi

  if [ -n "$OPT_AUTO_REBOOT" ] && ! [[ "$OPT_AUTO_REBOOT" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    die "--auto-reboot must be a 24-hour time such as 03:30 (got: $OPT_AUTO_REBOOT)"
  fi
}

# The private ranges --local stands for: RFC1918, and nothing else. Tailscale
# and other CGNAT overlays live in 100.64.0.0/10, which is deliberately absent -
# that range is also handed out by ISPs, so allowing it by default would open
# the UI to strangers on a CGNAT'd connection. Add it explicitly if you want it:
#   --local --ui-allow=100.64.0.0/10
UI_LOCAL_CIDRS="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

# The effective source list for the Dokploy UI port. Empty means the port is
# closed to everything except loopback. Shared by the dokploy component, which
# writes the iptables rule, and the summary, which reports the address.
ui_allow_list() {
  local out="$OPT_UI_ALLOW"
  if [ "$OPT_UI_LOCAL" -eq 1 ]; then
    if [ -n "$out" ]; then out="${out},${UI_LOCAL_CIDRS}"; else out="$UI_LOCAL_CIDRS"; fi
  fi
  printf '%s' "$out"
}

is_enabled() {
  local name="$1" candidate
  if [ -n "$OPT_ONLY" ]; then
    for candidate in ${OPT_ONLY//,/ }; do
      [ "$candidate" = "$name" ] && return 0
    done
    return 1
  fi
  for candidate in ${OPT_EXCLUDE//,/ }; do
    [ "$candidate" = "$name" ] && return 1
  done
  return 0
}

# Split the roster up front, so [n/total] is honest and the skipped components
# cost one quiet line instead of a stanza each.
plan_components() {
  local entry name
  for entry in "${COMPONENTS[@]}"; do
    name="${entry%%:*}"
    if is_enabled "$name"; then TO_RUN+=("$name"); else SKIPPED+=("$name"); fi
  done
  STEP_TOTAL=${#TO_RUN[@]}
  [ "$STEP_TOTAL" -gt 0 ] || die "Every component was excluded; nothing to do."
}

# =============================================================================
# Component modules
#
# setup/<name>.sh, one per component, fetched from SETUP_BASE or read from the
# checkout. Every module carries three markers - its name, the setup-api it was
# written against, and an end-of-module line - so a wrong file, a stale file
# and a truncated download are each caught before anything is sourced.
# =============================================================================
resolve_base() {
  local self dir
  if [ -n "$OPT_BASE" ]; then
    SETUP_BASE="$OPT_BASE"
  elif [ -z "$SETUP_BASE" ]; then
    # Run from a checkout: the modules beside the script win over the network,
    # which is what makes a branch testable before it is published.
    self="${BASH_SOURCE[0]:-}"
    if [ -n "$self" ] && [ -f "$self" ]; then
      dir="$(cd "$(dirname "$self")" 2>/dev/null && pwd -P || true)"
      [ -n "$dir" ] && [ -d "$dir/setup" ] && SETUP_BASE="$dir"
    fi
    [ -n "$SETUP_BASE" ] || SETUP_BASE="$SETUP_BASE_DEFAULT"
  fi
  SETUP_BASE="${SETUP_BASE%/}"
}

base_is_local() { [ "${SETUP_BASE#/}" != "$SETUP_BASE" ]; }

module_url() { printf '%s/setup/%s.sh' "$SETUP_BASE" "$1"; }

# Runs under the spinner, so the source that failed is left in a file for the
# caller to name in its error.
fetch_modules() {
  local name url dst
  for name in "$@"; do
    url="$(module_url "$name")"
    dst="$MODULE_DIR/$name.sh"
    log "module: $url"
    if base_is_local; then
      cp "$url" "$dst" || { printf '%s' "$url" >"$MODULE_DIR/.failed"; return 1; }
    else
      retry curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$dst" \
        || { printf '%s' "$url" >"$MODULE_DIR/.failed"; return 1; }
    fi
  done
  return 0
}

verify_module() {
  local name="$1" path="$2" src api
  src="$(module_url "$name")"
  [ -s "$path" ] || die "Module '$name' is empty. Source: $src"
  grep -qx "# setup-module: $name" "$path" \
    || die "Module '$name' is not a setup.sh component module. Source: $src"
  api="$(sed -n 's/^# setup-api: \([0-9][0-9]*\)$/\1/p' "$path" | head -n1 || true)"
  [ "$api" = "$SETUP_API" ] \
    || die "Module '$name' was written for setup-api ${api:-?}, this script is setup-api ${SETUP_API}. The published files are out of sync; retry in a few minutes."
  tail -n 3 "$path" | grep -qx '# end-of-module' \
    || die "Module '$name' is truncated (no end-of-module marker). Source: $src"
  bash -n "$path" >&4 2>&1 || die "Module '$name' failed the syntax check; see: ${LOG_HINT}"
}

load_modules() {
  local name path msg
  MODULE_DIR="$(mktemp -d)" || die "Could not create a temporary directory for the modules."
  if base_is_local; then
    msg="Loading $# component module(s) from ${SETUP_BASE}/setup"
  else
    msg="Fetching $# component module(s) from ${SETUP_BASE}"
  fi
  spin "$msg" fetch_modules "$@" \
    || die "Could not load module: $(cat "$MODULE_DIR/.failed" 2>/dev/null || echo unknown)"
  for name in "$@"; do
    path="$MODULE_DIR/$name.sh"
    verify_module "$name" "$path"
    # shellcheck disable=SC1090
    . "$path"
    declare -F "fn_${name}" >/dev/null || die "Module '$name' did not define fn_${name}."
  done
}

# =============================================================================
# Preflight
# =============================================================================
detect_os() {
  [ -r /etc/os-release ] || die "Cannot read /etc/os-release; this is not a supported system."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"
  ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

  case "$OS_ID" in
    debian|ubuntu) ;;
    *)
      # Derivatives (Linux Mint, Pop!_OS, Raspberry Pi OS) report their base in
      # ID_LIKE and work with the same repositories.
      case " ${ID_LIKE:-} " in
        *debian*|*ubuntu*)
          warn "Untested distribution '$OS_ID'; continuing because it is Debian-based."
          [ -n "$OS_CODENAME" ] || OS_CODENAME="${DEBIAN_CODENAME:-}"
          ;;
        *)
          die "Only Debian and Ubuntu are supported. Detected: $OS_PRETTY"
          ;;
      esac
      ;;
  esac

  [ -n "$OS_CODENAME" ] || die "Could not determine the distribution codename (VERSION_CODENAME)."
}

# Wait for cloud-init and the apt/dpkg locks. On a freshly booted cloud VM the
# unattended-upgrades and apt-daily timers hold these locks for the first minute
# or two, and any apt call in that window fails outright.
wait_for_system_ready() {
  if have cloud-init; then
    if cloud-init status >/dev/null 2>&1; then
      detail "Waiting for cloud-init to finish"
      run_sh "timeout 300 cloud-init status --wait" || warn "cloud-init did not finish within 300s; continuing anyway."
    fi
  fi

  local waited=0 timeout=300
  while apt_lock_held; do
    if [ $waited -eq 0 ]; then
      detail "Waiting for another package manager to release the apt lock"
    fi
    if [ $waited -ge $timeout ]; then
      warn "apt lock still held after ${timeout}s; stopping the apt timers and continuing."
      run systemctl stop unattended-upgrades.service apt-daily.service apt-daily-upgrade.service || true
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done
  [ $waited -gt 0 ] && detail "apt lock released after ${waited}s"
  return 0
}

# fuser lives in psmisc, which minimal images do not install, so fall back to
# looking for the processes that hold the lock.
apt_lock_held() {
  if have fuser; then
    fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1
    return $?
  fi
  pgrep -x apt-get >/dev/null 2>&1 && return 0
  pgrep -x dpkg >/dev/null 2>&1 && return 0
  pgrep -x apt >/dev/null 2>&1 && return 0
  # unattended-upgrade-shutdown runs permanently once the service is enabled and
  # holds no lock. Matching it would stall every run after the first for the
  # full timeout, so it has to be filtered out.
  pgrep -a -f 'unattended-upgrade' 2>/dev/null | grep -qv -- '-shutdown' && return 0
  return 1
}

# Proof that the clock is being disciplined, before the first apt call and the
# first TLS handshake. A wrong clock does not announce itself: apt rejects
# Release files as "not valid yet", TLS fails on notBefore, Let's Encrypt
# refuses to issue, JWTs are rejected as expired - none of which point at the
# clock. Minimal and container-derived images ship with time sync off far more
# often than you would expect, so it is confirmed rather than assumed.
ensure_clock() {
  if in_container; then
    detail "Container detected; the clock belongs to the host"
    return 0
  fi

  [ "$OPT_DRY_RUN" -eq 0 ] || { detail "Would verify time synchronisation"; return 0; }

  # An NTP daemon the distribution ships with, or one already installed: any of
  # them satisfies timedatectl, so only act when nothing is keeping time.
  if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)" = "yes" ]; then
    detail "Clock synchronised ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))"
    return 0
  fi

  if ! have chronyd && ! have ntpd; then
    run timedatectl set-ntp true || true
    run systemctl enable --now systemd-timesyncd.service || true
  fi

  # Give it a moment to make first contact before judging it.
  local waited=0
  while [ "$waited" -lt 20 ]; do
    [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)" = "yes" ] && break
    sleep 2
    waited=$((waited + 2))
  done

  if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)" = "yes" ]; then
    ok "Time synchronisation active ($(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC)"
  else
    warn "The clock is not synchronised. TLS, certificate issuance and token validation will fail in confusing ways until it is."
    detail "Check 'timedatectl status' and that UDP 123 is allowed outbound"
  fi
}

# Packages the run cannot start without, installed ahead of every component so
# even a --only=bun run has them. curl fetched this script so it is normally
# present; unzip is missing from most minimal images and is required before
# anything else runs (the Bun installer, for one, refuses without it).
bootstrap_packages() {
  local -a missing=()
  have curl  || missing+=(curl)
  have unzip || missing+=(unzip)
  [ -f /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)

  if [ ${#missing[@]} -eq 0 ]; then
    detail "Prerequisites present (curl, unzip, ca-certificates)"
    return 0
  fi
  apt_ensure_lists || die "apt-get update failed. Check network and mirror configuration."
  apt_install "prerequisites (${missing[*]})" "${missing[@]}" \
    || die "Could not install ${missing[*]}. See: ${LOG_HINT}"
  ok "Prerequisites installed: ${missing[*]}"
}

preflight() {
  CURRENT_STEP="preflight"

  [ "$(id -u)" -eq 0 ] || die "Must run as root:  sudo ./setup.sh"

  detect_os

  case "$ARCH" in
    amd64|arm64|x86_64|aarch64) ;;
    *) warn "Architecture '$ARCH' is unusual; Docker and Dokploy images may not exist for it." ;;
  esac

  banner

  # A Proxmox CT is a normal target, so a container is a note, not a warning.
  # Docker is the exception: Dokploy's installer refuses to run inside one.
  if [ -f /.dockerenv ]; then
    warn "Running inside a Docker container. Dokploy's installer refuses these and swarm may misbehave."
  elif in_container; then
    detail "Container detected ($(systemd-detect-virt --container 2>/dev/null || echo unknown)); host-owned settings will be skipped"
  fi

  # Basic connectivity check; a clear message here beats a confusing apt error.
  if ! run_sh "getent hosts deb.debian.org >/dev/null 2>&1 || getent hosts archive.ubuntu.com >/dev/null 2>&1"; then
    warn "DNS lookups for the distribution mirrors failed. Network problems are likely."
  fi

  wait_for_system_ready
  ensure_clock

  # Read-only, so a wrong URL or a stale module aborts with the machine
  # untouched. Then the prerequisites, ahead of every component.
  load_modules "${TO_RUN[@]}"
  bootstrap_packages
}

banner() {
  local mem_total disk_free
  mem_total="$(awk '/MemTotal/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "unknown")"
  disk_free="$(df -h / | awk 'NR==2 {print $4 " free of " $2}' 2>/dev/null || echo "unknown")"

  # Title and rule share one line; the facts pack into a few rows.
  local title="${SCRIPT_NAME} v${SCRIPT_VERSION}"
  local fill=$(( TERM_COLS - ${#title} - 3 ))
  [ "$fill" -ge 0 ] || fill=0
  ui ""
  ui " ${C_STEP}${BOLD}${SCRIPT_NAME}${NC} ${C_MUTED}v${SCRIPT_VERSION}${NC} ${C_STEP}$(rule_heavy "$fill")${NC}"
  row "System" "" "$OS_PRETTY ($ARCH) · $(uname -r)"
  row "Host" "" "$(hostname) · ${mem_total} RAM · ${disk_free}"
  local target="user ${OPT_USERNAME} · ssh port ${OPT_SSH_PORT}"
  [ "$OPT_TIMEZONE" = "keep" ] || target="${target} · ${OPT_TIMEZONE}"
  row "Target" "" "$target"
  row "Modules" "$C_MUTED" "$SETUP_BASE"
  row "Log" "$C_MUTED" "$LOG_HINT"
  if [ ${#SKIPPED[@]} -gt 0 ]; then
    local skip_list="" name
    for name in "${SKIPPED[@]}"; do
      if [ -z "$skip_list" ]; then skip_list="$name"; else skip_list="${skip_list} · ${name}"; fi
    done
    row "Skipped" "$C_MUTED" "$skip_list"
  fi
  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    row "Mode" "$C_WARN" "DRY RUN — no changes will be made"
  fi
}

# =============================================================================
# Summary
# =============================================================================
version_of() {
  local cmd="$1"
  have "$cmd" || { printf '%s' "not installed"; return 0; }
  case "$cmd" in
    docker)      docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || true ;;
    cloudflared) cloudflared --version 2>/dev/null | awk '{print $3}' || true ;;
    fail2ban-client) fail2ban-client --version 2>/dev/null | awk '{print $2}' || true ;;
    *)           printf 'installed' ;;
  esac
}

fmt_secs() {
  local s="$1"
  if [ "$s" -ge 60 ]; then
    printf '%dm %02ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

# Only the steps that took five seconds or more. The fast ones are noise;
# where the minutes went is the useful part.
step_times_list() {
  local e title secs out=""
  for e in ${STEP_TIMES[@]+"${STEP_TIMES[@]}"}; do
    title="${e%|*}"
    secs="${e##*|}"
    [ "$secs" -ge 5 ] || continue
    if [ -z "$out" ]; then
      out="${title} $(fmt_secs "$secs")"
    else
      out="${out} · ${title} $(fmt_secs "$secs")"
    fi
  done
  printf '%s' "$out"
  return 0
}

summary() {
  local elapsed=$((SECONDS - START_TIME))
  local nwarn=${#WARNINGS[@]}
  local plural="s"
  [ "$nwarn" -eq 1 ] && plural=""

  # Green when the run was clean, amber when it was not: the tail of a captured
  # log answers "did anything go sideways?" before anyone scrolls.
  local bar barcol="$C_OK"
  bar="Setup complete in $(fmt_secs "$elapsed")"
  if [ "$nwarn" -gt 0 ]; then
    bar="${bar} — ${nwarn} warning${plural}"
    barcol="$C_WARN"
  fi
  local fill=$(( TERM_COLS - $(dwidth "$bar") - 6 ))
  [ "$fill" -ge 0 ] || fill=0
  ui ""
  ui " ${barcol}${BOLD}━━ ${bar} $(rule_heavy "$fill")${NC}"
  ui ""

  # Everything else the old summary repeated - each version, the SSH settings,
  # the next steps - was already said once, in the step that did the work. What
  # is left is the roll call, the timing, the addresses and the warnings,
  # because those are the only things a reader has to carry away from the run.
  para "" "$(installed_list)"
  local times
  times="$(step_times_list)"
  [ -n "$times" ] && row "Time" "$C_MUTED" "$times"
  ui ""

  if [ -n "$PUBLIC_IP" ]; then
    row "Connect" "$C_INFO" "ssh -p ${OPT_SSH_PORT} ${OPT_USERNAME}@${PUBLIC_IP}"
    is_private_ip "$PUBLIC_IP" && row "" "$C_MUTED" "that is a private address — reachable from this network only" || true
    if [ "$DOKPLOY_INSTALLED" -eq 1 ]; then
      local allow
      allow="$(ui_allow_list)"
      if [ "$OPT_UI_PUBLIC" -eq 1 ]; then
        row "Dokploy" "$C_INFO" "http://${PUBLIC_IP}:3000"
        row "" "$C_WARN" "open to the internet — claim the admin account now"
      elif [ -n "$allow" ]; then
        row "Dokploy" "$C_INFO" "http://${PUBLIC_IP}:3000"
        row "" "$C_MUTED" "reachable from ${allow} only"
      else
        row "Dokploy" "$C_INFO" "ssh -L 3000:localhost:3000 -p ${OPT_SSH_PORT} ${OPT_USERNAME}@${PUBLIC_IP}"
        row "" "$C_MUTED" "then open http://localhost:3000 (port 3000 is closed)"
      fi
    fi
  fi
  row "Log" "$C_MUTED" "$LOG_HINT"

  # The warnings again, in one place. During the run each one scrolled past
  # inside its own step; an unattended log is read from the tail, so the recap
  # has to be the last thing printed.
  if [ "$nwarn" -gt 0 ]; then
    ui ""
    ui "   ${C_WARN}${BOLD}!${NC} ${C_TITLE}${BOLD}${nwarn} warning${plural} from this run${NC}"
    local w out first avail=$(( TERM_COLS - 9 ))
    [ "$avail" -ge 24 ] || avail=24
    for w in ${WARNINGS[@]+"${WARNINGS[@]}"}; do
      first=1
      while IFS= read -r out; do
        if [ "$first" -eq 1 ]; then
          ui "     ${C_WARN}·${NC} ${C_WARN}${out}${NC}"
          first=0
        else
          ui "       ${C_WARN}${out}${NC}"
        fi
      done < <(wrap_text "$avail" "$w")
    done
  fi
  ui ""
  log "RESULT: success warnings=${nwarn} elapsed=${elapsed}s"
}

# The address to print in the connect command.
#
# Asks the provider rather than a third-party echo service. Link-local metadata
# never leaves the host's own network, answers in milliseconds, reports the
# address actually assigned rather than whatever NAT a request happened to exit
# through, and does not put a six-figure monthly load on somebody else's free
# endpoint. Falls back to the source address of the default route, which is
# right on bare metal and on anything not behind NAT.
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

meta_get() {
  local out
  out="$(curl -4fsS --connect-timeout 1 --max-time 2 "$@" 2>/dev/null | tr -d '[:space:]' || true)"
  is_ipv4 "$out" && printf '%s' "$out"
  return 0
}

detect_public_ip() {
  local ip="" token=""

  # AWS. IMDSv2 requires a token; instances configured for it reject IMDSv1
  # outright, so ask for one first and fall through when there is no IMDS.
  token="$(curl -4fsS --connect-timeout 1 --max-time 2 -X PUT \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    http://169.254.169.254/latest/api/token 2>/dev/null || true)"
  if [ -n "$token" ]; then
    ip="$(meta_get -H "X-aws-ec2-metadata-token: $token" \
      http://169.254.169.254/latest/meta-data/public-ipv4)"
  fi

  # DigitalOcean, Hetzner and OpenStack answer the same path unauthenticated.
  [ -n "$ip" ] || ip="$(meta_get http://169.254.169.254/latest/meta-data/public-ipv4)"

  # Google Cloud.
  [ -n "$ip" ] || ip="$(meta_get -H 'Metadata-Flavor: Google' \
    http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)"

  # Azure.
  [ -n "$ip" ] || ip="$(meta_get -H 'Metadata: true' \
    'http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text')"

  # No metadata service: use the address this host would source traffic from.
  [ -n "$ip" ] || ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)"
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

  is_ipv4 "$ip" && printf '%s' "$ip"
  return 0
}

# RFC1918 and CGNAT. Worth saying out loud, because a connect command built
# from a private address will not work from anywhere but the same network.
is_private_ip() {
  case "$1" in
    10.*|192.168.*|127.*|169.254.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
    *) return 1 ;;
  esac
}

installed_list() {
  local bun_bin="${SSH_USER_HOME:-/root}/.bun/bin/bun"
  local -a got=()
  have docker           && got+=("Docker $(version_of docker)")
  [ "$DOKPLOY_INSTALLED" -eq 1 ] && got+=("Dokploy")
  have cloudflared      && got+=("cloudflared $(version_of cloudflared)")
  have fail2ban-client  && got+=("fail2ban $(version_of fail2ban-client)")
  [ -x "$bun_bin" ]     && got+=("Bun $("$bun_bin" --version 2>/dev/null)")
  # Only what is actually on the box; "not installed" rows told nobody anything.
  local out="" item
  for item in ${got[@]+"${got[@]}"}; do
    if [ -z "$out" ]; then out="$item"; else out="$out · $item"; fi
  done
  printf '%s' "$out"
  return 0
}

# =============================================================================
# Main
# =============================================================================
open_log() {
  # fd 4 is the log. It feeds the systemd journal rather than a file: nothing
  # to rotate, collect or clean up, journald's own caps bound the size, and
  # fleet tooling reads it back with the same command on every host.
  #
  # The socket check matters: systemd-cat exists wherever systemd is installed,
  # but with no journald behind it (a chroot, a plain Docker image) it exits at
  # once, and the first write to a pipe nobody reads would kill this shell with
  # SIGPIPE - silently, before a single step ran.
  if have systemd-cat && [ -S /run/systemd/journal/stdout ]; then
    exec 4> >(exec systemd-cat -t "$LOG_TAG" -p info)
    LOG_READY=1
  else
    # No journal on this system. Command output has nowhere useful to go;
    # --verbose puts each action on the console instead.
    exec 4>/dev/null
    LOG_HINT="unavailable (no systemd journal); re-run with --verbose"
  fi
}

main() {
  parse_args "$@"
  setup_colors

  # fd 3 is the console. Everything a command prints goes to the log instead.
  exec 3>&1

  validate_args
  resolve_base
  open_log
  log "$SCRIPT_NAME v$SCRIPT_VERSION starting; args: $*"

  # Nothing here reads from the terminal, and when the script itself arrives on
  # stdin (curl ... | bash) any child that reads stdin would swallow the rest
  # of it. By this point the whole file has been parsed - this call is its last
  # line - so cutting stdin off costs nothing and removes the hazard.
  exec </dev/null

  plan_components
  preflight

  # Needed by fn_bun and the summary even when the ssh component is skipped.
  resolve_user_home

  local name
  for name in "${TO_RUN[@]}"; do
    "fn_${name}"
  done
  step_finish

  PUBLIC_IP="$(detect_public_ip)"

  CURRENT_STEP="summary"
  summary
}

main "$@"
