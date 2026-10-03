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
