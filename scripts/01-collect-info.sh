#!/usr/bin/env bash
# Step 1: READ-ONLY. Collects everything we need to understand how the
# iMac's speakers are wired. Changes nothing on the system.
#
# Output goes to reports/<model>-<date>/ inside this repo. Nothing personal
# (serial numbers, user names, host name) is collected, so the report can be
# committed / shared.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr -cd 'A-Za-z0-9,._-')"
OUT="$REPO_DIR/reports/${MODEL:-unknown}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
say "Writing report to $OUT"

run() {  # run <outfile> <command...>   (errors are recorded, never fatal)
    local f="$OUT/$1"; shift
    { echo "\$ $*"; "$@"; } >"$f" 2>&1 || echo "(exit code $?)" >>"$f"
}

# --- machine / OS ---------------------------------------------------------
{
    for k in sys_vendor product_name product_version board_name bios_vendor bios_version bios_date; do
        printf '%-16s %s\n' "$k" "$(cat /sys/class/dmi/id/$k 2>/dev/null)"
    done
    echo; uname -a
    echo; cat /etc/os-release 2>/dev/null
} >"$OUT/system.txt"

run lspci-audio.txt  bash -c "lspci -nnk | grep -A4 -i audio"
run asound-cards.txt cat /proc/asound/cards
run aplay-l.txt      aplay -l
run aplay-L.txt      aplay -L
run lsmod-snd.txt    bash -c "lsmod | grep -i snd"

# --- the codec itself (most important part) ---------------------------------
for f in /proc/asound/card*/codec#*; do
    [[ -r $f ]] || continue
    c="$(basename "$(dirname "$f")")"
    cp "$f" "$OUT/${c}-$(basename "$f" | tr '#' '_').txt"
done

for d in /sys/class/sound/hwC*D*; do
    [[ -d $d ]] || continue
    n="$(basename "$d")"
    for a in vendor_name chip_name vendor_id subsystem_id revision_id modelname \
             init_pin_configs driver_pin_configs user_pin_configs hints init_verbs; do
        [[ -r "$d/$a" ]] && { echo "### $a"; cat "$d/$a"; echo; }
    done >"$OUT/sysfs-$n.txt" 2>&1
done

run module-params.txt bash -c 'for p in /sys/module/snd_hda_intel/parameters/* /sys/module/snd_hda_codec/parameters/*; do [ -r "$p" ] && echo "$p = $(cat "$p")"; done'
run modprobe-d.txt    bash -c "grep -rH . /etc/modprobe.d/ 2>/dev/null | grep -i -E 'snd|hda|alsa'"
run firmware-patch.txt bash -c "ls -la /lib/firmware/*.fw /lib/firmware/hda* 2>/dev/null"

# --- mixer / sound server state --------------------------------------------
if find_cirrus_codec; then
    run amixer-contents.txt amixer -c "$CARD" contents
    run amixer-scontents.txt amixer -c "$CARD" scontents
fi
run pactl-info.txt    pactl info
run pactl-sinks.txt   pactl list sinks
run pactl-cards.txt   pactl list cards
run wpctl-status.txt  wpctl status

# --- EFI boot-chime variables (READ ONLY). On some Macs the firmware only
# powers the speaker amp if the startup chime is not muted. -------------------
{
    for v in /sys/firmware/efi/efivars/SystemAudioVolume-* /sys/firmware/efi/efivars/StartupMute-* \
             /sys/firmware/efi/efivars/SystemAudioVolumeDB-*; do
        [[ -e $v ]] || continue
        echo "$(basename "$v"):"; od -An -tx1 "$v"
    done
} >"$OUT/efi-chime.txt" 2>&1

# --- kernel log (needs sudo to read on Mint) ---------------------------------
say "Reading kernel messages about sound (sudo may ask for your password)..."
sudo dmesg 2>/dev/null | grep -i -E 'snd|hda|cs42|cirrus|audio' >"$OUT/dmesg-sound.txt" \
    || echo "(could not read dmesg)" >"$OUT/dmesg-sound.txt"

# --- optional: alsa-info (very complete, upstream ALSA tool) -----------------
if command -v alsa-info >/dev/null || [[ -x /usr/sbin/alsa-info ]]; then
    ai="$(command -v alsa-info || echo /usr/sbin/alsa-info)"
    "$ai" --no-upload --stdout >"$OUT/alsa-info.txt" 2>&1 || true
fi

# --- quick human-readable summary -------------------------------------------
{
    echo "Model: $MODEL   Kernel: $(uname -r)"
    if find_cirrus_codec; then
        echo "Cirrus codec: $CODEC_NAME on card $CARD, codec address $CODEC_ADDR"
        grep -E '^(Vendor Id|Subsystem Id|Revision Id):' "$CODEC_FILE"
        echo
        echo "GPIO state:"
        sed -n '/^GPIO:/,/^Node/p' "$CODEC_FILE" | grep -v '^Node'
        echo
        echo "Pins and their default configs (what the firmware/driver thinks is wired):"
        awk '/^Node 0x/ {node=$2; type=$0} /Pin Default/ {print node "  " $0}' "$CODEC_FILE"
        echo
        echo "Pin controls (OUT = output enabled):"
        awk '/^Node 0x/ {node=$2} /Pin-ctls:/ {print node "  " $0}' "$CODEC_FILE"
    else
        echo "!! No Cirrus Logic codec found."
    fi
    echo
    grep -h -i -E 'autoconfig|line_outs|speaker_outs|hp_outs|cs4208|cs420' "$OUT/dmesg-sound.txt" 2>/dev/null
} >"$OUT/SUMMARY.txt"

cat "$OUT/SUMMARY.txt"
echo
say "Done. Report saved in: $OUT"
say "Next: commit and push it (git add reports && git commit -m 'Add hardware report' && git push), or paste SUMMARY.txt + the codec file."
