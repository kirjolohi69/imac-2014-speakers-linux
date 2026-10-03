#!/usr/bin/env bash
# Step 6: Find exactly which command makes the speakers work.
#
# 05-macos-verbs.sh got sound with a 4-channel stream, but only after it had
# already sent all the macOS commands, so we don't know which one mattered.
# This script starts from a clean codec (run it right after a reboot) and
# adds one thing at a time while a quiet voice repeats the 4 channel names.
#
# Runtime only: GPIOs are restored on exit, the vendor command is cleared by
# a reboot. Needs: hda-verb (sudo apt install alsa-tools)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cirrus
require_hda_verb

boot_id="$(cat /proc/sys/kernel/random/boot_id)"
if [[ -f "$STATE_DIR/codec.touched" && "$(cat "$STATE_DIR/codec.touched")" == "$boot_id" ]]; then
    die "The codec was already changed during this boot (by 05-macos-verbs.sh). Reboot first, then run this again."
fi
echo "$boot_id" >"$STATE_DIR/codec.touched"

LOG="$REPO_DIR/reports/isolate-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$LOG")"

ORIG_MASK="$(hda_verb 0x01 GET_GPIO_MASK 0)"
ORIG_DIR="$(hda_verb 0x01 GET_GPIO_DIRECTION 0)"
ORIG_DATA="$(hda_verb 0x01 GET_GPIO_DATA 0)"
[[ -n "$ORIG_DATA" ]] || die "Could not read GPIO state through $HWDEP"
echo "$ORIG_MASK $ORIG_DIR $ORIG_DATA" >"$STATE_DIR/gpio.orig"

set_gpio() {  # set_gpio MASK DIR DATA
    hda_verb 0x01 SET_GPIO_MASK "$1" >/dev/null
    hda_verb 0x01 SET_GPIO_DIRECTION "$2" >/dev/null
    hda_verb 0x01 SET_GPIO_DATA "$3" >/dev/null
}
restore_gpio() {
    [[ -f "$STATE_DIR/gpio.orig" ]] || return 0
    set_gpio "$ORIG_MASK" "$ORIG_DIR" "$ORIG_DATA"
    rm -f "$STATE_DIR/gpio.orig"
}
macos_gpio() { set_gpio 0x37 0x31 0x01; }
macos_7f0()  { hda_verb 0x0a 0x7f0 0x03 >/dev/null; hda_verb 0x0b 0x7f0 0x03 >/dev/null; }

play() {  # play CHANNELS  (background, loops until stop)
    tone_stop
    speaker-test -D "hw:${CARD},0" -c "$1" -r 48000 -F S16_LE -t wav -W "$QUIET_WAVS" -l 0 >/dev/null 2>&1 &
    TONE_PID=$!
    sleep 1.5
    kill -0 "$TONE_PID" 2>/dev/null || { TONE_PID=""; warn "Could not open a $1-channel stream."; return 1; }
}

step() {  # step "description"
    local r note
    sleep 0.7
    if ask_yn "[$1] Do you hear the voice?"; then
        r=AUDIBLE
        read -r -p "   which names sound full, which tinny? (e.g. 'FL FR full, rest tinny'; Enter = skip): " note </dev/tty
    else
        r=silent; note=""
    fi
    echo "$1 -> $r${note:+ ($note)}" >>"$LOG"
}

trap 'tone_stop; restore_gpio; ps_restore; pw_start' EXIT
{
    echo "Isolation test on $CODEC_NAME, card $CARD, kernel $(uname -r), TEST_VOLUME=$TEST_VOLUME"
    echo "original GPIO: mask=$ORIG_MASK dir=$ORIG_DIR data=$ORIG_DATA"
} >"$LOG"

make_quiet_wavs
pw_stop
ps_disable
say "A quiet voice will keep repeating the channel names. Answer after each change."

play 4 || die "4-channel playback failed."
step "1. 4ch, nothing changed"
macos_gpio
step "2. 4ch + macOS GPIOs only"
restore_gpio; echo "$ORIG_MASK $ORIG_DIR $ORIG_DATA" >"$STATE_DIR/gpio.orig"
macos_7f0
step "3. 4ch + vendor verb 0x7f0=3 only (GPIOs back to Linux default)"
macos_gpio
step "4. 4ch + vendor verb + macOS GPIOs"

say "Restarting the stream without sending anything (does the setting survive?)"
tone_stop; sleep 2
play 4 && step "5. 4ch, new stream, no re-send"
macos_7f0
step "6. 4ch, new stream, vendor verb re-sent"

say "Trying 2 channels with everything applied"
play 2 && { macos_7f0; step "7. 2ch + vendor verb + macOS GPIOs"; }

echo
say "Results saved to $LOG"
cat "$LOG"
say "Reboot afterwards to clear the codec state."
