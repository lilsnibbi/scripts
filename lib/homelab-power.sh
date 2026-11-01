#!/usr/bin/env bash
# Ubuntu Server laptop power settings. Run as root: sudo bash homelab-power.sh
# Requires systemd, udev and iw (install the Ubuntu iw package for Wi-Fi).
#
# Undo as root:
#   systemctl disable homelab-cpu-power.service homelab-wifi-power.service
#   rm -f /etc/systemd/logind.conf.d/99-homelab-power.conf \
#     /etc/udev/rules.d/99-homelab-wifi-power.rules \
#     /etc/systemd/system/homelab-{cpu,wifi}-power.service \
#     /usr/local/sbin/homelab-power-apply
#   systemctl daemon-reload
#   udevadm control --reload-rules
#   systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
#   reboot
# Only unmask targets that were not already masked before running this script.
# This script does not record prior state.
# Other power managers can override these settings; undoing does not restore a
# previously selected CPU governor or Wi-Fi power-saving state.
set -Eeuo pipefail

log() { printf '[%-8s] %s\n' "$1" "$2"; }
step=preflight
on_error() {
    local status=$? line=$1
    log FAILED "$step: stopped at script line $line (exit $status); changes already applied remain in place." >&2
    exit "$status"
}
trap 'on_error "$LINENO"' ERR

log STEP 'Checking requirements (no reboot or network restart will be performed).'
if (( EUID != 0 )); then
    log FAILED 'Root is required. Run: sudo bash homelab-power.sh' >&2
    exit 1
fi
if ! command -v systemctl >/dev/null || ! command -v udevadm >/dev/null || [[ ! -d /run/systemd/system ]]; then
    log FAILED 'A running systemd system and udevadm are required.' >&2
    exit 1
fi
log VERIFIED 'Running as root with systemd and udevadm available.'

step='Creating configuration directories'
install -d -m 755 /etc/systemd/logind.conf.d /etc/systemd/system /etc/udev/rules.d /usr/local/sbin
staging=$(mktemp -d)
trap 'rm -rf -- "$staging"' EXIT

# Stage each file so repeat runs can distinguish identical content and mode.
write_file() {
    local destination=$1 mode=$2 description=$3
    step="Installing $description"
    cat > "$staging/file"
    if [[ -f "$destination" ]] && cmp -s "$staging/file" "$destination" && [[ $(stat -c %a "$destination") == "$mode" ]]; then
        log ALREADY "$description: $destination has the requested content and permissions."
    else
        install -m "$mode" "$staging/file" "$destination"
        log APPLIED "$description: installed $destination (mode $mode)."
    fi
}

log STEP 'Saving persistent lid and idle settings.'
write_file /etc/systemd/logind.conf.d/99-homelab-power.conf 644 'Lid/idle drop-in' <<'CONFIG'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
CONFIG
log PENDING 'Lid-close on battery/AC/docked and logind idle action: ignore is saved; reboot to load it. Running logind was not restarted.'

