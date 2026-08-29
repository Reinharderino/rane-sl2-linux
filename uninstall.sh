#!/usr/bin/env bash
# Quitar el modulo parcheado y volver al snd-usb-audio original del kernel.
set -euo pipefail
PKG=snd-usb-audio-ranesl2
VER=1.0
[[ $EUID -eq 0 ]] || { echo "error: correlo como root (sudo ./uninstall.sh)" >&2; exit 1; }

dkms remove -m "$PKG" -v "$VER" --all || true
rm -rf "/usr/src/$PKG-$VER"
depmod -a
echo
echo "Listo. El snd-usb-audio original vuelve a estar activo."
echo "Recarga el modulo o reinicia para que tome efecto:"
echo "    sudo modprobe -r snd_usb_audio && sudo modprobe snd_usb_audio"
