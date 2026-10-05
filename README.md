# Rane SL2 on Linux

Native support for the **Rane SL2** DVS interface (`1cc5:0013`) on Linux, for
use with [Mixxx](https://mixxx.org) or any other software that speaks ALSA.

The SL2 came out in 2009, Serato discontinued it, and its drivers don't work on
modern macOS nor comfortably on Windows 10/11. The hardware is perfectly fine:
four 24-bit inputs and four outputs with phono preamps. This brings it back to
life.

## What this actually is

**It's not a new driver.** Looking at the device's USB descriptors, it turns
out the SL2 is already an almost textbook **USB Audio Class 2.0** device: its
class descriptors are valid and it declares `bInterfaceProtocol =
UAC_VERSION_2`. It has only two quirks that make the kernel reject it:

1. It reports a *vendor specific* interface class (`0xFF`) instead of audio.
2. It lacks the *interface association descriptor*, so the kernel bails out
   with `Audio class v2/v3 interfaces need an interface association`.

On top of that it doesn't answer the standard sample rate requests (it rejects
them with a *stall*), so the rate can't be discovered or set: it always runs at
**44100 Hz**.

All of this is solved with one entry in the ALSA quirks table. It's about
seventy lines. The rest of this repository is the scaffolding to build it for
any kernel, plus a diagnostic tool for the hardware.

## Installation

Requirements: your kernel's headers, `dkms`, `curl`, `make`, `python3` and
`alsa-utils`.

```bash
git clone <this-repo> && cd rane-sl2-linux
sudo ./install.sh
```

The installer detects your kernel, **downloads from kernel.org the `sound/usb`
sources matching that version**, applies the quirk and builds the module with
DKMS. Only that directory is downloaded, roughly 1.4 MB, not the full kernel
tarball.

DKMS rebuilds it automatically on every kernel update **within the same X.Y
series** (from 7.2.8 to 7.2.9, for example). The downloaded sources don't
build against another series, because ALSA's internal API changes, so DKMS
skips those kernels instead of failing: an older `-lts` installed alongside
won't break your updates. When you move to a new series (7.2 → 7.3), run
`sudo ./install.sh` again; until then that kernel uses the stock
`snd-usb-audio`, without the quirk.

To roll back at any time:

```bash
sudo ./uninstall.sh
```

DKMS archives the original `snd-usb-audio` and restores it untouched.

### If it can't find your kernel's sources

Debian-based distros name the kernel `7.0.0-14-generic` even though kernel.org
tags that release as **`v7.0`**, without the third number: `vX.Y.0` tags don't
exist. The installer already tries both forms, so this should sort itself out.

If no tag matches anyway (development kernel, `-rc`, or patched by the
distro), pass one by hand. **Any version from the same X.Y series works**, it
doesn't need to be the exact one:

```bash
sudo ./install.sh --tag v7.0
```

Published tags are at
<https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/refs/tags>.

### If 503 errors show up during the download

```
curl: (22) The requested URL returned error: 503
```

That's git.kernel.org rate limiting, not a failure. `curl` retries and moves
on; if a file truly fails to download, the installer aborts right there. As
long as the step ends with the file count (`46 files`, around 40 depending
on the version), the download is complete.

### If your distro builds the kernel with clang

CachyOS and a few others do. The module is built with the same compiler as its
kernel: the Makefile reads `CONFIG_CC_IS_CLANG` from the headers' `.config` on
every build and adds `LLVM=1` when needed. It doesn't depend on the distro,
and it works even with kernels of both kinds installed (on CachyOS,
`linux-cachyos` uses clang while `linux-zen`/`linux-lts` use gcc). With the
wrong compiler the build fails with
`unrecognized command-line option '-mstack-alignment=8'` or
`clang: error: unknown argument`.

### Secure Boot

DKMS signs the module with your MOK key if you have one set up. If you use
Secure Boot and the module doesn't load, you need to enroll that key
(`mokutil --import`).

## The computer doesn't detect it

**Plug in the SL2 before turning on the machine.**

Many xHCI controllers fail to enumerate it when hot-plugged. The symptom is the
LED blinking five times and turning off, and in `dmesg`:

```
usb 1-6: device descriptor read/64, error -110
usb usb1-port6: unable to enumerate USB device
```

It's not a broken unit or a bad cable: the SL2 takes longer to wake up than
the host is willing to wait before giving up. Connected from boot, it always
enumerates on the first try.

Unplugging it never causes problems. It's the way back that fails.

### Plugging it in with the machine running

It can be done, just not by brute force. Plug in the SL2, wait about ten
seconds for it to finish waking up, and force a port reset:

