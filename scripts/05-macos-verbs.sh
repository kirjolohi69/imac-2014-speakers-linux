#!/usr/bin/env bash
# Step 5: Send the codec commands macOS uses to switch on the speakers.
#
# Source: the 12" MacBook (MacBook9,1) has the same CS4208 chip with the same
# speaker routing (converter 0x0a -> digital pin 0x1d -> external amp). Its
# out-of-tree driver (github.com/leifliddy/macbook12-audio-driver) contains a
# capture of every command macOS sends. Compared with Linux, macOS also:
#   * sends vendor verb 0x7f0 = 0x3 to converter 0x0a before playing
#   * sets GPIO direction 0x31 / mask 0x37 / data 0x01 (Linux: GPIO0 only)
#   * sends 4 channels into converter 0x0a (Linux sends 2)
#
# This script plays a quiet voice and applies these one step at a time,
# asking after each step whether you hear anything.
#
# Everything lives in the codec's RAM only. GPIOs are restored on exit; the
# rest is cleared by a reboot (for a guaranteed clean slate: shut down, then
# power on). Needs: hda-verb  (sudo apt install alsa-tools)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cirrus
require_hda_verb

LOG="$REPO_DIR/reports/macos-verbs-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$LOG")"

ORIG_MASK="$(hda_verb 0x01 GET_GPIO_MASK 0)"
ORIG_DIR="$(hda_verb 0x01 GET_GPIO_DIRECTION 0)"
ORIG_DATA="$(hda_verb 0x01 GET_GPIO_DATA 0)"
[[ -n "$ORIG_DATA" ]] || die "Could not read GPIO state through $HWDEP"
echo "$ORIG_MASK $ORIG_DIR $ORIG_DATA" >"$STATE_DIR/gpio.orig"

restore_gpio() {
    [[ -f "$STATE_DIR/gpio.orig" ]] || return 0
    hda_verb 0x01 SET_GPIO_MASK "$ORIG_MASK" >/dev/null
    hda_verb 0x01 SET_GPIO_DIRECTION "$ORIG_DIR" >/dev/null
    hda_verb 0x01 SET_GPIO_DATA "$ORIG_DATA" >/dev/null
    rm -f "$STATE_DIR/gpio.orig"
}
trap 'tone_stop; restore_gpio; ps_restore; pw_start' EXIT

{
    echo "macOS verb test on $CODEC_NAME, card $CARD, kernel $(uname -r), TEST_VOLUME=$TEST_VOLUME"
    echo "original GPIO: mask=$ORIG_MASK dir=$ORIG_DIR data=$ORIG_DATA"
} >"$LOG"
touch "$STATE_DIR/codec.touched"

# hda-verb takes 12-bit verbs as 0xNNN and 4-bit verbs as 0xN00.
VENDOR_7F0=0x7f0
SET_STREAM_FORMAT=0x200
SET_DIGI_CONVERT_1=0x70d
SET_DIGI_CONVERT_2=0x70e

step() {  # step "description"  -> asks, logs, returns 0 if audible
    local r
    sleep 0.7
    if ask_yn "[$1] Do you hear the voice from the speakers now?"; then r=AUDIBLE; else r=silent; fi
    echo "$1 -> $r" >>"$LOG"
    [[ $r == AUDIBLE ]]
}

macos_7f0() {
    hda_verb 0x0a "$VENDOR_7F0" 0x03 >/dev/null
    hda_verb 0x0b "$VENDOR_7F0" 0x03 >/dev/null
}
macos_gpio() {
    hda_verb 0x01 SET_GPIO_DIRECTION 0x31 >/dev/null
    hda_verb 0x01 SET_GPIO_DATA 0x01 >/dev/null
    hda_verb 0x01 SET_GPIO_MASK 0x37 >/dev/null
}
macos_digi() {
    hda_verb 0x0a "$SET_DIGI_CONVERT_2" 0x01 >/dev/null
    hda_verb 0x0a "$SET_DIGI_CONVERT_1" 0x11 >/dev/null
}

pw_stop
ps_disable
say "Test sounds at TEST_VOLUME=$TEST_VOLUME. Press Ctrl+C at any time to stop and restore."

# --- 2-channel stream (what Linux normally does) ---------------------------
tone_start 2 || die "Could not start playback."
step "baseline, 2ch" && found=1 || found=0
if [[ $found == 0 ]]; then macos_7f0;  step "2ch + 0x7f0=3 on 0x0a/0x0b"   && found=1 || true; fi
if [[ $found == 0 ]]; then macos_gpio; step "2ch + 0x7f0 + macOS GPIOs"    && found=1 || true; fi
if [[ $found == 0 ]]; then macos_digi; step "2ch + 0x7f0 + GPIOs + DIGI"   && found=1 || true; fi
tone_stop

# --- 4-channel stream, 0x0a takes all 4 channels like on macOS -------------
if [[ $found == 0 ]]; then
    say "Now trying a 4-channel stream (like macOS)."
    speaker-test -D "hw:${CARD},0" -c 4 -r 48000 -F S16_LE -t wav -W "$QUIET_WAVS" -l 0 >/dev/null 2>&1 &
    TONE_PID=$!
    sleep 1.5
    if kill -0 "$TONE_PID" 2>/dev/null; then
        step "4ch, Linux routing" && found=1 || true
        if [[ $found == 0 ]]; then
            macos_7f0; macos_gpio; macos_digi
            step "4ch + 0x7f0 + GPIOs + DIGI" && found=1 || true
        fi
        if [[ $found == 0 ]]; then
            # 48 kHz, 16 bit, 4 channels into converter 0x0a, then re-arm
            hda_verb 0x0a "$SET_STREAM_FORMAT" 0x0013 >/dev/null
            macos_7f0
            step "4ch, 0x0a format=4ch + all macOS verbs" && found=1 || true
        fi
    else
        echo "4ch stream could not be opened on hw:${CARD},0" >>"$LOG"
        warn "Could not open a 4-channel stream."
    fi
    tone_stop
fi

echo
say "Results saved to $LOG"
cat "$LOG"
if [[ $found == 1 ]]; then
    say "We found something that works! Send me the log above."
else
    say "No luck with these. Send me the log anyway; next we try the GPIO probe (03)."
fi
say "Reboot afterwards to clear the codec state completely."