write_file /usr/local/sbin/homelab-power-apply 755 'CPU/Wi-Fi helper' <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
log() { printf '[%-8s] %s\n' "$1" "$2"; }
trap 'status=$?; log FAILED "Unexpected helper error at line $LINENO (exit $status)." >&2; exit "$status"' ERR
case "${1:-}" in
    cpu)
        log STEP 'Inspecting CPU frequency policies.'
        shopt -s nullglob
        policies=(/sys/devices/system/cpu/cpufreq/policy*)
        applied=0 already=0 skipped=0 failed=0
        if ((${#policies[@]} == 0)); then
            log SKIPPED 'CPU governor: no cpufreq policies exposed by this kernel/hardware.'
        fi
        for policy in "${policies[@]}"; do
            name=${policy##*/}
            if ! available=$(cat "$policy/scaling_available_governors"); then
                log SKIPPED "$name: cannot read available governors; no change made."
                skipped=$((skipped + 1))
                continue
            fi
            if [[ " $available " != *' performance '* ]]; then
                log SKIPPED "$name: performance unavailable (available: $available)."
                skipped=$((skipped + 1))
                continue
            fi
            if ! before=$(cat "$policy/scaling_governor"); then
                log FAILED "$name: cannot read current governor."
                failed=$((failed + 1))
                continue
            fi
            if [[ "$before" == performance ]]; then
                log ALREADY "$name: governor=performance (read from sysfs)."
                already=$((already + 1))
                continue
            fi
            if ! printf 'performance\n' > "$policy/scaling_governor"; then
                log FAILED "$name: could not write performance (previous governor: $before)."
                failed=$((failed + 1))
                continue
            fi
            if ! after=$(cat "$policy/scaling_governor"); then
                log FAILED "$name: write completed, but verification read failed."
                failed=$((failed + 1))
            elif [[ "$after" != performance ]]; then
                log FAILED "$name: requested performance, verification returned $after."
                failed=$((failed + 1))
            else
                log APPLIED "$name: $before -> performance; verified in sysfs."
                applied=$((applied + 1))
            fi
        done
        log SUMMARY "CPU: ${#policies[@]} policies; $applied applied, $already already set, $skipped skipped, $failed failed."
        (( failed == 0 )) || exit 1
        ;;
    wifi)
        iface=wlp0s20f3
        log STEP "Inspecting Wi-Fi power saving on $iface."
        if [[ ! -d "/sys/class/net/$iface" ]]; then
            log SKIPPED "$iface: interface absent; cannot apply or verify now. The boot service and device rule remain configured."
            exit 0
        fi
        if ! command -v iw >/dev/null; then
            log FAILED "$iface: iw is missing. Install it with 'sudo apt-get install iw', then run 'sudo systemctl restart homelab-wifi-power.service'." >&2
            exit 1
        fi
        if before=$(iw dev "$iface" get power_save); then
            if [[ "$before" == *'Power save: off'* ]]; then
                log ALREADY "$iface: power saving is off (verified with iw)."
                exit 0
            fi
            log INFO "$iface: current state: $before"
        else
            log INFO "$iface: initial state could not be read; attempting to disable and verify."
        fi
        if ! iw dev "$iface" set power_save off; then
            log FAILED "$iface: iw could not disable power saving; see driver error above." >&2
            exit 1
        fi
        if ! state=$(iw dev "$iface" get power_save); then
            log FAILED "$iface: disable command completed, but iw verification failed." >&2
            exit 1
        fi
        if [[ "$state" != *'Power save: off'* ]]; then
            log FAILED "$iface: requested off, verification returned: $state" >&2
            exit 1
        fi
        log APPLIED "$iface: power saving disabled; verified with iw ($state)."
        ;;
    *) log FAILED 'Usage: homelab-power-apply {cpu|wifi}' >&2; exit 2 ;;
esac
HELPER

write_file /etc/systemd/system/homelab-cpu-power.service 644 'CPU boot service' <<'UNIT'
[Unit]
Description=Set available CPU policies to performance

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-power-apply cpu

[Install]
WantedBy=multi-user.target
UNIT

write_file /etc/systemd/system/homelab-wifi-power.service 644 'Wi-Fi boot service' <<'UNIT'
[Unit]
Description=Disable Wi-Fi power saving on wlp0s20f3
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-power-apply wifi

[Install]
WantedBy=multi-user.target
UNIT

# Retry when the interface appears after boot, without waiting for network-online.
write_file /etc/udev/rules.d/99-homelab-wifi-power.rules 644 'Wi-Fi device rule' <<'RULE'
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlp0s20f3", TAG+="systemd", ENV{SYSTEMD_WANTS}+="homelab-wifi-power.service"
RULE

step='Reloading systemd units and udev rules'
log STEP "$step."
systemctl daemon-reload
log APPLIED 'systemd unit definitions reloaded.'
udevadm control --reload-rules
log APPLIED 'udev rules reloaded; the Wi-Fi rule is available for future interface add events.'

log STEP 'Disabling sleep, suspend and hibernate targets persistently.'
for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    step="Masking $target"
    if [[ $(readlink "/etc/systemd/system/$target" || true) == /dev/null ]]; then
        log ALREADY "$target: persistent mask already present."
    else
        systemctl mask "$target"
        log APPLIED "$target: mask command completed."
    fi
    if [[ $(readlink "/etc/systemd/system/$target" || true) != /dev/null ]]; then
        log FAILED "$target: persistent mask could not be verified." >&2
        exit 1
    fi
    log VERIFIED "$target: /etc/systemd/system/$target -> /dev/null."
done

log STEP 'Enabling CPU and Wi-Fi services for subsequent boots.'
for service in homelab-cpu-power.service homelab-wifi-power.service; do
    step="Enabling $service"
    if [[ $(systemctl is-enabled "$service" 2>/dev/null || true) == enabled ]]; then
        log ALREADY "$service: enabled for boot."
    else
        systemctl enable "$service"
        log APPLIED "$service: enable command completed."
    fi
    if [[ $(systemctl is-enabled "$service" 2>/dev/null || true) != enabled ]]; then
        log FAILED "$service: persistent enablement could not be verified." >&2
        exit 1
    fi
    log VERIFIED "$service: enabled; systemd will run its oneshot helper at boot."
done

# Run helpers directly so per-policy/driver results are visible in this SSH
# session. The enabled services use the same helper at boot; no duplicate run.
step='Applying current CPU and Wi-Fi settings'
log STEP 'Applying settings now; detailed results follow.'
failed=0
/usr/local/sbin/homelab-power-apply cpu || failed=1
/usr/local/sbin/homelab-power-apply wifi || failed=1

log INFO 'Boot-time helper output: journalctl -u homelab-cpu-power.service -u homelab-wifi-power.service'
log INFO 'Oneshot services may show inactive after completion; enablement controls whether they run at boot.'
log PENDING 'Reboot is required to load the saved lid/idle drop-in; its effective runtime state has not been verified.'
log INFO 'Later logind drop-ins and other power/network managers may override settings. Review any SKIPPED lines; see the script header to reverse these changes.'
if (( failed )); then
    log FAILED 'Configuration saved, but at least one immediate CPU/Wi-Fi operation failed. Review FAILED lines above; exiting 1.' >&2
    exit 1
fi
log SUMMARY 'Configuration saved and boot services verified enabled. Immediate checks completed without failures; skipped hardware was not changed. Lid/idle settings await reboot.'
