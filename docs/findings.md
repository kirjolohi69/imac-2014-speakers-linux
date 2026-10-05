# Findings

## Report 1: `reports/iMac14,4-20261003-184017` (kernel 7.0.0-38, Mint 22.3)

### Facts

* Codec: **Cirrus Logic CS4208**, card 2 (`HDA Intel PCH`), subsystem ID
  `0x106b7900` when read now. At boot the driver logged
  `picked fixup  for codec SSID 106b:0000` (empty name), so it read a zero SSID at
  probe time. `7900` isn't in the driver's table either, so either way it falls
  back to the default `gpio0` fixup.
* GPIO: 6 GPIOs. **GPIO0 is driven high**, GPIO1-5 unused. If GPIO0 is the
  amp-enable line, the amp is on.
* The firmware's pin configuration is **sensible**:

  | Pin | Type | Fed by | Config | Driver role |
  |---|---|---|---|---|
  | 0x1d | 8-channel **digital** out | converter 0x0a (8-ch digital) | Fixed internal speaker, assoc 1 seq 0 | "Speaker **Front**" |
  | 0x1e | 8-channel **digital** out | converter 0x0b (8-ch digital) | Fixed internal speaker, assoc 1 seq 2 | "Speaker **Surround**" |
  | 0x10 | analog HP jack | DAC 0x02 | HP | Headphone |
  | 0x21 | S/PDIF (optical, in the HP jack) | 0x0e | SPDIF | IEC958 |

  Kernel autoconfig: `line_outs=2 (0x1d/0x1e) type:speaker`. So the driver
  already sends audio to the right pins. Hypothesis 1 ("wrong pin") is
  **ruled out**.
* Analog pins 0x11-0x14 are marked unconnected, which is correct here.
* Both speaker links are digital (I2S/TDM-style) links to an external amplifier.
  They have **no hardware volume control**. The only volume controls are `Master`
  (a virtual master that in practice only reaches the headphone DAC),
  `Headphone`, and the alsa-lib software volume `PCM` (0-255).
* EFI `SystemAudioVolume` = `0x5d` (bit 7 clear). **The startup chime is not
  muted**, so the "firmware leaves the amp off" problem doesn't apply.
* PipeWire: card profile **`analog-stereo`** is active. The card also offers
  `analog-surround-21` and `analog-surround-40`.

### Interpretation

The speaker system is wired as **two digital links**: 0x1d (Front) and 0x1e
(Surround). With the default `analog-stereo` profile, PipeWire opens a
2-channel stream, so **only 0x1d receives audio and 0x1e gets nothing**.
If the amp(s) expect content on both links (e.g. one link per speaker, or
one link for woofers and one for tweeters), part of the speaker system stays
silent. That would sound thin, quiet, or one-sided.

### Next experiment

1. `scripts/02-tone-test.sh` (now defaults to 2 and 4 channels). We need to
   know which physical speaker plays each of Front L/R and Rear L/R.
2. Quick GUI check: Sound settings → Built-in Audio → profile
   **"Analog Surround 4.0 Output"**, then play music. Does it sound fuller?
   (Switch back to "Analog Stereo Duplex" afterwards; nothing is saved
   beyond that menu choice.)

If 0x1e drives part of the speakers, the fix is a small user-level PipeWire
config: a virtual stereo "iMac Speakers" sink that copies L/R onto all
four channels in the right order, with software volume. That's one file in
`~/.config/`, easy to delete, and needs no kernel changes.

## Test 2: desktop sound settings and tone test

* No sound at all from the speakers with the Analog Stereo, 2.1 and 4.0
  profiles, nor from the direct-to-hardware tone test (2 channels).
* So the problem is complete silence, not channel layout. The routing is
  right, so the amplifier or the digital link to it isn't being switched on.

### Lead: what macOS does on the 12" MacBook (same chip, same routing)

The MacBook9,1 driver (github.com/leifliddy/macbook12-audio-driver) replays a
capture of macOS's codec commands. Before playing to the speakers, macOS:

* sends the vendor verb `0x7f0` with value `3` to converter `0x0a`
  (Linux never does);
* sets GPIO direction `0x31`, mask `0x37`, data `0x01` (GPIO0 high, GPIO4/5
  driven low; Linux only touches GPIO0);
* sets DIGI_CONVERT_2 = 1 and DIGI_CONVERT_1 = 0x11 on `0x0a`;
* sends a 4-channel stream into converter `0x0a`.

`scripts/05-macos-verbs.sh` applies these step by step while a quiet voice
plays.

## Test 3: `05-macos-verbs.sh` (first sound!)

```
baseline, 2ch                  -> silent
2ch + 0x7f0=3 on 0x0a/0x0b     -> silent
2ch + 0x7f0 + macOS GPIOs      -> silent
2ch + 0x7f0 + GPIOs + DIGI     -> silent
4ch, Linux routing             -> AUDIBLE
```