```bash
sudo ./sl2-hotplug-reset
```

The script picks the port out of `dmesg`, resets it and waits for the device to
show up. If you already know the port, pass it by hand:

```bash
sudo ./sl2-hotplug-reset 1-6
```

Manually it's the same pair of writes, adjusting the path to your port:

```bash
P=/sys/bus/usb/devices/usb1/1-0:1.0/usb1-port6
echo 1 | sudo tee $P/disable >/dev/null
echo 0 | sudo tee $P/disable >/dev/null
```

To confirm it enumerated: `lsusb | grep 1cc5`.

Two known limits here: it's measured on a single unit in a single machine, so
we don't know whether every SL2 has the same boot time, and suspend/resume
hasn't been tested. If yours behaves differently in either case, open an
issue: that's useful data.

## Wiring

| Item | Setting |
|---|---|
| Turntable | **PHONO** |
| Rane input | **PHONO** |
| Mixer channel | **LINE** |
| RCA cables | straight: left to left |

The SL2 puts out **line level**; if you set the mixer channel to phono you add
another 40 dB preamp and it clips.

If your turntable has a built-in preamp and you leave it on LINE, then the
Rane input goes on **CD**, not PHONO. What must not happen is mixing both
approaches: two preamps in a chain clip, and none leaves the signal 40 dB low.

## Keep PipeWire off the device

PipeWire grabs the SL2 as just another sound card, while Mixxx opens it as raw
ALSA. Two owners for the same device. It usually looks like it works, because
PipeWire suspends idle nodes and releases the card, until something routes
audio there in the middle of a set.

Since you'll use the SL2 only from Mixxx through ALSA, the cleanest option is
to have WirePlumber ignore it. Find the device identifier:

```bash
wpctl status | grep -i 'Rane SL 2'
wpctl inspect <device id> | grep device.name
```

And with that exact value, create
`~/.config/wireplumber/wireplumber.conf.d/51-rane-sl2.conf`:

```
monitor.alsa.rules = [
  {
    matches = [{ device.name = "alsa_card.usb-Rane_Corporation_Rane_SL_2_SL2.01.00-00" }]
    actions = {
      update-props = {
        device.disabled = true
      }
    }
  }
]
```

```bash
systemctl --user restart wireplumber
```

After that the SL2 no longer shows up in `wpctl status`: no device, sink or
source. Mixxx keeps opening it as before, because it never went through
PipeWire. To roll back, delete the file and restart wireplumber.

That's exactly the intended effect: the SL2 stops existing for system audio.
No browser or notification can land on it.

## Mixxx configuration

In **Preferences → Sound Hardware**:

- Sound API: **ALSA**
- Sample rate: **44100 Hz** — mandatory. With any other rate the device won't
  open, because the driver declares 44100 and nothing else.
- Audio buffer: start at 21 ms and go down later

Outputs, with an **external mixer** (the usual setup with an SL2):

- `Deck 1` → Rane SL 2, channels **1-2**
- `Deck 2` → Rane SL 2, channels **3-4**
- `Main`, `Headphones` and `Booth` unassigned

The mixer does the mixing and the headphone cue. Leave Mixxx's faders and EQ
in neutral position: the deck outputs are post-fader, otherwise you'll be
fighting two controls for the same thing.

Without an external mixer, set `Main` to SL2 channels 1-2. Don't mix the SL2
with `default` (PipeWire): they're two different clocks and you'll get
dropouts.

Under **Vinyl Control**:

- Vinyl type: **Serato CV02 Vinyl**
- Turntable input signal boost: **0 dB**. If you need to raise it a lot, the
  problem is in the wiring, not here.
- `Vinyl Control 1` → channels 1-2, `Vinyl Control 2` → channels 3-4

## Diagnostics

If something's wrong, close Mixxx, leave the needle down with the record
spinning and run:

```bash
./sl2-signal-check
```

It measures level, clipping, reference tone frequency and phase between
channels, and tells you what to adjust. A healthy signal looks like this:

```
Levels
  CH1: peak  -19.9 dBFS   rms  -24.7 dBFS
  CH2: peak  -21.5 dBFS   rms  -26.5 dBFS

Reference tone  (Serato CV02 = 1000 Hz)
  CH1:   998.6 Hz     CH2:   998.6 Hz

Quadrature  (both channels must be 90 degrees apart)
  phase CH1-CH2: +91.2 degrees   correct
```

## Symptoms and causes

These cover almost everything, and they're hard to tell apart by eye:

