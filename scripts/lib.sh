# Shared helpers for the experiment scripts. Source this file, don't run it.
# shellcheck shell=bash

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$REPO_DIR/state"          # saved "before" values, used by undo.sh
mkdir -p "$STATE_DIR"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

ask_yn() {  # ask_yn "question" -> returns 0 for yes
    local a
    while true; do
        read -r -p "$1 [y/n] " a </dev/tty
        case "$a" in y|Y|yes) return 0 ;; n|N|no) return 1 ;; esac
    done
}

if [[ $EUID -eq 0 ]]; then
    die "Run these scripts as your normal user (not with sudo). They call sudo themselves only where needed."
fi

# Find the ALSA card + codec that holds the Cirrus Logic chip (not the HDMI one).
find_cirrus_codec() {
    local f
    for f in /proc/asound/card*/codec#*; do
        [[ -r "$f" ]] || continue
        if grep -q '^Vendor Id: 0x1013' "$f"; then
            CODEC_FILE="$f"
            CARD="$(basename "$(dirname "$f")")"; CARD="${CARD#card}"
            CODEC_ADDR="${f##*#}"
            HWDEP="/dev/snd/hwC${CARD}D${CODEC_ADDR}"
            SYSFS="/sys/class/sound/hwC${CARD}D${CODEC_ADDR}"
            CODEC_NAME="$(sed -n 's/^Codec: //p' "$f")"
            return 0
        fi
    done
    return 1
}

require_cirrus() {
    find_cirrus_codec || die "No Cirrus Logic codec found in /proc/asound. Run scripts/01-collect-info.sh and share the report."
}

require_hda_verb() {
    command -v hda-verb >/dev/null || die "hda-verb not found. Install it with:  sudo apt install alsa-tools   (remove later with: sudo apt remove alsa-tools)"
}

# hda_verb NID VERB PARAM -> prints the returned value (e.g. 0x0)
hda_verb() {
    sudo hda-verb "$HWDEP" "$1" "$2" "$3" 2>/dev/null | sed -n 's/^value = //p'
}

# --- PipeWire pause/resume, so we can talk to the hardware directly --------
PW_UNITS=(pipewire-pulse.socket pipewire.socket pipewire-pulse.service wireplumber.service pipewire.service)
pw_stop() {
    say "Pausing PipeWire for this user (will be restarted automatically)..."
    systemctl --user stop "${PW_UNITS[@]}" 2>/dev/null || true
    sleep 1
}
pw_start() {
    say "Restarting PipeWire..."
    systemctl --user start pipewire.socket pipewire-pulse.socket 2>/dev/null || true
    systemctl --user start pipewire.service wireplumber.service pipewire-pulse.service 2>/dev/null || true
}

# --- Disable codec runtime power-saving during a test (it would reset GPIOs) -
PS_FILE=/sys/module/snd_hda_intel/parameters/power_save
ps_disable() {
    if [[ -r $PS_FILE ]]; then
        PS_ORIG="$(cat "$PS_FILE")"
        [[ -f "$STATE_DIR/power_save.orig" ]] || echo "$PS_ORIG" > "$STATE_DIR/power_save.orig"
        echo 0 | sudo tee "$PS_FILE" >/dev/null
    fi
}
ps_restore() {
    if [[ -n "${PS_ORIG:-}" ]]; then
        echo "$PS_ORIG" | sudo tee "$PS_FILE" >/dev/null
        rm -f "$STATE_DIR/power_save.orig"
    fi
}

# --- Quiet test sounds -------------------------------------------------------
# The iMac's speaker links have no hardware volume control, and the tests
# bypass PipeWire's volume, so we make the test sounds themselves quiet:
# copies of speaker-test's voice prompts ("Front Left", ...) scaled down.
# Loudness: TEST_VOLUME=0.15 by default (about -16 dB). Override, e.g.:
#   TEST_VOLUME=0.05 scripts/02-tone-test.sh     (quieter)
#   TEST_VOLUME=0.4  scripts/02-tone-test.sh     (louder)
TEST_VOLUME="${TEST_VOLUME:-0.15}"
QUIET_WAVS="$STATE_DIR/quiet-wavs"
make_quiet_wavs() {
    local src=/usr/share/sounds/alsa
    [[ -r "$src/Front_Left.wav" ]] || die "Missing $src/Front_Left.wav (package alsa-utils / alsa-base)."
    mkdir -p "$QUIET_WAVS"
    python3 - "$src" "$QUIET_WAVS" "$TEST_VOLUME" <<'PY' || die "Could not create quiet test sounds."
import array, glob, os, sys, wave
src, dst, vol = sys.argv[1], sys.argv[2], float(sys.argv[3])
vol = max(0.0, min(vol, 1.0))
for f in glob.glob(os.path.join(src, "*.wav")):
    with wave.open(f) as w:
        params, frames = w.getparams(), w.readframes(w.getnframes())
    if params.sampwidth != 2:
        continue
    a = array.array("h", frames)
    if sys.byteorder == "big":
        a.byteswap()
    a = array.array("h", (int(x * vol) for x in a))
    if sys.byteorder == "big":
        a.byteswap()
    with wave.open(os.path.join(dst, os.path.basename(f)), "wb") as w:
        w.setparams(params)
        w.writeframes(a.tobytes())
PY
}

# say_channels DEVICE CHANNELS [LOOPS]  -> quiet "Front Left", "Front Right", ...
say_channels() {
    [[ -r "$QUIET_WAVS/Front_Left.wav" ]] || make_quiet_wavs
    speaker-test -D "$1" -c "$2" -t wav -W "$QUIET_WAVS" -l "${3:-1}"
}

# Quietly repeat the channel names in the background (for the GPIO probe).
# tone_start CHANNELS  -> sets TONE_PID
tone_start() {
    local ch="${1:-2}"
    [[ -r "$QUIET_WAVS/Front_Left.wav" ]] || make_quiet_wavs
    speaker-test -D "plughw:${CARD},0" -c "$ch" -t wav -W "$QUIET_WAVS" -l 0 >/dev/null 2>&1 &
    TONE_PID=$!
    sleep 1
    kill -0 "$TONE_PID" 2>/dev/null || { warn "speaker-test failed to start on plughw:${CARD},0"; TONE_PID=""; return 1; }
}
tone_stop() {
    if [[ -n "${TONE_PID:-}" ]]; then
        kill "$TONE_PID" 2>/dev/null || true
        wait "$TONE_PID" 2>/dev/null || true
    fi
    TONE_PID=""
}
