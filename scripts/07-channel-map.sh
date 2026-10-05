#!/usr/bin/env bash
# Step 7: Map every channel to its physical driver, and check the formats
# PipeWire would use.
#
# 06-isolate.sh showed the speakers work with any 4-channel stream (no extra
# codec commands needed) and stay silent with 2 channels. Channels 1+2 came out
# of the LEFT speaker (one tinny, one full), channels 3+4 out of the RIGHT one.
# Here each channel is played on its own so we know exactly which is the
# tweeter and which the woofer on each side.
#
# Nothing is changed on the codec. PipeWire is paused for part A/B and the
# card profile is put back after part C.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cirrus

LOG="$REPO_DIR/reports/channel-map-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$LOG")"
echo "Channel map test on $CODEC_NAME, card $CARD, kernel $(uname -r), TEST_VOLUME=$TEST_VOLUME" >"$LOG"

ORIG_PROFILE="" ORIG_SINK="" PA_CARD=""
restore_pw() {
    if [[ -n "$PA_CARD" && -n "$ORIG_PROFILE" ]]; then
        pactl set-card-profile "$PA_CARD" "$ORIG_PROFILE" 2>/dev/null || true
    fi
    if [[ -n "$ORIG_SINK" ]]; then
        pactl set-default-sink "$ORIG_SINK" 2>/dev/null || true
    fi
}
trap 'pw_start; restore_pw' EXIT

play1() {  # play1 DEVICE FORMAT RATE CHANNEL -> plays one channel of a 4ch stream once
    speaker-test -D "$1" -c 4 -F "$2" -r "$3" -t wav -W "$QUIET_WAVS" -s "$4" >"$STATE_DIR/speaker-test.out" 2>&1
}

make_quiet_wavs
pw_stop

# --- A: which driver is each channel? -----------------------------------------
say "Part A: each of the 4 channels is played alone. Listen for side and sound."
for n in 1 2 3 4; do
    echo
    read -r -p "Press Enter to play channel $n... " _ </dev/tty
    if ! play1 "hw:${CARD},0" S16_LE 48000 "$n"; then
        warn "Playback failed:"; tail -n 3 "$STATE_DIR/speaker-test.out"
        echo "A ch$n: playback failed" >>"$LOG"; continue
    fi
    while true; do
        read -r -p "  Channel $n came from which side? (l = left, r = right, b = both, n = nothing, a = play again): " side </dev/tty
        [[ $side == a ]] && { play1 "hw:${CARD},0" S16_LE 48000 "$n" || true; continue; }
        [[ $side =~ ^[lrbn]$ ]] && break
    done
    snd=""
    if [[ $side != n ]]; then
        while true; do
            read -r -p "  Did it sound full (f) or tinny (t)? " snd </dev/tty
            [[ $snd =~ ^[ft]$ ]] && break
        done
    fi
    echo "A ch$n: side=$side sound=${snd:--}" >>"$LOG"
done

# --- B: formats PipeWire may pick ----------------------------------------------
echo
say "Part B: the same left channel in other sample formats (a short voice each time)."
for fmt in "S32_LE 48000" "S16_LE 44100" "S32_LE 44100"; do
    read -r f r <<<"$fmt"
    read -r -p "Press Enter to play format $f at $r Hz... " _ </dev/tty
    if ! play1 "hw:${CARD},0" "$f" "$r" 1; then
        echo "B $f $r: not supported by hw" >>"$LOG"; warn "Not supported, skipping."; continue
    fi
    if ask_yn "  Did you hear it?"; then r2=AUDIBLE; else r2=silent; fi
    echo "B $f $r: $r2" >>"$LOG"
done

# --- C: through PipeWire with the 4.0 profile -------------------------------------
echo
pw_start
sleep 3
say "Part C: the same test through PipeWire, using the 'Analog Surround 4.0' profile."
if PA_CARD="$(pactl list short cards 2>/dev/null | awk '/pci-0000_00_1b/ {print $2; exit}')" && [[ -n $PA_CARD ]]; then
    ORIG_PROFILE="$(pactl list cards 2>/dev/null | awk -v c="$PA_CARD" '$1=="Name:" {inc=($2==c)} inc && /Active Profile:/ {print $3; exit}')"
    ORIG_SINK="$(pactl get-default-sink 2>/dev/null || true)"
    echo "C card=$PA_CARD original profile=$ORIG_PROFILE original sink=$ORIG_SINK" >>"$LOG"
    if pactl set-card-profile "$PA_CARD" output:analog-surround-40 2>>"$LOG"; then
        sleep 2
        SINK="$(pactl list short sinks | awk '/pci-0000_00_1b.*surround-40/ {print $2; exit}')"
        pactl set-default-sink "$SINK" 2>>"$LOG" || true
        pactl get-sink-volume "$SINK" >>"$LOG" 2>&1 || true
        read -r -p "Press Enter to play channel 2 (left, full) through PipeWire... " _ </dev/tty
        if speaker-test -D pipewire -c 4 -t wav -W "$QUIET_WAVS" -s 2 >"$STATE_DIR/speaker-test.out" 2>&1 \
           || speaker-test -D default -c 4 -t wav -W "$QUIET_WAVS" -s 2 >"$STATE_DIR/speaker-test.out" 2>&1; then
            if ask_yn "  Did you hear it?"; then r=AUDIBLE; else r=silent; fi
        else
            r="playback failed: $(tail -n 1 "$STATE_DIR/speaker-test.out")"
        fi
        echo "C pipewire surround-40 sink=$SINK: $r" >>"$LOG"
        pactl list sinks 2>/dev/null | awk -v s="$SINK" '$1=="Name:" {inc=($2==s)} inc && /Sample Specification|Channel Map|api.alsa.path|Volume:/' >>"$LOG"
    else
        echo "C could not switch profile" >>"$LOG"
    fi
else
    echo "C built-in card not found in PipeWire" >>"$LOG"
fi

echo
say "Results saved to $LOG"
cat "$LOG"
