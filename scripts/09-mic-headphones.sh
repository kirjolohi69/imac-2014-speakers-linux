#!/usr/bin/env bash
# Step 9: Check the built-in microphone and the headphone jack.
#
#   1. Records 5 seconds from the built-in microphone and plays it back.
#   2. Checks whether the headphone plug is detected (and the right way round).
#   3. Plays quiet test voices on the headphones, using the stereo profile.
#
# Your sound settings are put back at the end (profile and default output).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cirrus

PA_CARD="$(pactl list short cards | awk '/pci-0000_00_1b/ {print $2; exit}')"
[[ -n $PA_CARD ]] || die "Built-in sound card not found in PipeWire."
BASE="${PA_CARD#alsa_card.}"
LOG="$REPO_DIR/reports/mic-headphones-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$LOG")"
echo "Mic/headphone test on $CODEC_NAME, card $CARD, kernel $(uname -r)" >"$LOG"

ORIG_PROFILE="$(pactl list cards | awk -v c="$PA_CARD" '$1=="Name:" {inc=($2==c)} inc && /Active Profile:/ {print $3; exit}')"
ORIG_SINK="$(pactl get-default-sink)"
restore() {
    pactl set-card-profile "$PA_CARD" "$ORIG_PROFILE" 2>/dev/null || true
    sleep 1
    pactl set-default-sink "$ORIG_SINK" 2>/dev/null || true
}
trap restore EXIT

has() { pactl list short "$1" | awk -v s="$2" '$2==s {f=1} END {exit !f}'; }
wait_for() { for _ in $(seq 1 20); do has "$1" "$2" && return 0; sleep 0.5; done; return 1; }

peak_db() {  # peak level of a wav file in dBFS
    python3 - "$1" <<'PY'
import array, math, struct, sys
b = open(sys.argv[1], "rb").read()
i = b.find(b"data"); n = min(struct.unpack("<I", b[i+4:i+8])[0], len(b) - i - 8)
a = array.array("h", b[i+8:i+8+n-(n % 2)])
p = max((abs(v) for v in a), default=0)
print(f"{20*math.log10(p/32768):.1f}" if p else "-inf")
PY
}

# --- 1. microphone --------------------------------------------------------------
say "Part 1: built-in microphone"
SOURCE="alsa_input.${BASE}.analog-stereo"
if wait_for sources "$SOURCE"; then
    pactl set-source-port "$SOURCE" analog-input-internal-mic 2>/dev/null || true
    read -r -p "Press Enter, then talk normally for 5 seconds... " _ </dev/tty
    rm -f "$STATE_DIR/mic.wav"
    timeout 5 pw-record --target "$SOURCE" --channels 2 --format s16 --rate 48000 "$STATE_DIR/mic.wav" || true
    level="$(peak_db "$STATE_DIR/mic.wav")"
    say "Recorded. Peak level: $level dBFS. Playing it back on the speakers..."
    pw-play "$STATE_DIR/mic.wav" || true
    if ask_yn "Did you hear your voice clearly?"; then r=OK; else r=BAD; fi
    read -r -p "   anything odd? (quiet / noisy / distorted / blank = fine): " note </dev/tty
    echo "mic: $r, peak ${level} dBFS${note:+ ($note)}" >>"$LOG"
else
    echo "mic: input $SOURCE not found" >>"$LOG"; warn "Microphone input not found."
fi

# --- 2. headphone plug detection --------------------------------------------------
echo
say "Part 2: headphone plug detection"
jack() { amixer -c "$CARD" cget iface=CARD,name='Headphone Jack' 2>/dev/null | sed -n 's/.*: values=//p'; }
read -r -p "Make sure NOTHING is plugged into the headphone jack, then press Enter... " _ </dev/tty
j_out="$(jack)"
read -r -p "Now plug in headphones, then press Enter... " _ </dev/tty
sleep 1
j_in="$(jack)"
echo "jack detect: unplugged=$j_out plugged=$j_in" >>"$LOG"
say "Jack reads '$j_out' when unplugged and '$j_in' when plugged in."

# --- 3. headphone playback ----------------------------------------------------------
echo
say "Part 3: headphone playback (switches to the stereo profile for a moment)"
pactl set-card-profile "$PA_CARD" output:analog-stereo+input:analog-stereo
HP_SINK="alsa_output.${BASE}.analog-stereo"
if wait_for sinks "$HP_SINK"; then
    pactl set-sink-port "$HP_SINK" analog-output-headphones 2>/dev/null || true
    pactl set-sink-volume "$HP_SINK" 30%
    make_quiet_wavs
    # stereo copies with the voice on one side only
    python3 - "$QUIET_WAVS" <<'PY'
import array, sys, wave
d = sys.argv[1]
for name, side in (("Front_Left", 0), ("Front_Right", 1)):
    with wave.open(f"{d}/{name}.wav") as w:
        p, a = w.getparams(), array.array("h", w.readframes(w.getnframes()))
    s = array.array("h")
    for v in a:
        s.extend((v, 0) if side == 0 else (0, v))
    with wave.open(f"{d}/{name}_stereo.wav", "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(p.framerate); w.writeframes(s.tobytes())
PY
    read -r -p "Put the headphones on, then press Enter to hear 'Front Left' and 'Front Right'... " _ </dev/tty
    for f in Front_Left Front_Right; do pw-play --target "$HP_SINK" "$QUIET_WAVS/${f}_stereo.wav" || true; sleep 0.3; done
    while true; do
        read -r -p "Where did you hear them? (c = correct sides, s = swapped, o = only one side, n = nothing): " hp </dev/tty
        [[ $hp =~ ^[cson]$ ]] && break
    done
    if ask_yn "Did the speakers stay SILENT while the headphones played?"; then spk=silent; else spk=ALSO_PLAYING; fi
    echo "headphones: $hp (c=correct s=swapped o=one side n=nothing), speakers during headphones: $spk" >>"$LOG"
    pactl list sinks | awk -v s="$HP_SINK" '$1=="Name:" {inc=($2==s)} inc && /Active Port|headphones:/' >>"$LOG"
else
    echo "headphones: stereo sink did not appear" >>"$LOG"; warn "Stereo output did not appear."
fi

echo
say "Restoring your sound settings..."
restore
trap - EXIT
say "Results saved to $LOG"
cat "$LOG"
