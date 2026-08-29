#!/usr/bin/env python3
"""Insert the Rane SL2 quirk into a copy of the kernel's sound/usb sources.

Uses anchored insertion instead of a context diff so the same patch keeps
working across kernel versions, where line numbers and neighbouring entries
move around. Both edits are pure insertions: nothing existing is modified.
"""
import sys
import pathlib

VID_PID = "0x1cc5, 0x0013"

QUIRK_ENTRY = '''/*
 * Rane SL2 (Serato DVS interface).
 *
 * The class-specific descriptors are valid UAC2 and bInterfaceProtocol is
 * UAC_VERSION_2, but the interface class is reported as vendor specific and
 * the interface association descriptor is missing, so the standard probe path
 * bails out with "Audio class v2/v3 interfaces need an interface association".
 *
 * The device answers neither UAC2_CS_RANGE nor UAC2_CS_CUR for the sample
 * frequency control (it stalls both), so the rate can neither be discovered
 * nor set. The hardware runs at a fixed 44.1 kHz, measured two ways: the
 * 1 kHz Serato timecode reference reads back at 1087 Hz when the stream is
 * declared as 48 kHz (ratio 1.087), and a timed 10 s capture takes 10.9 s of
 * wall clock (44038 Hz). It is declared here as a single fixed rate and
 * paired with QUIRK_FLAG_FIXED_RATE so that the endpoint setup skips the
 * clock request that would otherwise fail and abort hw_params.
 *
 * Format is 4 channels of 24 bits carried in 4 byte subslots.
 *
 * Interface 3 is HID and is left to usbhid by matching only the vendor
 * specific interfaces.
 */
{
\tUSB_DEVICE_VENDOR_SPEC(0x1cc5, 0x0013),
\tQUIRK_DRIVER_INFO {
\t\tQUIRK_DATA_COMPOSITE {
\t\t\t{ QUIRK_DATA_STANDARD_MIXER(0) },
\t\t\t{
\t\t\t\tQUIRK_DATA_AUDIOFORMAT(1) {
\t\t\t\t\t.formats = SNDRV_PCM_FMTBIT_S32_LE,
\t\t\t\t\t.channels = 4,
\t\t\t\t\t.fmt_bits = 24,
\t\t\t\t\t.iface = 1,
\t\t\t\t\t.altsetting = 1,
\t\t\t\t\t.altset_idx = 1,
\t\t\t\t\t.endpoint = 0x06,
\t\t\t\t\t.ep_attr = USB_ENDPOINT_XFER_ISOC |
\t\t\t\t\t\t   USB_ENDPOINT_SYNC_ASYNC,
\t\t\t\t\t.clock = 5,
\t\t\t\t\t.rates = SNDRV_PCM_RATE_44100,
\t\t\t\t\t.rate_min = 44100,
\t\t\t\t\t.rate_max = 44100,
\t\t\t\t\t.nr_rates = 1,
\t\t\t\t\t.rate_table = (unsigned int[]) { 44100 },
\t\t\t\t},
\t\t\t},
\t\t\t{
\t\t\t\tQUIRK_DATA_AUDIOFORMAT(2) {
\t\t\t\t\t.formats = SNDRV_PCM_FMTBIT_S32_LE,
\t\t\t\t\t.channels = 4,
\t\t\t\t\t.fmt_bits = 24,
\t\t\t\t\t.iface = 2,
\t\t\t\t\t.altsetting = 1,
\t\t\t\t\t.altset_idx = 1,
\t\t\t\t\t.endpoint = 0x82,
\t\t\t\t\t.ep_attr = USB_ENDPOINT_XFER_ISOC |
\t\t\t\t\t\t   USB_ENDPOINT_SYNC_ASYNC |
\t\t\t\t\t\t   USB_ENDPOINT_USAGE_IMPLICIT_FB,
\t\t\t\t\t.clock = 5,
\t\t\t\t\t.rates = SNDRV_PCM_RATE_44100,
\t\t\t\t\t.rate_min = 44100,
\t\t\t\t\t.rate_max = 44100,
\t\t\t\t\t.nr_rates = 1,
\t\t\t\t\t.rate_table = (unsigned int[]) { 44100 },
\t\t\t\t},
\t\t\t},
\t\t\tQUIRK_COMPOSITE_END
\t\t}
\t}
},
'''.replace('\\t', '\t')

FLAG_ENTRY = (
    "\tDEVICE_FLG(0x1cc5, 0x0013, /* Rane SL2 */\n"
    "\t\t   QUIRK_FLAG_FIXED_RATE),\n"
)


def fail(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def insert_before(path, anchor, block, what):
    text = path.read_text(encoding="utf-8")
    if VID_PID in text:
        print(f"  {path.name}: ya contiene la entrada, sin cambios")
        return
    lines = text.split("\n")
    hits = [i for i, l in enumerate(lines) if l.startswith(anchor)]
    if not hits:
        fail(f"no se encontro el ancla {anchor!r} en {path}. "
             "Puede que la estructura del kernel haya cambiado.")
    lines[hits[0]:hits[0]] = block.split("\n") + [""]
    path.write_text("\n".join(lines), encoding="utf-8")
    print(f"  {path.name}: {what} insertado")


def insert_after(path, anchor, block, what):
    text = path.read_text(encoding="utf-8")
    if VID_PID in text:
        print(f"  {path.name}: ya contiene la entrada, sin cambios")
        return
    idx = text.find(anchor)
    if idx < 0:
        fail(f"no se encontro el ancla {anchor!r} en {path}. "
             "Puede que la estructura del kernel haya cambiado.")
    cut = idx + len(anchor)
    path.write_text(text[:cut] + "\n" + block.rstrip("\n") + text[cut:],
                    encoding="utf-8")
    print(f"  {path.name}: {what} insertado")


def main():
    if len(sys.argv) != 2:
        print(f"uso: {sys.argv[0]} <directorio-con-sound-usb>", file=sys.stderr)
        sys.exit(2)
    d = pathlib.Path(sys.argv[1])
    qt, qc = d / "quirks-table.h", d / "quirks.c"
    for f in (qt, qc):
        if not f.is_file():
            fail(f"falta {f}")

    # El #undef cierra la tabla; ha estado ahi durante muchas versiones.
    insert_before(qt, "#undef USB_DEVICE_VENDOR_SPEC", QUIRK_ENTRY,
                  "entrada de quirk")
    # La tabla de flags se recorre linealmente y devuelve al primer match,
    # asi que insertar al principio es seguro y no depende del orden por vendor.
    insert_after(qc, "static const struct usb_audio_quirk_flags_table quirk_flags_table[] = {",
                 FLAG_ENTRY, "QUIRK_FLAG_FIXED_RATE")


if __name__ == "__main__":
    main()
