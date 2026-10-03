#!/usr/bin/env bash
# Step 3: Find which codec GPIO pin switches on the speaker amplifier.
#
# On Macs with Cirrus codecs the speakers sit behind an external amplifier
# that is enabled through one of the codec's GPIO pins. If Linux drives the
# wrong pin, the speakers stay silent (or only partly work).
#
# This script plays a tone and switches ONE GPIO at a time, asking you whether
# the sound changed. The original GPIO values are saved first and restored
# when the script exits (also on Ctrl+C). A reboot also resets everything.
#
# Needs: hda-verb  (sudo apt install alsa-tools)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cirrus
require_hda_verb

NGPIO="$(sed -n 's/^GPIO: io=\([0-9]*\).*/\1/p' "$CODEC_FILE")"
[[ -n "$NGPIO" && "$NGPIO" -gt 0 ]] || die "Codec reports no GPIOs."
LOG="$REPO_DIR/reports/gpio-probe-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$LOG")"

restore_gpio() {
    [[ -n "${ORIG_DATA:-}" ]] || return 0
    say "Restoring original GPIO state (mask=$ORIG_MASK dir=$ORIG_DIR data=$ORIG_DATA)"
    hda_verb 0x01 SET_GPIO_MASK "$ORIG_MASK" >/dev/null
    hda_verb 0x01 SET_GPIO_DIRECTION "$ORIG_DIR" >/dev/null
    hda_verb 0x01 SET_GPIO_DATA "$ORIG_DATA" >/dev/null
    rm -f "$STATE_DIR/gpio.orig"
}
trap 'tone_stop; restore_gpio; ps_restore; pw_start' EXIT

ORIG_MASK="$(hda_verb 0x01 GET_GPIO_MASK 0)"
ORIG_DIR="$(hda_verb 0x01 GET_GPIO_DIRECTION 0)"
ORIG_DATA="$(hda_verb 0x01 GET_GPIO_DATA 0)"
[[ -n "$ORIG_DATA" ]] || die "Could not read GPIO state through $HWDEP"
echo "$ORIG_MASK $ORIG_DIR $ORIG_DATA" >"$STATE_DIR/gpio.orig"
{
    echo "GPIO probe on $CODEC_NAME, card $CARD, $NGPIO GPIOs, kernel $(uname -r)"
    echo "original: mask=$ORIG_MASK dir=$ORIG_DIR data=$ORIG_DATA"
} >"$LOG"
say "$NGPIO GPIOs. Original: mask=$ORIG_MASK dir=$ORIG_DIR data=$ORIG_DATA"

pw_stop
ps_disable
tone_start 2 || die "Could not play a tone."

set_gpio() {  # set_gpio MASK DIR DATA
    hda_verb 0x01 SET_GPIO_MASK "$1" >/dev/null
    hda_verb 0x01 SET_GPIO_DIRECTION "$2" >/dev/null
    hda_verb 0x01 SET_GPIO_DATA "$3" >/dev/null
}

if ask_yn "Baseline: a quiet voice is repeating 'Front Left' / 'Front Right'. Do you hear it from the speakers?"; then
    echo "baseline: audible" >>"$LOG"
else
    echo "baseline: silent" >>"$LOG"
fi

for ((i = 0; i < NGPIO; i++)); do
    bit=$((1 << i))
    for level in 1 0; do
        data=$(( (ORIG_DATA & ~bit) | (level ? bit : 0) ))
        set_gpio "$(printf '0x%x' $((ORIG_MASK | bit)))" "$(printf '0x%x' $((ORIG_DIR | bit)))" "$(printf '0x%x' $data)"
        sleep 0.5
        if ask_yn "GPIO$i = $level (output). Do you hear the voice from the speakers?"; then r=audible; else r=silent; fi
        read -r -p "   any change in quality vs. before? (blank = no): " note </dev/tty
        echo "GPIO$i=$level -> $r ${note:+($note)}" >>"$LOG"
    done
    set_gpio "$ORIG_MASK" "$ORIG_DIR" "$ORIG_DATA"
done

all=$(( (1 << NGPIO) - 1 ))
set_gpio "$(printf '0x%x' $all)" "$(printf '0x%x' $all)" "$(printf '0x%x' $all)"
if ask_yn "ALL GPIOs = 1. Do you hear the voice from the speakers?"; then r=audible; else r=silent; fi
echo "ALL=1 -> $r" >>"$LOG"

echo
say "Results saved to $LOG"
cat "$LOG"
