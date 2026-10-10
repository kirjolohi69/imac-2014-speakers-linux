# iMac 2014 speakers on Linux

Working internal speakers for the **iMac 21.5-inch, Mid 2014 (`iMac14,4`)** on
Linux.

On this iMac the built-in speakers are completely silent on Linux, even though
the sound card is detected and everything looks fine in the sound settings.
This repo fixes that with a small PipeWire configuration: no kernel module,
no compiling, nothing outside two config files. One command to install, one to
remove.

**Status:** works on the author's iMac14,4 with Linux Mint 22.3 (kernel 7.0,
PipeWire 1.0.5, WirePlumber 0.4.17). Reports from other distros and from other
iMac models are very welcome, see [Help wanted](#help-wanted).

## Is this for my Mac?

```bash
cat /sys/class/dmi/id/product_name    # should print: iMac14,4
```

The installer checks this and warns you on any other model. Other Macs with the
same Cirrus Logic CS4208 sound chip may need the same idea with a different
channel layout. [Help wanted](#help-wanted) explains how to check.

## What was wrong

The speakers aren't wired like normal laptop or desktop speakers:

* **Each side is a 2-way speaker** (a tweeter and a woofer) behind its own
  amplifier, fed over a digital link from the sound chip.
* The chip only sends audio to the amplifiers when it plays a
  **4-channel stream**. Normal stereo (2 channels) is silently dropped, which
  is why the speakers seem dead on Linux.
* The 4 channels are not front/rear but one driver each:

  | Channel | Driver |
  |---|---|
  | 1 (FL) | left tweeter |
  | 2 (FR) | left woofer |
  | 3 (RL) | right tweeter |
  | 4 (RR) | right woofer |

The fix adds a normal stereo output called **"iMac Speakers"**. It splits each
side with a crossover (treble above about 2.5 kHz to the tweeter, bass below it
to the woofer) and plays the result on the card's 4-channel output. The
crossover also keeps bass away from the small tweeters.

The full investigation, with every test result, is in
[docs/findings.md](docs/findings.md).

## Requirements

* PipeWire as the sound server (the default on Linux Mint 22+, Ubuntu 22.10+,
  Fedora, and most current distros). `pactl info` should mention PipeWire.
* `pactl` (Debian/Ubuntu/Mint: `sudo apt install pulseaudio-utils`; Fedora:
  `sudo dnf install pulseaudio-utils`; Arch: `sudo pacman -S libpulse`)
* WirePlumber 0.4 or 0.5. Only tested on 0.4 so far.

## Install

```bash
git clone https://github.com/kirjolohi69/imac-2014-speakers-linux.git
cd imac-2014-speakers-linux

bash scripts/install-fix.sh --system   # for every user on this computer (asks for your password)
# or
bash scripts/install-fix.sh            # just for your own user account
```

No git? Click **Code → Download ZIP** on GitHub, unzip it, and run the same
commands from the unzipped folder.

The installer creates the "iMac Speakers" output, makes it your default output,
and **sets its volume to 30%**. Play some music and turn it up from there.

With `--system`, other users get working speakers at their next login. The
first time, their "iMac Speakers" volume starts at 100%; after they change it,
it's remembered.

### What it changes

| Install type | Files |
|---|---|
| `--system` | `/etc/pipewire/pipewire.conf.d/60-imac-speakers.conf`, plus `/etc/wireplumber/main.lua.d/51-imac-speakers.lua` (WirePlumber 0.4) or `/etc/wireplumber/wireplumber.conf.d/51-imac-speakers.conf` (WirePlumber 0.5) |
| just you | `~/.config/pipewire/pipewire.conf.d/60-imac-speakers.conf` |

It also switches the built-in card to the **"Analog Surround 4.0 Output +
Analog Stereo Input"** profile, which keeps the microphone input available
(the microphone itself hasn't been tested yet).
Your previous profile and default output are saved so uninstalling can put them
back.

### Uninstall

```bash
bash scripts/uninstall-fix.sh
```

This removes the files above and restores your previous sound settings.

## Using it

* **Pick "iMac Speakers"** as the output in Sound settings. "Speakers –
  Built-in Audio" is the raw 4-channel output underneath. It still shows up, but
  if you select it directly, each driver gets the wrong part of the sound.
* **Headphones:** the headphone jack only works in the stereo profile. Switch
  the built-in card's profile to "Analog Stereo Duplex" and select the
  headphones. Switch back to "Analog Surround 4.0 Output" and "iMac Speakers"
  for the speakers. (Automatic switching is on the to-do list.)
* **Balance slider:** works normally on "iMac Speakers", so it's an easy way to
  check each speaker on its own.
* **Crossover:** 2500 Hz is a reasonable guess, not a measured value. If voices
  sound thin or harsh, try a lower value; if they sound muffled, a higher one.
  Re-running the installer replaces the old setting:

  ```bash
  bash scripts/install-fix.sh --system 2000
  ```

* **Better sound with EasyEffects:** the fix only splits the sound; it doesn't
  apply the speaker tuning macOS uses. EasyEffects can add that. Set its output
  device to **"iMac Speakers"**. Boost bass gently, cut below about 80–100 Hz
  (the small woofers can't play lower), and put a limiter last.

## Troubleshooting

* **No sound after installing:** check that "iMac Speakers" is selected and
  that the built-in card's profile is "Analog Surround 4.0 Output". A profile
  you picked by hand earlier wins over the installer's preference, so pick
  the 4.0 profile once in Sound settings.
* **"iMac Speakers" doesn't appear:** run
  `journalctl --user -u pipewire -u wireplumber -n 50` and open an issue with
  the output.
* **Still nothing:** run `bash scripts/01-collect-info.sh` (read-only, no
  personal data such as serial numbers) and attach the folder it creates under
  `reports/` to an issue.

## Help wanted

* **Other distros / WirePlumber 0.5:** if you install this on something other
  than Mint 22.3, please open an issue saying whether it worked.
* **Other iMac models:** some other Macs with a CS4208 chip (for example the
  iMac 2015 models) may have the same 4-channel speaker wiring. On those,
  `scripts/07-channel-map.sh` plays each of the 4 channels separately so you can
  write down which driver it reaches. Please share the result together with
  `scripts/01-collect-info.sh`.
* **Mic and headphones:** `scripts/09-mic-headphones.sh` tests the built-in
  microphone and the headphone jack. Results are welcome.

## The investigation scripts

The `scripts/0*-*.sh` scripts are the tools used to figure all this out. They
are safe to run: they only read information, play quiet test sounds, or change
settings that live in RAM until the next reboot. Nothing is written to firmware
or NVRAM.

| Script | What it does |
|---|---|
| `01-collect-info.sh` | read-only hardware report into `reports/` |
| `02-tone-test.sh` | announce channel names on 2 and 4 channels, straight to the hardware |
| `03-gpio-probe.sh` | flip codec GPIO lines one by one (needs `hda-verb` from `alsa-tools`) |
| `04-pin-probe.sh` | temporarily override the codec's pin configuration |
| `05-macos-verbs.sh` | send codec commands macOS uses on similar Macs (needs `hda-verb`) |
| `06-isolate.sh` | after a reboot: find which of those is needed (answer: none, just 4 channels) |
| `07-channel-map.sh` | play each channel alone to map it to a driver |
| `08-compare-sides.sh` | compare left/right drivers and check polarity (with the fix installed) |
| `09-mic-headphones.sh` | test the built-in microphone and headphone jack |
| `undo.sh` | undo any leftover runtime experiment (a reboot does too) |

Test sounds play at 15% of full scale. Set `TEST_VOLUME=0.05` (quieter) or
`TEST_VOLUME=0.3` (louder) in front of a command to change that. The desktop
volume slider has no effect on them.

`reports/` contains the author's own reports, kept as a reference.

## Credits

* The Linux kernel's Cirrus Logic HD-audio driver (`sound/hda/codecs/cirrus/cs420x.c`).
* [leifliddy/macbook12-audio-driver](https://github.com/leifliddy/macbook12-audio-driver)
  and its capture of macOS codec commands on the 12-inch MacBook, which has
  the same chip. It pointed the investigation in the right direction.
* Built with help from Claude (Anthropic).

## License

MIT, see [LICENSE](LICENSE). No warranty: this changes sound settings only, but
use it at your own risk.
