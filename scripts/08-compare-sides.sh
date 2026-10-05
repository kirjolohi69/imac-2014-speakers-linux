#!/usr/bin/env bash
# Step 8: Compare the left and right speakers driver by driver, and check that
# tweeter and woofer on each side are wired with the same polarity.
#
# Plays short bursts of filtered noise straight to single drivers through
# PipeWire's raw 4-channel output (the "iMac Speakers" fix must be installed).
# Changes nothing. Loudness: TEST_VOLUME (default 0.15).
#
# Channel map (from 07-channel-map.sh):
#   FL = left tweeter   FR = left woofer   RL = right tweeter   RR = right woofer
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PA_CARD="$(pactl list short cards | awk '/pci-0000_00_1b/ {print $2; exit}')"
[[ -n $PA_CARD ]] || die "Built-in sound card not found in PipeWire."
TARGET="alsa_output.${PA_CARD#alsa_card.}.analog-surround-40"
pactl list short sinks | awk -v s="$TARGET" '$2==s {f=1} END {exit !f}' \
    || die "The 4-channel output isn't active. Install the fix first (scripts/install-fix.sh)."

WAVS="$STATE_DIR/compare"
LOG="$REPO_DIR/reports/compare-sides-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$WAVS" "$(dirname "$LOG")"

say "Generating test sounds..."
python3 - "$WAVS" "$TEST_VOLUME" <<'PY'
import array, math, random, sys, wave
out, vol = sys.argv[1], float(sys.argv[2])
R = 48000
random.seed(1)

def biquad(x, kind, f, q=0.7071):
    w = 2 * math.pi * f / R; c, s = math.cos(w), math.sin(w); a = s / (2 * q)
    if kind == "lp": b0, b1, b2 = (1 - c) / 2, 1 - c, (1 - c) / 2
    else:            b0, b1, b2 = (1 + c) / 2, -(1 + c), (1 + c) / 2
    a0, a1, a2 = 1 + a, -2 * c, 1 - a
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    y, x1, x2, y1, y2 = [], 0.0, 0.0, 0.0, 0.0
    for v in x:
        o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, v, y1, o
        y.append(o)
    return y

def pink(n):  # Paul Kellett's economy pink noise
    b0 = b1 = b2 = 0.0; y = []
    for _ in range(n):
        w = random.uniform(-1, 1)
        b0 = 0.99765 * b0 + w * 0.0990460
        b1 = 0.96300 * b1 + w * 0.2965164
        b2 = 0.57000 * b2 + w * 1.0526913
        y.append(b0 + b1 + b2 + w * 0.1848)
    return y

def norm(x, peak):
    m = max(abs(v) for v in x) or 1.0
    n = len(x); fade = int(0.01 * R)
    return [v / m * peak * min(1.0, i / fade, (n - 1 - i) / fade) for i, v in enumerate(x)]

def band(kind):  # 2 s of pink noise in the woofer, tweeter or crossover band
    x = pink(2 * R)
    if kind == "low":   x = biquad(biquad(x, "lp", 2500), "lp", 2500); x = biquad(x, "hp", 80)
    if kind == "high":  x = biquad(biquad(x, "hp", 2500), "hp", 2500)
    if kind == "xover": x = biquad(biquad(x, "hp", 1500), "lp", 4000)
    return norm(x, vol)

GAP = [0.0] * int(0.6 * R)
def write(name, frames):  # frames: list of 4-tuples (FL FR RL RR)
    a = array.array("h")
    for f in frames:
        a.extend(int(max(-1, min(1, v)) * 32767) for v in f)
    with wave.open(f"{out}/{name}.wav", "wb") as w:
        w.setnchannels(4); w.setsampwidth(2); w.setframerate(R); w.writeframes(a.tobytes())

def on(ch, x):  # signal x on the channels in set ch, silence elsewhere
    return [tuple(v if i in ch else 0.0 for i in range(4)) for v in x]

def onpair(chs, x, invert_first):
    a, b = chs
    return [tuple((-v if (i == a and invert_first) else v) if i in chs else 0.0 for i in range(4)) for v in x]

silence = [(0.0,) * 4] * len(GAP)
lo, hi, xo = band("low"), band("high"), band("xover")
# A/B twice: left first, then right
write("woofers",  (on({1}, lo) + silence + on({3}, lo) + silence) * 2)
write("tweeters", (on({0}, hi) + silence + on({2}, hi) + silence) * 2)
# polarity: same polarity first, then tweeter inverted
write("polarity-left",  (onpair((0, 1), xo, False) + silence + onpair((0, 1), xo, True) + silence) * 2)
write("polarity-right", (onpair((2, 3), xo, False) + silence + onpair((2, 3), xo, True) + silence) * 2)
PY

play() { pw-play --target "$TARGET" --channels 4 --channel-map FL,FR,RL,RR "$WAVS/$1.wav"; }

ask3() {  # ask3 "question" "answer1" "answer2"
    local a
    while true; do
        read -r -p "$1 [1 = $2, 2 = $3, s = same, a = again] " a </dev/tty
        case "$a" in 1|2|s) echo "$a"; return ;; a) return 1 ;; esac
    done
}

run() {  # run NAME "question" "answer1" "answer2"
    local ans
    echo
    read -r -p "Press Enter to play: $1 ... " _ </dev/tty
    while true; do
        play "$1"
        ans="$(ask3 "$2" "$3" "$4")" && break
    done
    echo "$1: $ans  (1=$3, 2=$4, s=same)" >>"$LOG"
}

echo "Side comparison on kernel $(uname -r), TEST_VOLUME=$TEST_VOLUME, target $TARGET" >"$LOG"
say "Each test plays two bursts of noise, then repeats them once."
run woofers  "Woofers: which was LOUDER or BASSIER?"      "first (left)"  "second (right)"
run tweeters "Tweeters: which was LOUDER or BRIGHTER?"    "first (left)"  "second (right)"
say "Polarity: both drivers of ONE side play the same noise, first in phase, then with the tweeter flipped."
run polarity-left  "LEFT speaker: which burst sounded LOUDER/FULLER?"  "first"  "second"
run polarity-right "RIGHT speaker: which burst sounded LOUDER/FULLER?" "first"  "second"

echo
say "Results saved to $LOG"
cat "$LOG"
