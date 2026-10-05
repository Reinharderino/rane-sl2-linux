#!/usr/bin/env bash
# Remove the patched module and go back to the kernel's original snd-usb-audio.
set -euo pipefail
PKG=snd-usb-audio-ranesl2
VER=1.0
[[ $EUID -eq 0 ]] || { echo "error: run it as root (sudo ./uninstall.sh)" >&2; exit 1; }

dkms remove -m "$PKG" -v "$VER" --all || true
rm -rf "/usr/src/$PKG-$VER"
depmod -a
echo
echo "Done. The original snd-usb-audio is active again."
echo "Reload the module or reboot for it to take effect:"
echo "    sudo modprobe -r snd_usb_audio && sudo modprobe snd_usb_audio"
