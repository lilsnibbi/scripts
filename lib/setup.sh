#!/usr/bin/env bash
# =============================================================================
#  setup.sh - Server Initialization Suite
#
#  Bootstraps a fresh Debian or Ubuntu VM: system updates, SSH key setup and
#  hardening, firewall, fail2ban, Docker, Dokploy, and unattended security
#  updates.
#
#  Designed to run unattended on first boot. Every step is idempotent and safe
#  to re-run.
#
#  Usage: sudo ./setup.sh [options]     (see --help)
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="Server Initialization Suite"

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
OPT_NEW_KEY=0
OPT_SAVE_KEY=""
OPT_KEEP_PASSWORD_AUTH=0
OPT_HOSTNAME=""
# UTC by default rather than whatever the image happens to ship. Timestamps
# from a fleet are only comparable if every host agrees on the zone, and a
# server has no reason to prefer a local one. --timezone=keep opts out.
OPT_TIMEZONE="UTC"
OPT_TIMEZONE_SET=0
OPT_UI_ALLOW=""
OPT_UI_PUBLIC=0
OPT_AUTO_REBOOT=""
OPT_EXCLUDE=""
OPT_ONLY=""
OPT_RESET_FIREWALL=0
OPT_REINSTALL_DOKPLOY=0
OPT_DRY_RUN=0
OPT_VERBOSE=0
OPT_NO_COLOR=0

# -----------------------------------------------------------------------------
# Components, in execution order. "name:description".
# -----------------------------------------------------------------------------
COMPONENTS=(
  "update:Refresh apt indexes and apply pending security upgrades"
  "base:Install base utilities (curl, git, jq, iproute2, ...)"
  "ssh:Create the login account, install SSH keys, harden sshd"
  "firewall:Configure the UFW firewall"
  "fail2ban:Install and pre-configure fail2ban for SSH"
  "hardening:Kernel network hardening, journald limits, root password lock"
  "swap:Create a swapfile when RAM is small and no swap exists"
  "docker:Install Docker CE with container log rotation"
  "dokploy:Install the Dokploy PaaS platform"
  "cloudflared:Install the Cloudflare Zero Trust tunnel daemon"
  "bun:Install the Bun JavaScript runtime"
  "unattended:Enable automatic security updates"
  "verify:Prove SSH still works before this session is closed"
)

# -----------------------------------------------------------------------------
# Runtime state
# -----------------------------------------------------------------------------
LOG_FILE=""
APT_UPDATED=0
CURRENT_STEP="startup"
STEP_INDEX=0
STEP_TOTAL=0
TTY=0
START_TIME=$SECONDS

GENERATED_PRIVATE_KEY=""
SSH_KEY_SOURCE="none"
SSH_HARDENED=0
DOKPLOY_INSTALLED=0

declare -a WARNINGS=()
declare -a SUMMARY=()

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
C_TITLE='' C_STEP='' C_OK='' C_WARN='' C_ERR='' C_INFO='' C_MUTED='' C_RULE='' C_KEY='' C_BADGE=''

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
      C_TITLE=$'\033[38;2;255;255;255m'   # white     - headings, the loudest thing
      C_STEP=$'\033[38;2;199;125;255m'    # violet    - step badges, product name
      C_INFO=$'\033[38;2;43;231;255m'     # cyan      - in-progress, addresses
      C_OK=$'\033[38;2;61;255;136m'       # spring    - completed
      C_WARN=$'\033[38;2;255;182;39m'     # amber     - warnings
      C_ERR=$'\033[38;2;255;77;109m'      # rose      - failures
      C_MUTED=$'\033[38;2;163;177;209m'   # pale slate- secondary detail
      C_RULE=$'\033[38;2;76;90;135m'      # slate     - dividers and frames
      C_KEY=$'\033[38;2;255;210;74m'      # gold      - the private key callout
      # A filled chip: violet background, near-black text. Legible on a light
      # terminal as well as a dark one, because both halves are set here.
      C_BADGE=$'\033[48;2;199;125;255;38;2;22;18;32;1m'
      ;;
    2)
      C_TITLE=$'\033[38;5;231m'
      C_STEP=$'\033[38;5;141m'
      C_INFO=$'\033[38;5;51m'
      C_OK=$'\033[38;5;48m'
      C_WARN=$'\033[38;5;214m'
      C_ERR=$'\033[38;5;203m'
      C_MUTED=$'\033[38;5;250m'
      C_RULE=$'\033[38;5;60m'
      C_KEY=$'\033[38;5;220m'
      C_BADGE=$'\033[48;5;141;38;5;16;1m'
      ;;
    *)
      C_TITLE=$'\033[97m'
      C_STEP=$'\033[95m'
      C_INFO=$'\033[96m'
      C_OK=$'\033[92m'
      C_WARN=$'\033[93m'
      C_ERR=$'\033[91m'
      C_MUTED=$'\033[37m'
      C_RULE=$'\033[90m'
      C_KEY=$'\033[93m'
      C_BADGE=$'\033[45;30;1m'
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
# The console (fd 3) and the log file are deliberately separate streams. Command
# output goes only to the log; the generated private key goes only to the
# console, so it is never written to disk.
# -----------------------------------------------------------------------------
strip_ansi() { printf '%s' "$1" | sed -e 's/\x1b\[[0-9;]*m//g'; }

log() {
  [ -n "$LOG_FILE" ] || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_FILE"
}

ui() { printf '%b\n' "$*" >&3; }

say() {
  ui "$*"
  log "[ui] $(strip_ansi "$*")"
}