| Symptom | Actual cause |
|---|---|
| Clean circle but the track doesn't move | **Clipping.** The reference tone survives saturation and keeps drawing the circle, but the position data is modulated in fine amplitude details and gets destroyed. Lower the gain. |
| The track plays in reverse | Swapped channels, or a signal so poor the direction can't be resolved. Before crossing cables, check the PHONO switches. |
| The track skips | Clock mismatch. If the reference tone reads ~1087 Hz instead of 1000, the driver is declaring 48000 while the hardware runs at 44100: the module with the quirk isn't active. |
| Only low rumble, almost no level | Turntable on LINE with the Rane on PHONO, or the needle lifted. |
| The output carries the timecode instead of the music | The SL2 passes the input through to the output as long as no playback stream is open: the ADC and the thru depend on the output side running. If in Mixxx you only assigned the vinyl control inputs and left `Deck 1` and `Deck 2` unassigned, the device never leaves that mode. Assign the outputs (channels 1-2 and 3-4) and check that the deck's **PASS** button is off. |

## Technical details

Device descriptors:

| Interface | Class | Endpoints | Role |
|---|---|---|---|
| 0 | `0xFF` sub 1 | none | control (`SL 2 Audio`) |
| 1 alt 1 | `0xFF` sub 2 | `0x06` OUT isoc, 112 B | playback |
| 2 alt 1 | `0xFF` sub 2 | `0x82` IN isoc, 112 B | capture |
| 3 | HID | `0x81` IN / `0x01` OUT interrupt | control and MIDI |

Format: 4 channels, 24 bits in 4-byte subslots, fixed 44100 Hz, `S32_LE` on
the ALSA side. The quirk uses `USB_DEVICE_VENDOR_SPEC` to match only the
`0xFF` interfaces, so the HID interface stays with `usbhid` and isn't claimed
by the audio driver.

A detail that surprises people when testing: **the ADC only delivers data
while the output stream is active**, because the input endpoint is the
implicit feedback source for the output one. If you record with `arecord`
alone, you get exact digital zeros. You have to play something in parallel —
which is what `sl2-signal-check` does.

PID `0x0014` is the variant claimed by Serato Scratch Live; `0x0013` is the
generic ASIO mode, which is the one this quirk supports. If you have a unit
that shows up as `0014`, open an issue: its descriptors need to be captured.

## License

The quirk is inserted into Linux kernel sources and follows its license,
**GPL-2.0**. The scripts in this repository, likewise.

## Data provenance

Everything in the quirk comes from the **descriptors the device itself
publishes** (`doc/lsusb-sl2.txt`, output of `lsusb -v`) or from measurements on
the signal. The 44100 Hz rate, for example, was determined by measuring: the
1 kHz reference tone read 1087 Hz when declaring 48000, and a timed 10 s
capture took 10.9 s of wall-clock time.

Rane's Windows and macOS drivers were consulted to understand the device's
architecture — they turn out to be thin wrappers over the endpoints, with all
the logic in user space — but **no value in the quirk comes from
disassembling them**, and those binaries are not redistributed here because
they're proprietary to Rane/inMusic and Serato.

If you want to inspect them yourself, they're inside the **Serato Scratch Live
2.5** installer (free download with a free account at serato.com, in the
legacy versions archive). The drivers end up in `Serato/Drivers/<OS>/SL2/`,
and the ASIO package opens with `innoextract`.

## Other models in the family

The **SL3** and **SL4** are from the same generation and very likely share the
same structure: vendor specific interfaces with valid UAC2 descriptors and no
IAD. Adapting the quirk would be a matter of changing the PID and adjusting
endpoints and channel count.

If you have one, open an issue with the output of `lsusb -v -d 1cc5:XXXX` and
the result of measuring the actual sample rate. Known PIDs in the family, taken
from Serato's INF files:

| Model | USB ID |
|---|---|
| Rane SL 1 | `13e5:0001` |
| Rane MP 4 | `13e5:0002` |
| Rane TTM 57SL | `13e5:8003` |
| Rane SL 3 | `1cc5:0003` |
| Rane Sixty-Eight | `1cc5:0005` |
| Rane Sixty Two | `1cc5:000a` |
| Rane SL 4 | `1cc5:0010` |
| Rane Sixty One | `1cc5:0012` |
| **Rane SL 2 (ASIO mode)** | **`1cc5:0013`** |
| Rane SL 2 (Scratch Live mode) | `1cc5:0014` |

## Upstream submission

`patch/` holds the same quirk as a Linux kernel patch, ready to send to the
mailing list. It passes `checkpatch.pl --strict` with no remarks.

If it ends up accepted upstream, this repository is no longer needed: support
ships with every distribution's kernel.
