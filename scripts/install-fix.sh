#!/usr/bin/env bash
# Install the speaker fix for the current user: a PipeWire virtual sink
# "iMac Speakers" that turns stereo into the 4 channels the speakers need.
#
# Two ways to install:
#
#   scripts/install-fix.sh [crossover_hz]            just for you
#     * ~/.config/pipewire/pipewire.conf.d/60-imac-speakers.conf
#
#   scripts/install-fix.sh --system [crossover_hz]   for every user (asks for sudo)
#     * /etc/pipewire/pipewire.conf.d/60-imac-speakers.conf
#     * /etc/wireplumber/main.lua.d/51-imac-speakers.lua           (WirePlumber 0.4)
#       or /etc/wireplumber/wireplumber.conf.d/51-imac-speakers.conf (WirePlumber 0.5+)
#       which prefer the 4-channel profile for users who haven't picked one themselves
#     * removes the per-user file above, so the sink isn't created twice
#
# For you (the user running the script) it also switches the built-in card to
# "Analog Surround 4.0 Output + Analog Stereo Input" and makes "iMac Speakers"
# the default output with its volume slider at 30%. The previous profile and
# default output are saved and restored by scripts/uninstall-fix.sh.
#
# Default crossover: 2500 Hz
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cirrus

command -v pactl >/dev/null || die "pactl is missing. Install it first (Debian/Ubuntu/Mint: sudo apt install pulseaudio-utils, Fedora: sudo dnf install pulseaudio-utils, Arch: sudo pacman -S libpulse)."
[[ "$(pactl info 2>/dev/null)" == *PipeWire* ]] || die "This fix needs PipeWire as the sound server (pactl info should mention PipeWire)."

MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
if [[ $MODEL != "iMac14,4" ]]; then
    warn "This fix was made for the iMac14,4 (21.5-inch, Mid 2014). This computer is: $MODEL"
    warn "Its speakers may be wired differently. Check with scripts/07-channel-map.sh first."
    ask_yn "Install anyway?" || exit 1
fi

SYSTEM=0
if [[ ${1:-} == --system ]]; then SYSTEM=1; shift; fi
XOVER="${1:-2500}"
[[ $XOVER =~ ^[0-9]+$ && $XOVER -ge 500 && $XOVER -le 8000 ]] || die "Crossover must be a whole number of Hz between 500 and 8000."

USER_CONF="$HOME/.config/pipewire/pipewire.conf.d/60-imac-speakers.conf"
SYS_CONF="/etc/pipewire/pipewire.conf.d/60-imac-speakers.conf"
SYS_WP04="/etc/wireplumber/main.lua.d/51-imac-speakers.lua"
SYS_WP05="/etc/wireplumber/wireplumber.conf.d/51-imac-speakers.conf"
SAVE_DIR="$HOME/.local/state/imac-speakers"
PROFILE="output:analog-surround-40+input:analog-stereo"
mkdir -p "$SAVE_DIR"
if [[ $SYSTEM == 0 && -f $SYS_CONF ]]; then
    die "The fix is already installed system-wide. To change it, run: scripts/install-fix.sh --system [crossover_hz]"
fi

PA_CARD="$(pactl list short cards | awk '/pci-0000_00_1b/ {print $2; exit}')"
[[ -n $PA_CARD ]] || die "Built-in sound card not found in PipeWire (is PipeWire running?)."
TARGET="alsa_output.${PA_CARD#alsa_card.}.analog-surround-40"

# Remember the current setup once, so uninstall can put it back.
if [[ ! -f "$SAVE_DIR/previous" ]]; then
    prev_profile="$(pactl list cards | awk -v c="$PA_CARD" '$1=="Name:" {inc=($2==c)} inc && /Active Profile:/ {print $3; exit}')"
    prev_sink="$(pactl get-default-sink 2>/dev/null || true)"
    printf 'PA_CARD=%q\nPREV_PROFILE=%q\nPREV_SINK=%q\n' "$PA_CARD" "$prev_profile" "$prev_sink" >"$SAVE_DIR/previous"