* With a **4-channel stream** the speakers play. Some channels sound full,
  others tinny (corrected in test 4 below: the split is per side, not per pair).
* The macOS commands were still active from the 2ch steps, and the desktop
  4.0 profile (4ch without the commands) was silent earlier. So the likely
  requirement is "4 channels **plus** one of the macOS commands".
  `scripts/06-isolate.sh` (run after a reboot) tests each one separately, and
  checks whether the setting survives a stream restart.
* Caution until we know whether the amp has its own crossover: the tweeters
  are getting full-range audio, so keep the volume moderate.

## Test 4: `06-isolate.sh` (after a reboot, clean codec)

```
1. 4ch, nothing changed                         -> AUDIBLE
2. 4ch + macOS GPIOs only                       -> AUDIBLE
3. 4ch + vendor verb 0x7f0=3 only               -> AUDIBLE
4. 4ch + vendor verb + macOS GPIOs              -> AUDIBLE
5. 4ch, new stream, no re-send                  -> AUDIBLE
6. 4ch, new stream, vendor verb re-sent         -> AUDIBLE
7. 2ch + vendor verb + macOS GPIOs              -> silent
```

* **No codec commands are needed.** The only requirement is a
  **4-channel stream**. A 2-channel stream is silent, even with all the macOS
  commands applied.
* **The layout is per side, not front/rear.** Channels 1 and 2 (converter
  0x0a -> pin 0x1d) both play from the **left** speaker. One sounds tinny
  (tweeter), one full (woofer): ch1 = tinny, ch2 = full. Channels 3 and 4
  (0x0b -> 0x1e) both play from the **right** speaker, one tinny and one full.
  Test 5 confirms ch3 = right tweeter, ch4 = right woofer.
* So each digital link feeds one side's 2-way speaker (tweeter + woofer).
  A normal stereo signal has to be split as L -> ch1+ch2, R -> ch3+ch4,
  ideally with a crossover (high-pass for tweeters, low-pass for woofers).
* The card number changed from 2 to 0 between boots, so a fix must not
  hard-code it.
* Open question: the desktop "Analog Surround 4.0" profile was silent in
  test 2, even though it is a 4-channel stream. `scripts/07-channel-map.sh`
  checks the sample formats PipeWire uses and plays through PipeWire.

## Test 5: `07-channel-map.sh`

```
A ch1: side=l sound=t      -> left tweeter
A ch2: side=l sound=f      -> left woofer
A ch3: side=r sound=t      -> right tweeter
A ch4: side=r sound=f      -> right woofer
B S32_LE 48000: AUDIBLE
B S16_LE 44100: not supported by hw
B S32_LE 44100: not supported by hw
C pipewire surround-40 (s32le 4ch 48000Hz, FL FR RL RR): AUDIBLE
```

* Complete map: FL = left tweeter, FR = left woofer, RL = right tweeter,
  RR = right woofer.
* The hardware accepts 48 kHz only. PipeWire's default (S32_LE, 48 kHz)
  works, and PipeWire resamples 44.1 kHz content itself.
* PipeWire's own "Analog Surround 4.0" profile reaches the speakers, so
  the fix can be done entirely in PipeWire. The earlier silent desktop test
  was probably a profile switch that hadn't taken effect.

## The fix: `scripts/install-fix.sh`

A PipeWire filter-chain (`fix/imac-speakers.conf.in`) creates a normal stereo
sink, **"iMac Speakers"**. It splits each side with a 4th-order
Linkwitz-Riley crossover (default 2500 Hz) and plays the result on the 4.0
output: L high -> FL, L low -> FR, R high -> RL, R low -> RR.

I checked it in a clean PipeWire 1.0.5 + WirePlumber 0.4.17 setup (the
versions in Mint 22.3), with a null 4-channel sink standing in for the
hardware:

| input | ch1 L-tw | ch2 L-wf | ch3 R-tw | ch4 R-wf |
|---|---|---|---|---|
| L=100 Hz, R=8 kHz | 0 | 100 Hz | 8 kHz | 0 |
| L=8 kHz, R=100 Hz | 8 kHz | 0 | 0 | 100 Hz |

Limitation: the headphone jack only exists in the "Analog Stereo" profile,
so headphones need a profile switch in Sound settings.

## Test 6: first listening with the fix

* "Sounds pretty good". The balance slider works and isolates each speaker.
* The left side sounds a bit bassier and "different" from the right. Possible
  causes: room placement (a wall or corner near one side), a level difference
  between the two woofers, or one side's tweeter wired with opposite polarity
  to its woofer (that changes how the drivers sum around the crossover).
  `scripts/08-compare-sides.sh` A/B-tests woofer vs woofer and tweeter vs
  tweeter, and checks in-phase vs flipped-tweeter on each side.