info()   { say "   ${C_INFO}${BOLD}·${NC} $*"; }
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
wrap_text() {
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

# Join short items with " · ", starting a new line before the budget runs out.
# Turns five one-item rows into one or two dense rows.
join_items() {
  local width="$1"; shift
  local line="" item
  for item in "$@"; do
    if [ -z "$line" ]; then
      line="$item"
    elif [ $(( $(dwidth "$line") + 3 + $(dwidth "$item") )) -le "$width" ]; then
      line="$line · $item"
    else
      printf '%s\n' "$line"
      line="$item"
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
  [ -n "$LOG_FILE" ] && ui "${C_MUTED}    Log: ${LOG_FILE}${NC}"
  ui ""
  log "FATAL: $(strip_ansi "$1")"
  exit "${2:-1}"
}

# A step header is "[n/N] Title" followed by a rule that fills whatever space
# the title leaves, so the heading always reaches the right margin.
step() {
  STEP_INDEX=$((STEP_INDEX + 1))
  CURRENT_STEP="$1"
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

step_skipped() {
  ui ""
  ui " ${C_MUTED}  skip   $1 — $2${NC}"
  log "=== SKIPPED: $1 ($2) ==="
}

# -----------------------------------------------------------------------------
# Error handling
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
  if [ -n "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
    ui ""
    ui "${C_MUTED}    Last 20 log lines:${NC}"
    sed 's/^/      /' <(tail -n 20 "$LOG_FILE") >&3 2>/dev/null || true
  fi
  ui ""
  ui "    Full log: ${BOLD}${LOG_FILE}${NC}"
  # A key generated before the failure is already installed on the server and
  # exists nowhere but this screen. Losing it to an unrelated later failure
  # would lock the account out for good.
  print_private_key
  ui ""
  exit "$rc"
}
trap 'on_error $? $LINENO' ERR

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
  "$@" >>"$LOG_FILE" 2>&1 || rc=$?
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
  bash -c "$1" >>"$LOG_FILE" 2>&1 || rc=$?
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
trap show_cursor EXIT

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
run_spin() {
  local msg="$1"; shift
  local rc=0

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    detail "$msg (dry-run)"
    log "+ $*"
    return 0
  fi

  if [ "$TTY" -eq 0 ] || [ "$OPT_VERBOSE" -eq 1 ]; then
    detail "$msg"
    run "$@"
    return $?
  fi

  log "+ $*"
  hide_cursor
  "$@" >>"$LOG_FILE" 2>&1 &
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
    "$@" >>"$LOG_FILE" 2>&1 || rc=$?
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
# Usage
# -----------------------------------------------------------------------------
usage() {
  setup_colors
  exec 3>&1
  ui ""
  ui " ${C_STEP}${BOLD}${SCRIPT_NAME}${NC} ${C_MUTED}v${SCRIPT_VERSION}${NC}"
  ui " ${C_RULE}${RULE}${NC}"
  ui ""
  ui " ${C_TITLE}${BOLD}Usage:${NC} sudo ./setup.sh [options]"
  ui ""
  ui " ${C_TITLE}${BOLD}Account and SSH${NC}"
  ui "   ${C_INFO}--username=NAME${NC}      Login account to configure. Default: ${BOLD}root${NC}."
  ui "                        A non-root name is created with passwordless sudo,"
  ui "                        and root SSH login is then disabled."
  ui "   ${C_INFO}--ssh-port=N${NC}         Port for sshd. Default: ${BOLD}22${NC}."
  ui "   ${C_INFO}--pubkey=\"ssh-... \"${NC}  Install this public key instead of generating one."
  ui "   ${C_INFO}--new-key${NC}            Generate a fresh keypair even if the account already"
  ui "                        has authorized keys."
  ui "   ${C_INFO}--save-key=PATH${NC}      Also write the generated private key to PATH (mode 0600)."
  ui "   ${C_INFO}--keep-password-auth${NC} Leave SSH password login enabled. Not recommended."
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
  ui "   ${C_INFO}--ui-public${NC}          Expose the Dokploy UI to the whole internet."
  ui "                        ${C_WARN}The first visitor to reach it becomes the admin.${NC}"
  ui "   ${C_INFO}--auto-reboot=HH:MM${NC}  Let unattended-upgrades reboot in this window when a"
  ui "                        patch needs it. Default: never reboot on its own,"
  ui "                        which means kernel patches stay inactive."
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
  ui "   ${C_INFO}--dry-run${NC}            Show what would happen, change nothing."
  ui "   ${C_INFO}--verbose${NC}            Disable the spinner, print each action as a line."
  ui "   ${C_INFO}--no-color${NC}           Disable coloured output."
  ui "   ${C_INFO}--version${NC}            Print the script version and exit."
  ui "   ${C_INFO}--help${NC}               Show this help and exit."
  ui ""
  ui " ${C_TITLE}${BOLD}Examples${NC}"
  ui "   ${C_MUTED}sudo ./setup.sh${NC}"
  ui "   ${C_MUTED}sudo ./setup.sh --username=deploy --ssh-port=2222 --ui-allow=203.0.113.9/32${NC}"
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
      --new-key)             OPT_NEW_KEY=1 ;;
      --save-key=*)          OPT_SAVE_KEY="$value" ;;
      --keep-password-auth)  OPT_KEEP_PASSWORD_AUTH=1 ;;
      --hostname=*)          OPT_HOSTNAME="$value" ;;
      --timezone=*)          OPT_TIMEZONE="$value"; OPT_TIMEZONE_SET=1 ;;
      --ui-allow=*)          OPT_UI_ALLOW="$value" ;;
      --ui-public)           OPT_UI_PUBLIC=1 ;;
      --auto-reboot=*)       OPT_AUTO_REBOOT="$value" ;;
      --exclude=*)           OPT_EXCLUDE="$value" ;;
      --only=*)              OPT_ONLY="$value" ;;
      --reset-firewall)      OPT_RESET_FIREWALL=1 ;;
      --reinstall-dokploy)   OPT_REINSTALL_DOKPLOY=1 ;;
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

  if [ -n "$OPT_AUTO_REBOOT" ] && ! [[ "$OPT_AUTO_REBOOT" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    die "--auto-reboot must be a 24-hour time such as 03:30 (got: $OPT_AUTO_REBOOT)"
  fi
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

preflight() {
  CURRENT_STEP="preflight"

  [ "$(id -u)" -eq 0 ] || die "Must run as root:  sudo ./setup.sh"

  detect_os

  case "$ARCH" in
    amd64|arm64|x86_64|aarch64) ;;
    *) warn "Architecture '$ARCH' is unusual; Docker and Dokploy images may not exist for it." ;;
  esac

  banner

  if [ -f /.dockerenv ] || grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
    warn "Running inside a container. Dokploy's installer refuses Docker containers and swarm may misbehave."
  fi

  # Basic connectivity check; a clear message here beats a confusing apt error.
  if ! run_sh "getent hosts deb.debian.org >/dev/null 2>&1 || getent hosts archive.ubuntu.com >/dev/null 2>&1"; then
    warn "DNS lookups for the distribution mirrors failed. Network problems are likely."
  fi

  wait_for_system_ready
}