fi

TMP="$(mktemp -d)"
sed -e "s/@XOVER@/${XOVER}.0/g" -e "s/@TARGET@/${TARGET}/g" "$REPO_DIR/fix/imac-speakers.conf.in" >"$TMP/60-imac-speakers.conf"
sed -e "s/@CARD@/${PA_CARD}/g" "$REPO_DIR/fix/51-imac-speakers.lua" >"$TMP/51-imac-speakers.lua"
sed -e "s/@CARD@/${PA_CARD}/g" "$REPO_DIR/fix/51-imac-speakers.conf" >"$TMP/51-imac-speakers.conf"

if [[ $SYSTEM == 1 ]]; then
    say "Installing system-wide (crossover ${XOVER} Hz). sudo may ask for your password."
    sudo install -D -m 644 "$TMP/60-imac-speakers.conf" "$SYS_CONF"
    say "  $SYS_CONF"
    wp_ver="$(wireplumber --version 2>/dev/null | sed -n 's/.*libwireplumber \([0-9]*\.[0-9]*\).*/\1/p' | head -n1)"
    if [[ $wp_ver == 0.4 ]]; then
        sudo install -D -m 644 "$TMP/51-imac-speakers.lua" "$SYS_WP04"
        say "  $SYS_WP04"
    else
        sudo install -D -m 644 "$TMP/51-imac-speakers.conf" "$SYS_WP05"
        say "  $SYS_WP05 (WirePlumber ${wp_ver:-version unknown})"
    fi
    if [[ -f $USER_CONF ]]; then
        say "Removing your per-user copy ($USER_CONF), the system-wide one replaces it"
        rm -f "$USER_CONF"
    fi
else
    say "Writing $USER_CONF (crossover ${XOVER} Hz, target $TARGET)"
    install -D -m 644 "$TMP/60-imac-speakers.conf" "$USER_CONF"
fi
rm -rf "$TMP"

trap 'warn "Step failed: $BASH_COMMAND (line $LINENO)"' ERR

# retry N CMD...  -> run CMD until it succeeds, up to N times, 0.5 s apart
retry() {
    local n=$1; shift
    for ((i = 0; i < n; i++)); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    "$@"   # last try, showing the error
}
has_sink() { pactl list short sinks | awk -v s="$1" '$2==s {f=1} END {exit !f}'; }

say "Restarting PipeWire to load the new config"
systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service
retry 20 pactl info

say "Switching the built-in card to the 4-channel profile"
retry 20 pactl set-card-profile "$PA_CARD" "$PROFILE"
retry 20 has_sink "$TARGET" || die "The 4-channel output ($TARGET) did not appear."
retry 20 has_sink imac_speakers || die "The 'iMac Speakers' sink did not appear. Check: journalctl --user -u pipewire -u wireplumber -n 50"

pactl set-sink-volume "$TARGET" 100% || true     # raw 4ch output at 0 dB; volume is done on iMac Speakers
retry 10 pactl set-default-sink imac_speakers
retry 10 pactl set-sink-volume imac_speakers 30%
retry 10 pactl set-sink-mute imac_speakers 0

say "Installed. 'iMac Speakers' is now your default output; its volume slider starts at 30%."
if [[ $SYSTEM == 1 ]]; then
    say "Other users get it at their next login (log them out first if they are logged in)."
    say "Their 'iMac Speakers' volume starts at 100% the first time; they can lower it once, it is remembered."
fi
say "Play some music and raise the volume slowly."
say "Headphones: switch the 'Speakers - Built-in Audio' profile to 'Analog Stereo Duplex' in Sound settings,"
say "and pick the headphones as output. Switch back to 'Analog Surround 4.0 Output' + 'iMac Speakers' afterwards."
say "To remove: scripts/uninstall-fix.sh"
