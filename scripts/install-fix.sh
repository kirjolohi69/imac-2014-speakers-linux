#!/usr/bin/env bash
# Install the speaker fix for the current user: a PipeWire virtual sink
# "iMac Speakers" that turns stereo into the 4 channels the speakers need.
#
# What it changes (all inside your home folder, nothing system-wide):
#   * ~/.config/pipewire/pipewire.conf.d/60-imac-speakers.conf   (new file)
#   * the built-in card's profile -> "Analog Surround 4.0 Output + Analog Stereo Input"
#   * the default output -> "iMac Speakers" (volume set to 30% to start)
# The previous profile/default output are saved and restored by
# scripts/uninstall-fix.sh.
#
# Usage: scripts/install-fix.sh [crossover_hz]      default crossover: 2500
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cirrus

XOVER="${1:-2500}"
[[ $XOVER =~ ^[0-9]+$ && $XOVER -ge 500 && $XOVER -le 8000 ]] || die "Crossover must be a whole number of Hz between 500 and 8000."

CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"
CONF="$CONF_DIR/60-imac-speakers.conf"
SAVE_DIR="$HOME/.local/state/imac-speakers"
PROFILE="output:analog-surround-40+input:analog-stereo"
mkdir -p "$CONF_DIR" "$SAVE_DIR"

PA_CARD="$(pactl list short cards | awk '/pci-0000_00_1b/ {print $2; exit}')"
[[ -n $PA_CARD ]] || die "Built-in sound card not found in PipeWire (is PipeWire running?)."
TARGET="alsa_output.${PA_CARD#alsa_card.}.analog-surround-40"

# Remember the current setup once, so uninstall can put it back.
if [[ ! -f "$SAVE_DIR/previous" ]]; then
    prev_profile="$(pactl list cards | awk -v c="$PA_CARD" '$1=="Name:" {inc=($2==c)} inc && /Active Profile:/ {print $3; exit}')"
    prev_sink="$(pactl get-default-sink 2>/dev/null || true)"
    printf 'PA_CARD=%q\nPREV_PROFILE=%q\nPREV_SINK=%q\n' "$PA_CARD" "$prev_profile" "$prev_sink" >"$SAVE_DIR/previous"
fi

say "Writing $CONF (crossover ${XOVER} Hz, target $TARGET)"
sed -e "s/@XOVER@/${XOVER}.0/g" -e "s/@TARGET@/${TARGET}/g" "$REPO_DIR/fix/imac-speakers.conf.in" >"$CONF"

say "Switching the built-in card to the 4-channel profile"
pactl set-card-profile "$PA_CARD" "$PROFILE"

say "Restarting PipeWire to load the new sink"
systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service
for _ in $(seq 1 20); do
    pactl list short sinks 2>/dev/null | grep -q "imac_speakers" && break
    sleep 0.5
done
pactl list short sinks | grep -q "imac_speakers" || die "The 'iMac Speakers' sink did not appear. Check: journalctl --user -u pipewire -n 50"

# WirePlumber may restore the old profile on restart; set it again.
pactl set-card-profile "$PA_CARD" "$PROFILE" || true
sleep 1
pactl set-sink-volume "$TARGET" 100% 2>/dev/null || true     # raw 4ch output at 0 dB; volume is done on iMac Speakers
pactl set-default-sink imac_speakers
pactl set-sink-volume imac_speakers 30%
pactl set-sink-mute imac_speakers 0

say "Installed. 'iMac Speakers' is now the default output, at 30% volume."
say "Play some music and raise the volume slowly."
say "Headphones: switch the 'Speakers - Built-in Audio' profile to 'Analog Stereo Duplex' in Sound settings."
say "To remove: scripts/uninstall-fix.sh"
