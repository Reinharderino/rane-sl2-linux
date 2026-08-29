#!/usr/bin/env bash
# Build and install an snd-usb-audio module carrying the Rane SL2 quirk.
#
# The quirk lives in the kernel's quirks table, so the whole module has to be
# rebuilt. To stay compatible with whatever kernel is running, the matching
# sound/usb sources are fetched from kernel.org at install time rather than
# shipped pinned to one version.
set -euo pipefail

PKG=snd-usb-audio-ranesl2
VER=1.0
SRC=/usr/src/$PKG-$VER
CGIT=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

KVER=$(uname -r)
TAG=""

usage() {
	cat <<EOF
uso: sudo ./install.sh [opciones]

  --kernel VER   compilar para esta version de kernel (por defecto: $(uname -r))
  --tag vX.Y.Z   tag de kernel.org del que bajar las fuentes
                 (por defecto se deduce de la version del kernel)
  -h, --help     esta ayuda
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--kernel) KVER=${2:?falta el valor}; shift 2 ;;
		--tag)    TAG=${2:?falta el valor};  shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "opcion desconocida: $1" >&2; usage; exit 2 ;;
	esac
done

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || die "hay que correrlo como root (sudo ./install.sh)"

step "Comprobando requisitos"
for t in curl make dkms python3; do
	command -v "$t" >/dev/null || die "falta '$t'. Instalalo y volve a intentar."
done
BUILD=/lib/modules/$KVER/build
[[ -d $BUILD ]] || die "no hay headers del kernel en $BUILD.
  Arch/CachyOS : sudo pacman -S linux-headers   (o linux-cachyos-headers, linux-lts-headers...)
  Debian/Ubuntu: sudo apt install linux-headers-$KVER
  Fedora       : sudo dnf install kernel-devel-$KVER"
echo "  kernel      : $KVER"
echo "  headers     : $BUILD"

# El kernel se compila con clang en varias distros (CachyOS entre ellas) y el
# modulo debe usar el mismo toolchain, o gcc rechaza los flags de clang.
LLVM_ARG=""
if grep -qi clang /proc/version 2>/dev/null; then
	command -v clang >/dev/null || die "el kernel fue compilado con clang pero clang no esta instalado"
	LLVM_ARG="LLVM=1"
	echo "  compilador  : clang (LLVM=1)"
else
	echo "  compilador  : gcc"
fi

if [[ -z $TAG ]]; then
	base=$(printf '%s' "$KVER" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?') \
		|| die "no pude deducir la version base de '$KVER'; pasala con --tag vX.Y.Z"
	TAG="v$base"
fi
echo "  fuentes de  : $TAG"

step "Bajando sound/usb de $TAG"
rm -rf "$SRC"; mkdir -p "$SRC"
listing=$(curl -fsSL --retry 3 "$CGIT/tree/sound/usb?h=$TAG") \
	|| die "no pude listar sound/usb de $TAG.
  Si tu kernel no corresponde a un tag publicado, pasa uno cercano con --tag."
mapfile -t files < <(printf '%s' "$listing" \
	| grep -oE "/tree/sound/usb/[A-Za-z0-9_.-]+\.(c|h)\?h=" \
	| sed 's|/tree/sound/usb/||; s|?h=||' | sort -u)
[[ ${#files[@]} -gt 10 ]] || die "el listado de sound/usb vino vacio o incompleto"

for f in "${files[@]}"; do
	curl -fsSL --retry 3 "$CGIT/plain/sound/usb/$f?h=$TAG" -o "$SRC/$f" \
		|| die "fallo la descarga de $f"
	[[ -s $SRC/$f ]] || die "$f vino vacio"
done
curl -fsSL --retry 3 "$CGIT/plain/sound/usb/Makefile?h=$TAG" -o "$SRC/Makefile.upstream" \
	|| die "fallo la descarga del Makefile"
echo "  ${#files[@]} archivos"

step "Aplicando el quirk del SL2"
python3 "$HERE/patch-sources.py" "$SRC"

step "Generando Makefile y dkms.conf"
# La lista de objetos cambia entre versiones (fcp.o es reciente), asi que se
# toma del Makefile original en vez de hardcodearla.
python3 - "$SRC/Makefile.upstream" "$SRC/Makefile" <<'PY'
import sys
up, out = sys.argv[1], sys.argv[2]
lines = open(up, encoding="utf-8").read().split("\n")
keep, i = [], 0
while i < len(lines):
    if lines[i].startswith("snd-usb-audio-"):
        block = [lines[i]]
        # las reglas se continuan con barra invertida al final de linea
        while block[-1].rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            block.append(lines[i])
        keep.append("\n".join(block))
    i += 1
if not keep:
    sys.exit("error: no encontre las reglas snd-usb-audio-y en el Makefile original")
open(out, "w", encoding="utf-8").write(
    "# Generado por install.sh: build fuera del arbol de snd-usb-audio\n"
    "# con la entrada del Rane SL2 en la tabla de quirks.\n\n"
    + "\n".join(keep)
    + "\n\nobj-m += snd-usb-audio.o\n\n"
      "KDIR ?= /lib/modules/$(shell uname -r)/build\n"
      "LLVM_ARG ?=\n\n"
      "all:\n\t$(MAKE) -C $(KDIR) M=$(CURDIR) $(LLVM_ARG) modules\n\n"
      "clean:\n\t$(MAKE) -C $(KDIR) M=$(CURDIR) $(LLVM_ARG) clean\n")
PY
rm -f "$SRC/Makefile.upstream"

cat > "$SRC/dkms.conf" <<EOF
PACKAGE_NAME="$PKG"
PACKAGE_VERSION="$VER"
MAKE[0]="make KDIR=/lib/modules/\${kernelver}/build LLVM_ARG=$LLVM_ARG"
BUILT_MODULE_NAME[0]="snd-usb-audio"
DEST_MODULE_LOCATION[0]="/updates"
AUTOINSTALL="yes"
EOF

step "Compilando e instalando con DKMS"
dkms remove -m "$PKG" -v "$VER" --all >/dev/null 2>&1 || true
dkms add -m "$PKG" -v "$VER"
dkms build -m "$PKG" -v "$VER" -k "$KVER"
dkms install -m "$PKG" -v "$VER" -k "$KVER" --force

step "Listo"
dkms status | grep "$PKG" || true
cat <<EOF

El modulo original quedo archivado; para volver atras:
    sudo ./uninstall.sh

Para que tome efecto sin reiniciar, con el SL2 desconectado:
    sudo modprobe -r snd_usb_audio && sudo modprobe snd_usb_audio
Si da "Module snd_usb_audio is in use", reinicia y listo.

Despues conecta el SL2 ANTES de encender la maquina: en caliente muchos
controladores xHCI no lo enumeran (ver README, seccion "El equipo no lo detecta").
EOF
