#!/usr/bin/env bash
# Remove the speaker fix installed by scripts/install-fix.sh and put the
# previous sound profile and default output back.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

CONF="$HOME/.config/pipewire/pipewire.conf.d/60-imac-speakers.conf"
SYS_CONF="/etc/pipewire/pipewire.conf.d/60-imac-speakers.conf"
SYS_WP="/etc/wireplumber/main.lua.d/51-imac-speakers.lua"
SAVE="$HOME/.local/state/imac-speakers/previous"

found=0
if [[ -f $CONF ]]; then
    say "Removing $CONF"
    rm -f "$CONF"; found=1
fi
if [[ -f $SYS_CONF || -f $SYS_WP ]]; then
    say "Removing the system-wide files (sudo may ask for your password)"
    sudo rm -f "$SYS_CONF" "$SYS_WP"; found=1
    say "Other users go back to normal at their next login."
fi
[[ $found == 1 ]] || say "No fix config found (already removed)."

say "Restarting PipeWire"
systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service
sleep 2

if [[ -f $SAVE ]]; then
    # shellcheck disable=SC1090
    source "$SAVE"
    if [[ -n "${PREV_PROFILE:-}" ]]; then
        say "Restoring card profile: $PREV_PROFILE"
        pactl set-card-profile "$PA_CARD" "$PREV_PROFILE" || warn "Could not restore the profile; pick it in Sound settings."
    fi
    if [[ -n "${PREV_SINK:-}" && "$PREV_SINK" != imac_speakers ]]; then
        sleep 1
        pactl set-default-sink "$PREV_SINK" 2>/dev/null || true
    fi
    rm -f "$SAVE"
fi
say "Uninstalled."
