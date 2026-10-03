#!/usr/bin/env bash
# Step 4: Tell the driver (temporarily) which codec pins are the speakers.
#
# On CS4208 Macs the internal speakers are often NOT on the pin the firmware
# advertises (0x12) but on pins 0x1d / 0x1e, which feed an external amplifier
# over a digital link. If the driver doesn't know that, it sends sound to a
# pin that goes nowhere.
#
# This uses the kernel's own runtime override (sysfs user_pin_configs +
# reconfig). Nothing is written to disk; a reboot or scripts/undo.sh removes it.
#
# Usage:
#   scripts/04-pin-probe.sh                 # interactive menu of presets
#   scripts/04-pin-probe.sh 0x1d=0x90100110 0x1e=0x90100112   # custom
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cirrus

# Pin default-config cheat sheet:
#   0x90100110 = fixed / internal / speaker, assoc 1, seq 0  (front L/R)
#   0x90100112 = same, seq 2 (driver treats it as a 2nd speaker pair)
#   0x411111f0 = "not connected" (hides the pin from the driver)
declare -A PRESETS=(
    [1]="0x1d=0x90100110"
    [2]="0x1d=0x90100110 0x1e=0x90100112"
    [3]="0x1d=0x90100110 0x1e=0x90100112 0x12=0x411111f0"
    [4]="0x12=0x90100110"
)
DESC=(
    ""
    "Speakers on digital pin 0x1d only"
    "Speakers on 0x1d + 0x1e (two pairs, e.g. woofer/tweeter or L/R)"
    "Like 2, and hide analog pin 0x12"
    "Speakers on analog pin 0x12 (what the stock driver assumes)"
)

if [[ $# -gt 0 ]]; then
    ASSIGN=("$@")
else
    echo "Pin presets:"
    for k in 1 2 3 4; do printf '  %s) %-60s [%s]\n' "$k" "${DESC[$k]}" "${PRESETS[$k]}"; done
    read -r -p "Choose 1-4: " k </dev/tty
    [[ -n "${PRESETS[$k]:-}" ]] || die "Invalid choice."
    read -r -a ASSIGN <<<"${PRESETS[$k]}"
fi

[[ -e "$SYSFS/user_pin_configs" ]] \
    || die "$SYSFS/user_pin_configs missing (kernel built without CONFIG_SND_HDA_RECONFIG?)"

LOG="$REPO_DIR/reports/pin-probe-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$LOG")"
trap 'pw_start' EXIT
pw_stop

say "Applying: ${ASSIGN[*]}"
for a in "${ASSIGN[@]}"; do
    nid="${a%%=*}"; val="${a#*=}"
    echo "$nid $val" | sudo tee "$SYSFS/user_pin_configs" >/dev/null
done
touch "$STATE_DIR/pins.modified"
if ! echo 1 | sudo tee "$SYSFS/reconfig" >/dev/null; then
    die "reconfig failed (something still has the sound card open: check 'fuser -v /dev/snd/*'). Run scripts/undo.sh."
fi
sleep 2
find_cirrus_codec || die "Codec disappeared after reconfig?! Run scripts/undo.sh or reboot."
# Freshly created mixer controls may start muted.
for ctl in Master Speaker PCM Front Surround 'Bass Speaker'; do
    amixer -q -c "$CARD" sset "$ctl" 80% unmute 2>/dev/null || true
done

{
    echo "Pin probe: ${ASSIGN[*]}  ($CODEC_NAME, kernel $(uname -r))"
    sudo dmesg | grep -i 'autoconfig\|line_outs\|speaker_outs\|hp_outs' | tail -n 8
} >"$LOG"
say "Driver now sees:"; tail -n 8 "$LOG"

say "Playing test sounds..."
for ch in 2 4; do
    if say_channels "plughw:${CARD},0" "$ch" >/dev/null 2>&1; then
        read -r -p "$ch ch: which channel names did you hear (blank = nothing)? " heard </dev/tty
        read -r -p "    quality? (quiet / tinny / distorted / fine): " how </dev/tty
        echo "$ch ch: heard=[$heard] quality=[$how]" >>"$LOG"
    fi
done

echo
say "Results saved to $LOG"
say "This override stays active until reboot or scripts/undo.sh."
