#!/usr/bin/env bash
# Step 2: Play test sounds straight to the codec, bypassing PipeWire, so we can
# hear what the hardware actually does with each channel.
#
# Changes nothing permanently: PipeWire is paused for the duration of the test
# and restarted automatically when the script ends (even on Ctrl+C).
#
# Usage: scripts/02-tone-test.sh [channels...]     default: 2 4 6 8
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cirrus

LOG="$REPO_DIR/reports/tone-test-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$LOG")"
CHANNELS=("$@"); [[ ${#CHANNELS[@]} -gt 0 ]] || CHANNELS=(2 4 6 8)

trap 'tone_stop; pw_start' EXIT
pw_stop

say "Codec: $CODEC_NAME (card $CARD). Turn the volume down a bit before continuing."
say "A voice will say each channel name ('Front Left', 'Rear Right', ...)."
echo "Tone test on $CODEC_NAME, card $CARD, kernel $(uname -r)" >"$LOG"

# Make sure the hardware mixer isn't muted (non-destructive: alsactl state is
# restored by PipeWire/WirePlumber and by undo.sh).
alsactl store -f "$STATE_DIR/alsa-mixer-before-tone-test.state" "$CARD" 2>/dev/null || true
for ctl in Master Speaker PCM Front Surround 'Bass Speaker' Center LFE; do
    amixer -q -c "$CARD" sset "$ctl" 80% unmute 2>/dev/null || true
done

for ch in "${CHANNELS[@]}"; do
    echo
    say "Playing $ch-channel test (each channel is announced once)."
    if ! speaker-test -D "plughw:${CARD},0" -c "$ch" -t wav -l 1 >"$STATE_DIR/speaker-test.out" 2>&1; then
        warn "$ch channels not supported by this device - skipping."
        echo "$ch ch: not supported" >>"$LOG"
        continue
    fi
    read -r -p "Which channel names did you hear from the SPEAKERS (blank = nothing)? " heard </dev/tty
    read -r -p "Anything odd? (quiet / tinny / distorted / one side only / fine): " how </dev/tty
    echo "$ch ch: heard=[$heard] quality=[$how]" >>"$LOG"
done

if [[ -f "$STATE_DIR/alsa-mixer-before-tone-test.state" ]]; then
    alsactl restore -f "$STATE_DIR/alsa-mixer-before-tone-test.state" "$CARD" 2>/dev/null || true
fi

echo
say "Results saved to $LOG"
cat "$LOG"
