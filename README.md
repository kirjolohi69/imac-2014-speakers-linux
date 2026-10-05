# imac-2014-speakers-linux

Getting the internal speakers of the **iMac 21.5" Mid 2014 (iMac14,4)** working
properly on Linux (tested target: Linux Mint 22.3).

Status: **working fix (testing).** The speakers work once the codec gets a
4-channel stream. Each side is a 2-way speaker (tweeter + woofer) on its own
digital link. The fix is a PipeWire setting in your home folder. See
[docs/findings.md](docs/findings.md) for how we got here.

## Install the fix

```bash
bash scripts/install-fix.sh --system   # for every user on this iMac (asks for sudo)
bash scripts/install-fix.sh            # or: just for you
# optional last argument: crossover in Hz, default 2500
```

This creates a stereo output called **"iMac Speakers"**, makes it the
default, and sets its volume to 30% (other users start at 100% the first
time they use it). It splits the sound into the 4 channels
the speakers need: treble to the tweeters, bass to the woofers.

* Undo: `bash scripts/uninstall-fix.sh` (restores your previous sound setup).
* Changed files: `/etc/pipewire/pipewire.conf.d/60-imac-speakers.conf` and
  `/etc/wireplumber/main.lua.d/51-imac-speakers.lua` (`--system`), or
  `~/.config/pipewire/pipewire.conf.d/60-imac-speakers.conf` (just you), plus
  the card profile and default output, which uninstall puts back.
* Headphones: switch the built-in card's profile to "Analog Stereo Duplex" in
  Sound settings (and back to "Analog Surround 4.0 Output" for the speakers).

## Safety rules for this project

Everything is designed so your Mint install can't be broken:

| Kind of change | Where it lives | How to undo |
|---|---|---|
| Reading hardware info (`01`) | nothing is changed | – |
| Test tones (`02`) | PipeWire paused while testing | restarted automatically |
| GPIO / pin experiments (`03`, `04`) | **RAM only**, inside the running sound driver | `scripts/undo.sh` **or just reboot** |
| Vendor-command experiments (`05`, `06`) | **RAM only**, inside the codec | reboot |
| The fix (`install-fix.sh`) | one PipeWire file in your home folder, or two small files in `/etc` (`--system`) | `scripts/uninstall-fix.sh` |

* No kernel is replaced, nothing is compiled into the system, no firmware/NVRAM
  is written.
* Sound settings can't stop Linux from booting. The worst case for any of this
  is "no sound until reboot".
* Scripts run as your normal user and only call `sudo` for the single commands
  that need it.

## Investigation scripts

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
scripts/install-fix.sh     # install the fix (see above)
scripts/08-compare-sides.sh  # (with the fix installed) compare left/right drivers, check polarity
scripts/09-mic-headphones.sh # built-in microphone + headphone jack check
scripts/uninstall-fix.sh   # remove it
scripts/undo.sh            # put everything back (a reboot also does)
```

Each step writes its results into `reports/`.

Test sounds are played quietly (15% of full scale). Make them quieter or louder
with e.g. `TEST_VOLUME=0.05 scripts/02-tone-test.sh` or `TEST_VOLUME=0.3 ...`.
The desktop volume slider does not affect these tests.

See [docs/background.md](docs/background.md) for background and
[docs/findings.md](docs/findings.md) for what the reports have shown so far.