banner() {
  local mem_total disk_free
  mem_total="$(awk '/MemTotal/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "unknown")"
  disk_free="$(df -h / | awk 'NR==2 {print $4 " free of " $2}' 2>/dev/null || echo "unknown")"

  # Title and rule share one line; the six facts pack into three rows.
  local title="${SCRIPT_NAME} v${SCRIPT_VERSION}"
  local fill=$(( TERM_COLS - ${#title} - 3 ))
  [ "$fill" -ge 0 ] || fill=0
  ui ""
  ui " ${C_STEP}${BOLD}${SCRIPT_NAME}${NC} ${C_MUTED}v${SCRIPT_VERSION}${NC} ${C_STEP}$(rule_heavy "$fill")${NC}"
  row "System" "" "$OS_PRETTY ($ARCH) · $(uname -r)"
  row "Host" "" "$(hostname) · ${mem_total} RAM · ${disk_free}"
  row "Log" "$C_MUTED" "$LOG_FILE"
  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    row "Mode" "$C_WARN" "DRY RUN — no changes will be made"
  fi
}

# =============================================================================
# Component: update
# =============================================================================
# Timezone, and proof that the clock is actually being disciplined.
#
# A wrong clock does not announce itself. It surfaces hours later as TLS
# handshakes that fail on notBefore, Let's Encrypt refusing to issue, JWTs
# rejected as expired, and registry auth failing - none of which point at the
# clock. Minimal and container-derived images ship with time sync off far more
# often than you would expect, so it is worth confirming rather than assuming.
configure_clock() {
  if [ -n "$OPT_TIMEZONE" ] && [ "$OPT_TIMEZONE" != "keep" ]; then
    local current
    current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    if [ "$current" = "$OPT_TIMEZONE" ]; then
      detail "Timezone already $OPT_TIMEZONE"
    elif [ ! -f "/usr/share/zoneinfo/$OPT_TIMEZONE" ]; then
      # tzdata is missing rather than the zone being wrong: --timezone was
      # validated at startup, so this can only be the UTC default.
      detail "No zoneinfo on this image; leaving the timezone as ${current:-unknown}"
    elif run timedatectl set-timezone "$OPT_TIMEZONE"; then
      ok "Timezone set to $OPT_TIMEZONE"
    else
      warn "Could not set the timezone to $OPT_TIMEZONE."
    fi
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

fn_update() {
  step "System update"

  configure_clock

  if [ -n "$OPT_HOSTNAME" ] && [ "$OPT_HOSTNAME" != "$(hostname)" ]; then
    run hostnamectl set-hostname "$OPT_HOSTNAME"
    # Keep /etc/hosts consistent so sudo does not stall on name resolution.
    if ! grep -qE "^127\.0\.1\.1[[:space:]]+$OPT_HOSTNAME\b" /etc/hosts 2>/dev/null; then
      run_sh "printf '127.0.1.1\t%s\n' '$OPT_HOSTNAME' >> /etc/hosts"
    fi
    ok "Hostname set to $OPT_HOSTNAME"
  fi

  apt_update || die "apt-get update failed. Check network and mirror configuration."

  local pending
  pending="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true)"
  if [ "${pending:-0}" -gt 0 ]; then
    detail "$pending package(s) to upgrade"
    run_spin "Upgrading packages (this can take several minutes)" \
      retry apt-get dist-upgrade "${APT_OPTS[@]}" \
      || die "Package upgrade failed. See $LOG_FILE"
    ok "System packages upgraded"
  else
    ok "System already up to date"
  fi

  run apt-get autoremove "${APT_OPTS[@]}" || true

  if [ -f /var/run/reboot-required ]; then
    warn "A reboot is required to finish applying kernel or library updates."
  fi
}

# =============================================================================
# Component: base
# =============================================================================
fn_base() {
  step "Base packages"

  # iproute2 provides ss, which Dokploy's installer uses for its port checks.
  # openssh-client provides ssh -Q, used to pick supported SSH algorithms.
  apt_ensure_lists || die "apt-get update failed. Check network and mirror configuration."

  local pkgs=(
    ca-certificates curl wget gnupg lsb-release apt-transport-https
    git unzip tar jq
    iproute2 net-tools dnsutils psmisc
    openssh-server openssh-client
    sudo ufw
    htop rsync
  )

  apt_install "base packages (${#pkgs[@]})" "${pkgs[@]}" || die "Failed to install base packages. See $LOG_FILE"
  ok "Base packages installed"
}

# =============================================================================
# Component: ssh
#
# Order matters. The account and its authorized_keys are created and verified
# first; sshd is only hardened afterwards, and never if no usable key is in
# place. That ordering is what makes a lockout impossible.
# =============================================================================
SSH_USER_HOME=""

ssh_resolve_home() {
  SSH_USER_HOME="$(getent passwd "$OPT_USERNAME" 2>/dev/null | cut -d: -f6 || true)"
  if [ -z "$SSH_USER_HOME" ]; then
    if [ "$OPT_DRY_RUN" -eq 1 ]; then
      SSH_USER_HOME="/home/$OPT_USERNAME"
      return 0
    fi
    die "Could not resolve the home directory of '$OPT_USERNAME'."
  fi
}

ssh_create_user() {
  if [ "$OPT_USERNAME" = "root" ]; then
    ssh_resolve_home
    return 0
  fi

  if id -u "$OPT_USERNAME" >/dev/null 2>&1; then
    ok "User '$OPT_USERNAME' already exists"
  else
    run useradd --create-home --shell /bin/bash "$OPT_USERNAME" \
      || die "Failed to create user '$OPT_USERNAME'."
    ok "Created user '$OPT_USERNAME'"
  fi

  # No password is ever set, so login is key-only. sudo therefore has to be
  # passwordless or the account could not administer anything.
  run usermod -aG sudo "$OPT_USERNAME" || true
  local sudoers="/etc/sudoers.d/90-${OPT_USERNAME}-init"
  write_file "$sudoers" 0440 "$OPT_USERNAME ALL=(ALL) NOPASSWD:ALL" || true
  if [ "$OPT_DRY_RUN" -eq 0 ] && [ -f "$sudoers" ]; then
    if have visudo; then
      if ! visudo -cf "$sudoers" >>"$LOG_FILE" 2>&1; then
        run rm -f "$sudoers"
        die "The generated sudoers file was rejected by visudo and has been removed."
      fi
    else
      warn "visudo is unavailable, so the sudoers drop-in could not be validated."
    fi
  fi
  ok "Passwordless sudo configured for '$OPT_USERNAME'"

  ssh_resolve_home
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

ssh_install_pubkey() {
  local pubkey="$1"
  local dir="$SSH_USER_HOME/.ssh"
  local file="$dir/authorized_keys"

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    detail "Would install public key into $file"
    return 0
  fi

  install -d -m 700 -o "$OPT_USERNAME" -g "$(id -gn "$OPT_USERNAME")" "$dir"
  touch "$file"
  chmod 600 "$file"
  chown "$OPT_USERNAME:$(id -gn "$OPT_USERNAME")" "$file"

  if grep -qxF "$pubkey" "$file" 2>/dev/null; then
    detail "Public key already present in authorized_keys"
  else
    printf '%s\n' "$pubkey" >>"$file"
  fi
}

# The private key is printed to the console only, never to the log file, and is
# shredded from the temporary directory immediately after being read.
ssh_generate_key() {
  local tmpdir comment priv pub
  comment="${OPT_USERNAME}@$(hostname)-$(date +%Y%m%d)"

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    detail "Would generate an ed25519 keypair ($comment)"
    SSH_KEY_SOURCE="generated"
    return 0
  fi

  tmpdir="$(mktemp -d)"
  chmod 700 "$tmpdir"
  ssh-keygen -t ed25519 -a 100 -N '' -C "$comment" -f "$tmpdir/id_ed25519" >>"$LOG_FILE" 2>&1 \
    || die "ssh-keygen failed."

  priv="$(cat "$tmpdir/id_ed25519")"
  pub="$(cat "$tmpdir/id_ed25519.pub")"

  if have shred; then
    shred -u "$tmpdir/id_ed25519" "$tmpdir/id_ed25519.pub" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"

  ssh_install_pubkey "$pub"
  GENERATED_PRIVATE_KEY="$priv"
  SSH_KEY_SOURCE="generated"

  if [ -n "$OPT_SAVE_KEY" ]; then
    ( umask 077; printf '%s\n' "$priv" >"$OPT_SAVE_KEY" )
    chmod 600 "$OPT_SAVE_KEY"
    warn "Private key also written to $OPT_SAVE_KEY — delete it once copied."
  fi

  detail "Private key held for printing at the end of this run"
}

# Prints the generated private key and what to do with it. Deliberately called
# at the very end of a run - and from the error handler - rather than at the
# moment the key is created: on a full run that moment is eight steps and
# several screens of scrollback before the prompt comes back.
#
# The key body is printed flush left and without decoration on its own lines.
# Anything else - an indent, a leading "│" - is copied along with the key and
# makes the resulting file unreadable to ssh, which is the whole point of
# printing it.
#
# No argument: the key comes from GENERATED_PRIVATE_KEY, and the function is a
# no-op when no key was generated (--pubkey, or an account that already had
# authorized keys).
print_private_key() {
  [ -n "$GENERATED_PRIVATE_KEY" ] || return 0

  local title=" PRIVATE KEY - copy it now, it is stored nowhere else "
  local host="${PUBLIC_IP:-<server-ip>}"
  local width=0 line

  while IFS= read -r line; do
    [ "${#line}" -gt "$width" ] && width="${#line}"
  done <<<"$GENERATED_PRIVATE_KEY"
  [ "$width" -ge $((${#title} + 2)) ] || width=$((${#title} + 2))

  local kf="~/.ssh/${OPT_USERNAME}_key"
  ui ""
  ui "${C_KEY}${BOLD}┏━${title}$(rule_heavy $((width - ${#title} - 1)))┓${NC}"
  printf '%s\n' "$GENERATED_PRIVATE_KEY" >&3
  ui "${C_KEY}${BOLD}┗$(rule_heavy "$width")┛${NC}"
  ui ""
  ui "   ${C_STEP}${BOLD}1${NC}  Save the block above, BEGIN and END lines included, as ${C_INFO}${kf}${NC}"
  ui "   ${C_STEP}${BOLD}2${NC}  ${C_INFO}chmod 600 ${kf}${NC}"
  ui "   ${C_STEP}${BOLD}3${NC}  ${C_INFO}ssh -i ${kf} -p ${OPT_SSH_PORT} ${OPT_USERNAME}@${host}${NC}"
  ui "      ${C_MUTED}Do that from a second terminal, before you close this one.${NC}"
  log "[ui] (private key printed to console; deliberately not logged)"
}

ssh_setup_keys() {
  local existing
  existing="$(ssh_count_keys)"

  if [ -n "$OPT_PUBKEY" ]; then
    ssh_install_pubkey "$OPT_PUBKEY"
    SSH_KEY_SOURCE="provided"
    ok "Installed the supplied public key for '$OPT_USERNAME'"
    return 0
  fi

  if [ "$existing" -gt 0 ] && [ "$OPT_NEW_KEY" -eq 0 ]; then
    SSH_KEY_SOURCE="existing"
    ok "'$OPT_USERNAME' already has $existing authorized key(s); keeping them"
    detail "Use --new-key to generate an additional keypair anyway"
    return 0
  fi

  info "Generating a new ed25519 keypair for '$OPT_USERNAME'"
  ssh_generate_key
  ok "Public key installed in $(ssh_authorized_keys_path)"
}

# Build an algorithm list from a desired set intersected with what this sshd
# actually supports. Listing an algorithm the local OpenSSH does not know makes
# sshd -t fail, which would abort hardening on older releases.
ssh_supported_algos() {
  local query="$1" desired="$2" avail out=""
  avail="$(ssh -Q "$query" 2>/dev/null || true)"
  [ -n "$avail" ] || return 1
  local a
  for a in ${desired//,/ }; do
    if printf '%s\n' "$avail" | grep -qxF "$a"; then
      out="${out:+$out,}$a"
    fi
  done
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Comment out directives we own wherever else they are set, so the effective
# configuration is unambiguous. sshd uses the first value it finds, so cloud
# images that ship /etc/ssh/sshd_config.d/50-cloud-init.conf with
# "PasswordAuthentication yes" would otherwise silently win.
ssh_neutralise_conflicts() {
  local ours="$1"
  local directives='PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|PermitEmptyPasswords|KbdInteractiveAuthentication|ChallengeResponseAuthentication|X11Forwarding|MaxAuthTries|ClientAliveInterval|ClientAliveCountMax|LoginGraceTime|AllowUsers|AllowGroups|Port'
  local f
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$f" ] || continue
    [ "$f" = "$ours" ] && continue
    if grep -qE "^[[:space:]]*($directives)[[:space:]]" "$f"; then
      backup_file "$f"
      run sed -i -E "s~^[[:space:]]*($directives)[[:space:]]~# disabled by setup.sh: \\1 ~" "$f"
      detail "Neutralised overlapping directives in $f"
    fi
  done
}

ssh_ensure_include() {
  local main=/etc/ssh/sshd_config
  if [ ! -f "$main" ]; then
    warn "/etc/ssh/sshd_config is missing; is openssh-server installed?"
    return 0
  fi
  grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main" 2>/dev/null && return 0
  backup_file "$main"
  if [ "$OPT_DRY_RUN" -eq 0 ]; then
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n\n' | cat - "$main" >"${main}.new"
    mv "${main}.new" "$main"
    chmod 644 "$main"
  fi
  detail "Added the sshd_config.d Include directive"
}

# Ubuntu 24.04 and Debian 13 start sshd through ssh.socket, where the Port
# directive in sshd_config is ignored entirely. The listening port has to be
# changed on the socket unit instead.
ssh_apply_socket_port() {
  systemctl list-unit-files ssh.socket >/dev/null 2>&1 || return 0
  systemctl is-enabled ssh.socket >/dev/null 2>&1 || return 0

  local dir=/etc/systemd/system/ssh.socket.d
  local content
  content="$(printf '[Socket]\nListenStream=\nListenStream=%s' "$OPT_SSH_PORT")"
  write_file "$dir/10-port.conf" 0644 "$content" || true
  run systemctl daemon-reload
  detail "ssh.socket configured to listen on port $OPT_SSH_PORT"
  return 0
}

ssh_restart() {
  local unit="ssh"
  systemctl list-unit-files ssh.service >/dev/null 2>&1 || unit="sshd"

  if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    run systemctl restart ssh.socket || warn "Could not restart ssh.socket."
    run systemctl restart "$unit" || true
  else
    run systemctl restart "$unit" || die "sshd failed to restart. Existing sessions stay open; fix the config before disconnecting."
  fi

  # Existing sessions survive a restart, so a failure here is recoverable, but
  # it must be loud.
  if [ "$OPT_DRY_RUN" -eq 0 ] && ! systemctl is-active --quiet "$unit" \
     && ! systemctl is-active --quiet ssh.socket; then
    die "sshd is not running after the restart. Do not close this session; see $LOG_FILE"
  fi
}

# sshd -t can fail for reasons that have nothing to do with this configuration
# (a broken host key, a bad directive someone else left behind). Rejecting our
# drop-in in that case would silently discard the hardening, so when validation
# fails the baseline is tested too and only a genuine regression is fatal.
validate_sshd_config() {
  local ours="$1" err

  if err="$(sshd -t 2>&1)"; then
    detail "sshd configuration validated"
    return 0
  fi

  log "sshd -t failed with our drop-in: $err"
  mv "$ours" "${ours}.rejected"

  local baseline_err
  if baseline_err="$(sshd -t 2>&1)"; then
    # The baseline is fine, so the fault is ours. Leave SSH untouched.
    rm -f "${ours}.rejected"
    die "The generated sshd configuration was rejected: ${err}. It has been removed and SSH is unchanged."
  fi

  # The baseline is broken too, so this is pre-existing and not something the
  # drop-in caused. Keep the hardening and make the real problem visible.
  mv "${ours}.rejected" "$ours"
  warn "sshd reports a pre-existing problem: ${baseline_err}"
  warn "The hardening was applied anyway. Fix the above before relying on it."
  return 0
}

fn_ssh() {
  step "SSH access and hardening"

  ssh_create_user
  ssh_setup_keys

  local keycount
  keycount="$(ssh_count_keys)"
  if [ "$OPT_DRY_RUN" -eq 0 ] && [ "$keycount" -lt 1 ]; then
    die "No authorized keys are installed for '$OPT_USERNAME'. Refusing to harden sshd; that would lock you out."
  fi

  local ours=/etc/ssh/sshd_config.d/00-server-init.conf
  ssh_ensure_include
  ssh_neutralise_conflicts "$ours"

  local root_login="prohibit-password"
  local allow_line="AllowUsers $OPT_USERNAME"
  if [ "$OPT_USERNAME" != "root" ]; then
    root_login="no"
  fi

  local password_auth="no"
  if [ "$OPT_KEEP_PASSWORD_AUTH" -eq 1 ]; then
    password_auth="yes"
    warn "Password authentication left enabled by --keep-password-auth."
  fi

  local kex ciphers macs crypto=""
  kex="$(ssh_supported_algos kex 'sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group18-sha512,diffie-hellman-group16-sha512' || true)"
  ciphers="$(ssh_supported_algos cipher 'chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr' || true)"
  macs="$(ssh_supported_algos mac 'hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com' || true)"
  [ -n "$kex" ]     && crypto="${crypto}KexAlgorithms $kex"$'\n'
  [ -n "$ciphers" ] && crypto="${crypto}Ciphers $ciphers"$'\n'
  [ -n "$macs" ]    && crypto="${crypto}MACs $macs"$'\n'

  local content
  content="$(cat <<CONF
# Managed by setup.sh (Server Initialization Suite) — do not edit by hand.
# Generated $(date -u '+%Y-%m-%d %H:%M:%S UTC')
#
# This file sorts first inside sshd_config.d on purpose: sshd keeps the first
# value it sees for a directive, so nothing later can weaken these settings.

Port $OPT_SSH_PORT

# Authentication
PermitRootLogin $root_login
PasswordAuthentication $password_auth
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
AuthenticationMethods publickey
UsePAM yes
$allow_line

# Brute-force surface
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 30
MaxStartups 10:30:60

# Idle session cleanup
ClientAliveInterval 300
ClientAliveCountMax 2

# Reduce what a session can reach
X11Forwarding no
AllowAgentForwarding no
PermitUserEnvironment no

${crypto}
CONF
)"

  if [ "$OPT_KEEP_PASSWORD_AUTH" -eq 1 ]; then
    # A comma-separated AuthenticationMethods list requires *every* method it
    # lists, so it cannot express "either one". Remove the directive and let
    # PasswordAuthentication and PubkeyAuthentication decide on their own.
    content="$(grep -v '^AuthenticationMethods ' <<< "$content")"
  fi

  backup_file "$ours"
  write_file "$ours" 0644 "$content" || true

  # Weak Diffie-Hellman moduli are a standard hardening step and are safe to
  # drop as long as some remain.
  if [ -f /etc/ssh/moduli ] && [ "$OPT_DRY_RUN" -eq 0 ]; then
    if awk '$5 >= 3071' /etc/ssh/moduli >/tmp/moduli.safe 2>/dev/null && [ -s /tmp/moduli.safe ]; then
      run cp /tmp/moduli.safe /etc/ssh/moduli
      detail "Removed Diffie-Hellman moduli below 3072 bits"
    fi
    rm -f /tmp/moduli.safe
  fi

  if [ "$OPT_DRY_RUN" -eq 0 ]; then
    # sshd -t needs the privilege separation directory, which normally only
    # exists once sshd has run at least once.
    mkdir -p /run/sshd
    validate_sshd_config "$ours"
  fi

  ssh_apply_socket_port
  ssh_restart

  SSH_HARDENED=1
  ok "sshd hardened on port $OPT_SSH_PORT (login: $OPT_USERNAME, password auth: $password_auth)"

  if [ "$OPT_SSH_PORT" != "22" ]; then
    warn "SSH now listens on port $OPT_SSH_PORT. Verify a new session works before closing this one."
  fi
  if [ "$OPT_USERNAME" != "root" ]; then
    warn "Root SSH login is disabled. Log in as '$OPT_USERNAME' and use sudo."
  fi
}

# =============================================================================
# Component: firewall
# =============================================================================
fn_firewall() {
  step "Firewall (UFW)"

  if ! have ufw; then
    apt_ensure_lists || true
    apt_install "ufw" ufw || die "Could not install ufw."
  fi

  if [ "$OPT_RESET_FIREWALL" -eq 1 ]; then
    run_sh "ufw --force reset"
    warn "Existing UFW rules were wiped by --reset-firewall."
  fi

  run_sh "ufw default deny incoming"
  run_sh "ufw default allow outgoing"

  # Allow SSH before enabling; ufw limit also rate-limits repeat connections.
  run_sh "ufw limit ${OPT_SSH_PORT}/tcp comment 'SSH'"
  ok "SSH allowed and rate-limited on ${OPT_SSH_PORT}/tcp"

  if is_enabled dokploy; then
    run_sh "ufw allow 80/tcp comment 'HTTP (Traefik)'"
    run_sh "ufw allow 443/tcp comment 'HTTPS (Traefik)'"
    run_sh "ufw allow 443/udp comment 'HTTP/3 (Traefik)'"
    # 3000 is the admin UI, not application traffic, so it is not opened just
    # because Dokploy is being installed. --ui-public opts into that.
    if [ "$OPT_UI_PUBLIC" -eq 1 ]; then
      run_sh "ufw allow 3000/tcp comment 'Dokploy UI (--ui-public)'"
      ok "Opened 80/tcp, 443/tcp, 443/udp and 3000/tcp for Dokploy"
    else
      run_sh "ufw delete allow 3000/tcp" || true
      ok "Opened 80/tcp, 443/tcp and 443/udp for Dokploy"
    fi
  fi

  run_sh "ufw --force enable"
  ok "UFW enabled"

  # This is not a footnote. Docker inserts its own iptables rules ahead of
  # UFW's, so a published container port is reachable even when UFW claims to
  # deny it. The --ui-allow handling below is what actually restricts port 3000.
  # Stated as a detail, not a warning: it is true of every Docker host and
  # nothing about this run made it so. The warning that matters - port 3000
  # being open to the internet - is raised by the Dokploy step itself.
  detail "Docker publishes container ports around UFW; published ports stay open"
}

# =============================================================================
# Component: fail2ban
# =============================================================================
fn_fail2ban() {
  step "fail2ban"

  # python3-systemd is required for the systemd backend. Ubuntu 24.04 and
  # Debian 12 no longer guarantee /var/log/auth.log exists, so the file backend
  # fails at startup; reading the journal instead is the reliable option.
  apt_ensure_lists || true
  apt_install "fail2ban" fail2ban python3-systemd || die "Could not install fail2ban."

  local jail=/etc/fail2ban/jail.local
  local content
  content="$(cat <<CONF
# Managed by setup.sh (Server Initialization Suite).

[DEFAULT]
# Read the systemd journal rather than /var/log/auth.log, which does not exist
# on distributions that ship without rsyslog.
backend = systemd

bantime  = 1h
findtime = 10m
maxretry = 4
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = $OPT_SSH_PORT
maxretry = 3
bantime  = 1h

[recidive]
# Hosts that keep coming back after a ban get a much longer one.
enabled  = true
backend  = systemd
logpath  = /var/log/fail2ban.log
bantime  = 1w
findtime = 1d
maxretry = 5
CONF
)"

  write_file "$jail" 0644 "$content" || true

  # The recidive jail reads fail2ban's own log file, so it must exist.
  run touch /var/log/fail2ban.log

  run systemctl enable fail2ban || true
  if run systemctl restart fail2ban; then
    ok "fail2ban active, watching SSH on port $OPT_SSH_PORT"
  else
    warn "fail2ban failed to start. See 'journalctl -u fail2ban' and $LOG_FILE"
  fi
}
# =============================================================================
# Component: hardening
# =============================================================================
fn_hardening() {
  step "Kernel and log hardening"

  harden_sysctl
  cap_journal
  lock_root_password
}

# Network-stack settings that are safe on a Docker host.
#
# Two deliberate omissions. net.ipv4.ip_forward is not touched: Docker turns it
# on for itself, and a file here setting it to 0 would silently break every
# container's networking on the next boot. rp_filter is set to 2 (loose) rather
# than 1 (strict), because strict mode drops the asymmetric return traffic that
# Swarm's ingress mesh and multi-homed hosts legitimately produce; loose mode
# still discards obviously spoofed source addresses.
harden_sysctl() {
  local conf
  conf="$(cat <<'CONF'
# Managed by setup.sh (Server Initialization Suite).
# Deliberately absent: net.ipv4.ip_forward - Docker manages it.

# SYN flood mitigation.
net.ipv4.tcp_syncookies = 1

# Loose reverse-path filtering. Strict (1) breaks Docker Swarm ingress.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Ignore anything that tries to rewrite this host's routing table.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# This host is not a router.
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Source routing lets a caller choose the return path. Nothing legitimate does.
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Do not answer broadcast pings, do not trust forged ICMP errors.
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Do not hand kernel addresses to unprivileged readers.
kernel.kptr_restrict = 2

# Classic /tmp symlink and hardlink races.
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
CONF
)"

  if write_file /etc/sysctl.d/99-server-init-hardening.conf 0644 "$conf"; then
    if run sysctl --system; then
      ok "Kernel network hardening applied"
    else
      warn "Some sysctl settings were rejected by this kernel; see $LOG_FILE"
    fi
  else
    detail "Kernel hardening already in place"
  fi
}

# Container logs are already capped in daemon.json, but the journal is not. Its
# default ceiling is a share of the filesystem, so on a large disk it will grow
# into tens of gigabytes of logs nobody reads before anything stops it.
cap_journal() {
  local conf
  conf="$(cat <<'CONF'
# Managed by setup.sh (Server Initialization Suite).
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
SystemKeepFree=1G
MaxRetentionSec=1month
CONF
)"

  if write_file /etc/systemd/journald.conf.d/99-server-init.conf 0644 "$conf"; then
    run systemctl restart systemd-journald || warn "Could not restart systemd-journald."
    ok "Journal capped at 500 MB, one month retention"
  else
    detail "Journal limits already in place"
  fi
}

# Disabling root's SSH login leaves its password untouched, so a console, a
# rescue shell or a serial port is still a password prompt. Only lock it once
# the replacement account is demonstrably usable, and never when root is the
# account being configured.
lock_root_password() {
  if [ "$OPT_USERNAME" = "root" ]; then
    detail "Root is the login account; leaving its password alone"
    return 0
  fi

  local home keys=0
  home="$(getent passwd "$OPT_USERNAME" 2>/dev/null | cut -d: -f6 || true)"
  if [ -n "$home" ] && [ -f "$home/.ssh/authorized_keys" ]; then
    keys="$(grep -cE '^(ssh-|ecdsa-|sk-)' "$home/.ssh/authorized_keys" 2>/dev/null || true)"
  fi
  if [ "${keys:-0}" -lt 1 ]; then
    detail "'$OPT_USERNAME' has no authorized keys yet; leaving root's password alone"
    return 0
  fi

  if [ "$(passwd -S root 2>/dev/null | awk '{print $2}')" = "L" ]; then
    detail "Root password already locked"
    return 0
  fi

  if run passwd -l root; then
    ok "Root password locked; '$OPT_USERNAME' with sudo is the only way in"
  else
    warn "Could not lock the root password."
  fi
}


# =============================================================================
# Component: swap
#
# Small VPS instances routinely run out of memory during container builds. A
# swapfile is the cheapest fix and costs nothing when unused.
# =============================================================================
fn_swap() {
  step "Swap"

  local existing
  existing="$(swapon --show --noheadings 2>/dev/null | wc -l)"
  if [ "${existing:-0}" -gt 0 ]; then
    ok "Swap already configured; leaving it alone"
    return 0
  fi

  local mem_mb size_mb
  mem_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  if [ "$mem_mb" -ge 8192 ]; then
    ok "${mem_mb} MB of RAM; no swapfile needed"
    return 0
  fi
  size_mb=$((mem_mb < 2048 ? 2048 : mem_mb))

  local avail_mb
  avail_mb="$(df --output=avail -m / | tail -n1 | tr -d ' ')"
  if [ "$avail_mb" -lt $((size_mb + 2048)) ]; then
    warn "Not enough free disk space for a ${size_mb} MB swapfile; skipping."
    return 0
  fi

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    detail "Would create a ${size_mb} MB swapfile at /swapfile"
    return 0
  fi

  run_spin "Creating a ${size_mb} MB swapfile" \
    bash -c "fallocate -l ${size_mb}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=${size_mb}"
  run chmod 600 /swapfile

  # Swap is a convenience, not a dependency. A filesystem that refuses
  # swapfiles must not abort the rest of the run.
  if ! run mkswap /swapfile || ! run swapon /swapfile; then
    run rm -f /swapfile
    warn "This filesystem refused a swapfile; continuing without swap."
    return 0
  fi

  grep -qE '^/swapfile\b' /etc/fstab || run_sh "printf '/swapfile none swap sw 0 0\n' >> /etc/fstab"
  if write_file /etc/sysctl.d/99-swap.conf 0644 "vm.swappiness = 10
vm.vfs_cache_pressure = 50"; then
    run sysctl --system || warn "Could not apply the swappiness settings."
  fi

  ok "${size_mb} MB swapfile active"
}

# =============================================================================
# Component: docker
#
# Docker is installed from Docker's own apt repository rather than left to
# Dokploy's installer, which pins an exact version and apt-mark holds it.
# Installing it first means Dokploy detects Docker and skips that entirely.
# =============================================================================
fn_docker() {
  step "Docker"

  # Legacy packages conflict with docker-ce and must go first.
  local legacy=(docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc)
  local installed=()
  local p
  for p in "${legacy[@]}"; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "^install ok installed"; then
      installed+=("$p")
    fi
  done
  if [ ${#installed[@]} -gt 0 ]; then
    detail "Removing conflicting packages: ${installed[*]}"
    run apt-get remove "${APT_OPTS[@]}" "${installed[@]}" || true
  fi

  if have docker && docker version >/dev/null 2>&1; then
    ok "Docker already installed: $(docker --version 2>/dev/null || echo unknown)"
  else
    local repo_os="$OS_ID"
    case "$OS_ID" in
      debian|ubuntu) ;;
      *) repo_os="debian"; case " ${ID_LIKE:-} " in *ubuntu*) repo_os="ubuntu" ;; esac ;;
    esac

    run install -m 0755 -d /etc/apt/keyrings
    run_spin "Fetching the Docker signing key" \
      retry curl -fsSL --connect-timeout 15 "https://download.docker.com/linux/${repo_os}/gpg" \
      -o /etc/apt/keyrings/docker.asc \
      || die "Could not download the Docker GPG key."
    run chmod a+r /etc/apt/keyrings/docker.asc

    write_file /etc/apt/sources.list.d/docker.list 0644 \
      "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${repo_os} ${OS_CODENAME} stable" || true
    # Remove the deb822 file a previous version of this script may have written.
    run rm -f /etc/apt/sources.list.d/docker.sources

    apt_update || die "apt-get update failed after adding the Docker repository."
    apt_install "Docker Engine" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      || die "Docker installation failed. See $LOG_FILE"
    ok "Docker installed: $(docker --version 2>/dev/null || echo unknown)"
  fi

  # Unbounded container logs are a classic way for an unattended server to fill
  # its disk months later.
  configure_docker_daemon

  run systemctl enable docker || true
  run systemctl start docker || die "Docker failed to start."

  if [ "$OPT_USERNAME" != "root" ]; then
    run usermod -aG docker "$OPT_USERNAME" || true
    detail "'$OPT_USERNAME' added to the docker group (effective at next login)"
  fi
}

configure_docker_daemon() {
  local f=/etc/docker/daemon.json
  local desired='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  },
  "live-restore": false
}'

  if [ ! -f "$f" ]; then
    write_file "$f" 0644 "$desired" && detail "Container log rotation configured"
    return 0
  fi

  # An existing daemon.json is merged rather than replaced, so Dokploy's or the
  # operator's own settings survive a re-run.
  if have jq && [ "$OPT_DRY_RUN" -eq 0 ]; then
    local merged
    if merged="$(jq -s '.[0] * .[1]' "$f" <(printf '%s' "$desired") 2>/dev/null)" && [ -n "$merged" ]; then
      if [ "$merged" != "$(cat "$f")" ]; then
        backup_file "$f"
        printf '%s\n' "$merged" >"$f"
        run systemctl restart docker || warn "Docker did not restart cleanly after the daemon.json update."
        detail "Merged log rotation settings into the existing daemon.json"
      fi
      return 0
    fi
  fi
  warn "Left the existing /etc/docker/daemon.json untouched; container log rotation not applied."
}

# =============================================================================
# Component: dokploy
# =============================================================================
dokploy_is_installed() {
  have docker || return 1
  docker info 2>/dev/null | grep -q 'Swarm: active' || return 1
  [ -n "$(docker service ls --filter name=dokploy --quiet 2>/dev/null)" ]
}

# Dokploy's installer aborts if anything holds 80, 443 or 3000. Reporting which
# process holds the port is far more useful than its bare error message.
dokploy_check_ports() {
  local port busy=0
  for port in 80 443 3000; do
    if ss -tulnp 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
      local holder
      holder="$(ss -tulnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -n1 | sed 's/.*users:((//' | cut -d, -f1 | tr -d '("')"
      warn "Port ${port} is already in use by: ${holder:-unknown}"
      busy=1
    fi
  done
  return $busy
}

fn_dokploy() {
  step "Dokploy"

  if ! have docker; then
    if [ "$OPT_DRY_RUN" -eq 1 ]; then
      detail "Would install Dokploy once Docker is present"
      return 0
    fi
    warn "Docker is not installed, so Dokploy cannot be installed. Re-run without --exclude=docker."
    return 0
  fi

  if dokploy_is_installed; then
    if [ "$OPT_REINSTALL_DOKPLOY" -eq 0 ]; then
      ok "Dokploy is already installed; leaving it untouched"
      detail "Re-running the installer would leave and re-initialise Docker Swarm"
      detail "Use --reinstall-dokploy to force it, or 'dokploy update' to upgrade"
      DOKPLOY_INSTALLED=1
      restrict_dokploy_ui
      return 0
    fi
    warn "Reinstalling Dokploy: Docker Swarm will be left and re-initialised."
    detail "Removing the existing Dokploy services so the ports are free"
    run docker service rm dokploy dokploy-postgres || true
    run docker rm -f dokploy-traefik || true
    sleep 5
  fi

  if ! dokploy_check_ports; then
    warn "Skipping Dokploy because required ports are occupied. Free 80, 443 and 3000, then re-run with --only=dokploy."
    return 0
  fi

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    # Deliberately does not set DOKPLOY_INSTALLED: the summary reports what is
    # on the machine, and a dry run installs nothing.
    detail "Would run the Dokploy installer"
    return 0
  fi

  local installer
  installer="$(mktemp)"
  run_spin "Downloading the Dokploy installer" \
    retry curl -fsSL --connect-timeout 20 https://dokploy.com/install.sh -o "$installer" \
    || { rm -f "$installer"; die "Could not download the Dokploy installer."; }

  # Sanity check: a captive portal or error page must not be piped into a shell.
  if ! head -n1 "$installer" | grep -q '^#!'; then
    rm -f "$installer"
    die "The downloaded Dokploy installer is not a shell script. Aborting rather than executing it."
  fi

  info "Running the Dokploy installer (pulls several images; expect 2-5 minutes)"
  if run_spin "Installing Dokploy" bash "$installer"; then
    DOKPLOY_INSTALLED=1
    ok "Dokploy installed"
  else
    rm -f "$installer"
    die "The Dokploy installer failed. See $LOG_FILE"
  fi
  rm -f "$installer"

  wait_for_dokploy
  restrict_dokploy_ui
}

# The swarm service needs a moment to pull and start. Confirming the UI answers
# turns a silent half-finished install into a visible warning.
wait_for_dokploy() {
  local waited=0
  while [ $waited -lt 90 ]; do
    if curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:3000 2>/dev/null; then
      ok "Dokploy UI responding on port 3000"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  warn "Dokploy did not answer on port 3000 within 90s. Check 'docker service ls' and 'docker service logs dokploy'."
  return 0
}

# Restrict the Dokploy UI to specific sources.
#
# UFW cannot do this: Docker's iptables rules run first. The rule has to live in
# the DOCKER-USER chain, and is re-applied at boot by a systemd unit because
# iptables rules do not persist.
# Port 3000 is closed to the internet unless somebody asks for it.
#
# The first visitor to reach an unclaimed Dokploy UI becomes its administrator,
# which makes "reachable by default" the wrong default at any scale: the window
# between this script finishing and a human logging in is exactly the window an
# internet-wide scanner needs. Loopback is unaffected either way - a published
# port reached over 127.0.0.1 never traverses the FORWARD chain - so an SSH
# tunnel still works with no rules at all.
restrict_dokploy_ui() {
  if [ "$OPT_UI_PUBLIC" -eq 1 ]; then
    warn "The Dokploy UI on port 3000 is reachable from the whole internet (--ui-public)."
    detail "Whoever opens it first creates the admin account. Do it now."
    return 0
  fi

  local script=/usr/local/sbin/dokploy-ui-firewall
  local cidrs="$OPT_UI_ALLOW"
  local body
  body="$(cat <<SCRIPT
#!/usr/bin/env bash
# Managed by setup.sh. Restricts the Dokploy UI (port 3000) to allowed sources.
# Docker bypasses UFW, so the rule must sit in the DOCKER-USER chain.
set -euo pipefail

ALLOW="$cidrs"

iptables -N DOKPLOY-UI 2>/dev/null || iptables -F DOKPLOY-UI
for cidr in \${ALLOW//,/ }; do
  iptables -A DOKPLOY-UI -s "\$cidr" -j RETURN
done
iptables -A DOKPLOY-UI -j DROP

iptables -C DOCKER-USER -p tcp --dport 3000 -j DOKPLOY-UI 2>/dev/null \\
  || iptables -I DOCKER-USER -p tcp --dport 3000 -j DOKPLOY-UI
SCRIPT
)"

  write_file "$script" 0755 "$body" || true

  local unit
  unit="$(cat <<UNIT
[Unit]
Description=Restrict the Dokploy UI port to allowed sources
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$script

[Install]
WantedBy=multi-user.target
UNIT
)"
  write_file /etc/systemd/system/dokploy-ui-firewall.service 0644 "$unit" || true

  run systemctl daemon-reload
  run systemctl enable dokploy-ui-firewall.service || true
  if run systemctl restart dokploy-ui-firewall.service; then
    if [ -n "$OPT_UI_ALLOW" ]; then
      ok "Dokploy UI on port 3000 restricted to: $OPT_UI_ALLOW"
    else
      ok "Dokploy UI on port 3000 closed to the network"
      detail "Reach it over an SSH tunnel, the Cloudflare tunnel, or reopen it with:"
      detail "  sudo ./setup.sh --only=dokploy --ui-allow=<your.ip>/32"
    fi
  else
    warn "Could not apply the port 3000 restriction; the UI may be publicly reachable."
  fi
}

# =============================================================================
# Component: cloudflared
# =============================================================================
fn_cloudflared() {
  step "Cloudflare Tunnel (cloudflared)"

  if have cloudflared; then
    ok "cloudflared already installed: $(cloudflared --version 2>/dev/null | head -n1 || true)"
    return 0
  fi

  run install -m 0755 -d /usr/share/keyrings
  run_spin "Fetching the Cloudflare signing key" \
    retry curl -fsSL --connect-timeout 15 https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
    -o /usr/share/keyrings/cloudflare-public-v2.gpg \
    || { warn "Could not download the Cloudflare GPG key; skipping cloudflared."; return 0; }
  run chmod a+r /usr/share/keyrings/cloudflare-public-v2.gpg

  write_file /etc/apt/sources.list.d/cloudflared.list 0644 \
    "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" || true

  if ! apt_update; then
    warn "apt-get update failed after adding the Cloudflare repository; skipping cloudflared."
    return 0
  fi

  if apt_install "cloudflared" cloudflared; then
    ok "cloudflared installed: $(cloudflared --version 2>/dev/null | head -n1 || echo unknown)"
    detail "Connect it with: sudo cloudflared service install <tunnel-token>"
  else
    warn "cloudflared installation failed; continuing without it."
  fi
}

# =============================================================================
# Component: bun
# =============================================================================
fn_bun() {
  step "Bun runtime"

  local home="$SSH_USER_HOME"
  [ -n "$home" ] || home="$(getent passwd "$OPT_USERNAME" 2>/dev/null | cut -d: -f6 || true)"
  [ -n "$home" ] || { warn "Could not resolve a home directory for Bun; skipping."; return 0; }

  if [ -x "$home/.bun/bin/bun" ]; then
    ok "Bun already installed for '$OPT_USERNAME': $("$home/.bun/bin/bun" --version 2>/dev/null || echo unknown)"
    return 0
  fi

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    detail "Would install Bun into $home/.bun"
    return 0
  fi

  if run_spin "Installing Bun for '$OPT_USERNAME'" \
      runuser -u "$OPT_USERNAME" -- bash -c 'curl -fsSL https://bun.sh/install | bash'; then
    ok "Bun installed: $("$home/.bun/bin/bun" --version 2>/dev/null || echo unknown)"
    detail "Available in new shells; run 'source ~/.bashrc' in this one"
  else
    warn "Bun installation failed; continuing without it."
  fi
}

# =============================================================================
# Component: unattended-upgrades
#
# Runs last, so it can never contend with this script for the apt lock.
#
# The configuration deliberately restricts itself to the security pocket, never
# reboots on its own, and excludes the Docker packages: an automatic Docker or
# containerd upgrade restarts the daemon underneath running containers.
# =============================================================================
fn_unattended() {
  step "Automatic security updates"

  apt_ensure_lists || true
  apt_install "unattended-upgrades" unattended-upgrades apt-listchanges || {
    warn "Could not install unattended-upgrades; skipping."
    return 0
  }

  local origins
  if [ "$OS_ID" = "ubuntu" ]; then
    # Origins-Pattern entries must be key=value pairs. The shorter
    # "Ubuntu:noble-security" form belongs to Allowed-Origins, and putting it
    # here makes unattended-upgrade fail to parse its own configuration.
    origins='        "origin=Ubuntu,archive=${distro_codename}-security";
        "origin=UbuntuESMApps,archive=${distro_codename}-apps-security";
        "origin=UbuntuESM,archive=${distro_codename}-infra-security";'
  else
    origins='        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";'
  fi

  # Installing a kernel patch does not activate it. Without a reboot the host
  # keeps running the vulnerable image indefinitely, and across a fleet nobody
  # reboots by hand - so the choice is an explicit maintenance window or an
  # explicit decision to stay on the old kernel.
  local reboot_policy
  if [ -n "$OPT_AUTO_REBOOT" ]; then
    reboot_policy="// Reboot inside the window given by --auto-reboot.
Unattended-Upgrade::Automatic-Reboot \"true\";
Unattended-Upgrade::Automatic-Reboot-WithUsers \"true\";
Unattended-Upgrade::Automatic-Reboot-Time \"${OPT_AUTO_REBOOT}\";"
  else
    reboot_policy='// Never reboot on its own; pass --auto-reboot=HH:MM to allow it.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";'
  fi

  local conf
  conf="$(cat <<CONF
// Managed by setup.sh (Server Initialization Suite).
// Security updates only, Docker left alone.

// #clear discards whatever the shipped 50unattended-upgrades put in these
// lists, so the effective configuration is exactly what is written below
// rather than the union of both files. Allowed-Origins is cleared as well:
// unattended-upgrade merges it with Origins-Pattern, and Ubuntu's default
// entry for the plain release pocket would let through non-security updates.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
$origins
};

// Upgrading these restarts the Docker daemon under running containers.
#clear Unattended-Upgrade::Package-Blacklist;
Unattended-Upgrade::Package-Blacklist {
        "docker-ce";
        "docker-ce-cli";
        "containerd.io";
        "docker-buildx-plugin";
        "docker-compose-plugin";
};

$reboot_policy

// Apply upgrades one at a time so an interruption leaves a recoverable state.
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";

// Stop /boot filling up with old kernels, a common cause of later apt failures.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Virtual machines report no AC power.
Unattended-Upgrade::OnlyOnACPower "false";
Unattended-Upgrade::Skip-Updates-On-Metered-Connections "true";

// Keep the config files that are already on disk.
Dpkg::Options {
        "--force-confdef";
        "--force-confold";
};

Unattended-Upgrade::SyslogEnable "true";
CONF
)"

  write_file /etc/apt/apt.conf.d/52-server-init 0644 "$conf" || true

  local periodic
  periodic="$(cat <<'CONF'
// Managed by setup.sh (Server Initialization Suite).
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
CONF
)"
  write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 "$periodic" || true

  if [ "$OPT_DRY_RUN" -eq 0 ]; then
    if unattended-upgrade --dry-run --debug >>"$LOG_FILE" 2>&1; then
      detail "Configuration validated with a dry run"
    else
      warn "'unattended-upgrades --dry-run' reported a problem; see $LOG_FILE"
    fi
  fi

  run systemctl enable --now unattended-upgrades.service || true
  if [ -n "$OPT_AUTO_REBOOT" ]; then
    ok "Security updates applied automatically; reboots at ${OPT_AUTO_REBOOT} when needed"
  else
    ok "Security updates applied automatically; reboots stay manual"
    detail "Kernel patches need a reboot; --auto-reboot=HH:MM schedules one"
  fi
}

# =============================================================================
# Component: verify
#
# The last chance to notice a lockout while there is still a working shell to
# fix it from. Everything here is read-only: it proves the door opens rather
# than assuming the previous steps left it that way.
# =============================================================================
fn_verify() {
  step "Verify access"

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    detail "Would verify sshd, the firewall and a real key login"
    return 0
  fi

  if run_sh "ss -ltnH 'sport = :${OPT_SSH_PORT}' | grep -q ."; then
    ok "sshd is listening on port ${OPT_SSH_PORT}"
  else
    warn "Nothing is listening on port ${OPT_SSH_PORT}. Do not close this session; check 'systemctl status ssh'."
  fi

  if have ufw && run_sh "ufw status | grep -qi '^Status: active'"; then
    detail "UFW active"
  else
    detail "UFW not active"
  fi

  verify_key_login
}

# Prove the generated key actually authenticates, by using it. A key that was
# written to the wrong path, into a home directory with the wrong ownership, or
# under an AllowUsers line that excludes the account, all look identical to a
# successful run until the operator disconnects.
verify_key_login() {
  if [ -z "$GENERATED_PRIVATE_KEY" ]; then
    detail "No generated key to test; skipping the login check"
    return 0
  fi
  if ! have ssh; then
    detail "No ssh client available; skipping the login check"
    return 0
  fi

  local tmpdir kf rc=0
  tmpdir="$(mktemp -d)"
  chmod 700 "$tmpdir"
  kf="$tmpdir/key"
  ( umask 077; printf '%s\n' "$GENERATED_PRIVATE_KEY" >"$kf" )

  # Loopback only: it exercises sshd's real configuration without depending on
  # the host being reachable from outside, and 127.0.0.1 is in fail2ban's
  # ignoreip so a failed attempt cannot ban the machine from itself.
  run_sh "ssh -i '$kf' -p '$OPT_SSH_PORT' \
    -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -o LogLevel=ERROR \
    '${OPT_USERNAME}@127.0.0.1' true" || rc=$?

  have shred && shred -u "$kf" 2>/dev/null || true
  rm -rf "$tmpdir"

  if [ $rc -eq 0 ]; then
    ok "The generated key authenticates as '$OPT_USERNAME'"
  else
    warn "The generated key did not authenticate over loopback. Keep this session open and check 'journalctl -u ssh'."
  fi
  return 0
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

summary() {
  local elapsed=$((SECONDS - START_TIME))
  local mins=$((elapsed / 60)) secs=$((elapsed % 60))

  local bun_bin="${SSH_USER_HOME:-/root}/.bun/bin/bun"
  local bar="Setup complete in ${mins}m ${secs}s"
  local fill=$(( TERM_COLS - ${#bar} - 6 ))
  [ "$fill" -ge 0 ] || fill=0
  ui ""
  ui " ${C_OK}${BOLD}━━ ${bar} $(rule_heavy "$fill")${NC}"
  ui ""

  # Everything else the old summary repeated - each version, the SSH settings,
  # the warnings, the next steps - was already said once, in the step that did
  # the work. What is left is the roll call and the two addresses, because
  # those are the only things a reader has to carry away from the run.
  para "" "$(installed_list)"
  ui ""

  if [ -n "$PUBLIC_IP" ]; then
    row "Connect" "$C_INFO" "ssh -p ${OPT_SSH_PORT} ${OPT_USERNAME}@${PUBLIC_IP}"
    is_private_ip "$PUBLIC_IP" && row "" "$C_MUTED" "that is a private address — reachable from this network only" || true
    if [ "$DOKPLOY_INSTALLED" -eq 1 ]; then
      if [ "$OPT_UI_PUBLIC" -eq 1 ]; then
        row "Dokploy" "$C_INFO" "http://${PUBLIC_IP}:3000"
        row "" "$C_WARN" "open to the internet — claim the admin account now"
      elif [ -n "$OPT_UI_ALLOW" ]; then
        row "Dokploy" "$C_INFO" "http://${PUBLIC_IP}:3000"
        row "" "$C_MUTED" "reachable from ${OPT_UI_ALLOW} only"
      else
        row "Dokploy" "$C_INFO" "ssh -L 3000:localhost:3000 -p ${OPT_SSH_PORT} ${OPT_USERNAME}@${PUBLIC_IP}"
        row "" "$C_MUTED" "then open http://localhost:3000 (port 3000 is closed)"
      fi
    fi
  fi
  row "Log" "$C_MUTED" "$LOG_FILE"

  # Last of all, so the key and its instructions are still on screen when the
  # run ends and nothing has to be scrolled back for.
  print_private_key
  ui ""
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
main() {
  parse_args "$@"
  setup_colors

  # fd 3 is the console. Everything a command prints goes to the log instead.
  exec 3>&1

  validate_args

  LOG_FILE="/var/log/server-init-$(date +%Y%m%d-%H%M%S).log"
  if ! ( umask 077; : >"$LOG_FILE" ) 2>/dev/null; then
    LOG_FILE="$(mktemp -t server-init-XXXXXX.log)"
  fi
  log "$SCRIPT_NAME v$SCRIPT_VERSION starting; args: $*"

  preflight

  # Count the steps that will actually run, so [n/total] is honest.
  local entry name
  STEP_TOTAL=0
  for entry in "${COMPONENTS[@]}"; do
    is_enabled "${entry%%:*}" && STEP_TOTAL=$((STEP_TOTAL + 1))
  done
  [ "$STEP_TOTAL" -gt 0 ] || die "Every component was excluded; nothing to do."

  # Needed by fn_bun and the summary even when the ssh component is skipped.
  if id -u "$OPT_USERNAME" >/dev/null 2>&1; then
    SSH_USER_HOME="$(getent passwd "$OPT_USERNAME" 2>/dev/null | cut -d: -f6 || true)"
  fi

  for entry in "${COMPONENTS[@]}"; do
    name="${entry%%:*}"
    if is_enabled "$name"; then
      "fn_${name}"
    else
      step_skipped "$name" "${entry#*:}"
    fi
  done

  PUBLIC_IP="$(detect_public_ip)"

  CURRENT_STEP="summary"
  summary
}

main "$@"
