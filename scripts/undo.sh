#!/usr/bin/env bash
# Undo everything the experiment scripts may have changed in this boot session,
# and remove any persistent config this repo installed.
# (A plain reboot also undoes all runtime experiments.)
set -uo pipefail
source "$(dirname "$0")/lib.sh"

find_cirrus_codec || warn "No Cirrus codec visible right now; doing what we can."

# 1. GPIO values saved by 03-gpio-probe.sh (only left behind if it crashed)
if [[ -f "$STATE_DIR/gpio.orig" && -n "${HWDEP:-}" ]] && command -v hda-verb >/dev/null; then
    read -r m d v <"$STATE_DIR/gpio.orig"
    say "Restoring GPIOs: mask=$m dir=$d data=$v"
    hda_verb 0x01 SET_GPIO_MASK "$m" >/dev/null
    hda_verb 0x01 SET_GPIO_DIRECTION "$d" >/dev/null
    hda_verb 0x01 SET_GPIO_DATA "$v" >/dev/null
    rm -f "$STATE_DIR/gpio.orig"
fi

# 2. power_save value saved by a probe script
if [[ -f "$STATE_DIR/power_save.orig" ]]; then
    say "Restoring snd_hda_intel power_save=$(cat "$STATE_DIR/power_save.orig")"
    sudo tee "$PS_FILE" <"$STATE_DIR/power_save.orig" >/dev/null
    rm -f "$STATE_DIR/power_save.orig"
fi

# 3. runtime pin overrides from 04-pin-probe.sh
if [[ -f "$STATE_DIR/pins.modified" && -n "${SYSFS:-}" ]]; then
    say "Clearing runtime pin overrides and re-initialising the codec..."
    pw_stop
    echo 1 | sudo tee "$SYSFS/clear" >/dev/null && echo 1 | sudo tee "$SYSFS/reconfig" >/dev/null \
        && rm -f "$STATE_DIR/pins.modified" \
        || warn "Re-init failed (card busy?). A reboot will reset it."
    pw_start
fi

# 4. persistent config files this project may install later (if any)
for f in /etc/modprobe.d/imac-speakers.conf /lib/firmware/imac-speakers.fw; do
    if [[ -e $f ]]; then
        say "Removing $f"
        sudo rm -f "$f"
        NEED_REBOOT=1
    fi
done

if [[ -f "$STATE_DIR/codec.touched" ]]; then
    warn "05-macos-verbs.sh sent vendor commands that only a reboot clears. Please reboot."
    rm -f "$STATE_DIR/codec.touched"
fi

say "Undo complete.${NEED_REBOOT:+ Reboot to fully drop the removed boot-time config.}"
