# Background: why the speakers misbehave

## The hardware

* iMac14,4 (21.5", Mid 2014) uses a **Cirrus Logic CS4208** HD-Audio codec
  (to be confirmed by `01-collect-info.sh` on this machine).
* On several CS4208 Macs the internal speakers are **not** fed by an ordinary
  analog output. The codec sends audio over a digital pin (**0x1d**, sometimes
  also **0x1e**) to a separate speaker amplifier, and that amplifier is
  switched on through a codec **GPIO** pin. This is the "weird wiring".
* Because the amp is external, there is often no hardware volume control for
  the speakers; volume has to be done in software (PipeWire).

## What the Linux driver does today

The driver is `sound/hda/codecs/cirrus/cs420x.c` (older kernels:
`sound/pci/hda/patch_cirrus.c`). For CS4208 on Apple machines it looks up the
**codec subsystem ID** in a small table:

| Codec SSID | Machine | Fixup |
|---|---|---|
| 106b:5e00 | MacBookPro 11,2 | mbp11 |
| 106b:6c00 | MacMini 7,1 | macmini |
| 106b:7100 / 7200 | MacBookAir 6,x | mba6 |
| 106b:7800 | MacPro 6,1 | macmini |
| 106b:7b00 | MacBookPro 12,1 | mbp11 |
| 106b:7f00 | iMac 16,1 | mbp11 |

Anything not in the table gets the default `gpio0` fixup (GPIO0 = speaker amp
on, nothing else). There is **no entry for iMac14,4**. A
[CachyOS forum report](https://discuss.cachyos.org/t/no-sound-on-imac14-4-2014-21-5-cs4208-codec-fixup-not-applied-for-this-ssid/32577)
says this model reports codec SSID `106b:0000`, so it can never match a
table entry, and forcing `model=mba6/gpio0/mbp11/macmini` did not help there.

## Hypotheses to test (in order)

1. **Wrong pin**: the firmware's pin defaults point the driver at a pin that
   isn't connected to the speakers (e.g. 0x12) while 0x1d/0x1e are marked
   "not connected". → `04-pin-probe.sh`
2. **Amp not enabled**: the speaker amp sits on a GPIO other than GPIO0, or
   needs two GPIOs. → `03-gpio-probe.sh`
3. **Channel layout**: the speakers are split across channels (e.g. woofer
   and tweeter on different pin pairs), so plain stereo only reaches part of
   them, which sounds thin or quiet. → `02-tone-test.sh` with 4/6/8 channels
4. **Firmware leaves the amp off when the startup chime is muted**. Seen on
   12" MacBooks with CS4208: the firmware only powers the amp when the boot
   chime is enabled. Checked read-only by `01-collect-info.sh`
   (`efi-chime.txt`). If this turns out to matter, the safe fix is to turn the
   startup chime back on (from macOS, or by an NVRAM reset), *not* to write
   EFI variables from Linux.

Once the right combination is known, the fix will be a single
`/etc/modprobe.d/` file (a `model=` option and/or a small `patch=` firmware
file with pin configs and GPIO verbs), which `undo.sh` removes. If that isn't
enough, the next step would be a small out-of-tree kernel module built with
DKMS, also removable, and an upstream kernel patch adding iMac14,4 to the
table so nobody needs this repo.

## References

* Kernel driver source: <https://github.com/torvalds/linux/blob/master/sound/hda/codecs/cirrus/cs420x.c>
* iMac14,4 report (CachyOS forum): <https://discuss.cachyos.org/t/no-sound-on-imac14-4-2014-21-5-cs4208-codec-fixup-not-applied-for-this-ssid/32577>
* iMac16,2 speakers are on pins 0x1d/0x1e: <https://github.com/omacom/omarchy-pkgs/issues/510>
* 12" MacBook CS4208 driver + chime/amp finding: <https://github.com/leifliddy/macbook12-audio-driver>,
  <https://gist.github.com/jaderfeijo/9822c817665d075ca02c1beaa4e607df>
* Kernel docs on runtime pin overrides (`user_pin_configs`, `reconfig`, `patch=`):
  <https://docs.kernel.org/sound/hd-audio/notes.html>
