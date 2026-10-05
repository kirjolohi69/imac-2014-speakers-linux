# imac-2014-speakers-linux

Getting the internal speakers of the **iMac 21.5" Mid 2014 (iMac14,4)** working
properly on Linux (tested target: Linux Mint 22.3).

Status: **investigating.** The scripts collect information and run reversible
experiments. Nothing here is a finished fix yet.

## Safety rules for this project

Everything is designed so your Mint install can't be broken:

| Kind of change | Where it lives | How to undo |
|---|---|---|
| Reading hardware info (`01`) | nothing is changed | – |
| Test tones (`02`) | PipeWire paused while testing | restarted automatically |
| GPIO / pin experiments (`03`, `04`) | **RAM only**, inside the running sound driver | `scripts/undo.sh` **or just reboot** |
| (Later) a real fix | one clearly named file in `/etc/modprobe.d/` | `scripts/undo.sh` + reboot |

* No kernel is replaced, nothing is compiled into the system, no firmware/NVRAM
  is written.
* Sound settings can't stop Linux from booting. The worst case for any of this
  is "no sound until reboot".
* Scripts run as your normal user and only call `sudo` for the single commands
  that need it.

## How to run

```bash
git clone https://github.com/kirjolohi69/imac-2014-speakers-linux.git
cd imac-2014-speakers-linux

# Step 1 - read-only hardware report (do this first and share the result)
scripts/01-collect-info.sh
```

Then commit and push the new folder under `reports/` (or paste
`reports/*/SUMMARY.txt` and the `card*-codec_0.txt` file). That tells us how
the codec is wired on *your* machine and which experiment to run next.

Later steps (need `sudo apt install alsa-tools` for `hda-verb`):

```bash
scripts/02-tone-test.sh    # announce "Front Left" etc. on 2/4/6/8 channels, note what you hear
scripts/03-gpio-probe.sh   # flip each codec GPIO to find the speaker amplifier switch
scripts/04-pin-probe.sh    # temporarily tell the driver which pins are speakers
scripts/05-macos-verbs.sh  # send the commands macOS uses to switch the speakers on
scripts/06-isolate.sh      # (after a reboot) find which of those commands is needed
scripts/07-channel-map.sh  # which channel is which driver, and does PipeWire's format work
scripts/undo.sh            # put everything back (a reboot also does)
```

Each step writes its results into `reports/`.

Test sounds are played quietly (15% of full scale). Make them quieter or louder
with e.g. `TEST_VOLUME=0.05 scripts/02-tone-test.sh` or `TEST_VOLUME=0.3 ...`.
The desktop volume slider does not affect these tests.

See [docs/background.md](docs/background.md) for background and
[docs/findings.md](docs/findings.md) for what the reports have shown so far.
