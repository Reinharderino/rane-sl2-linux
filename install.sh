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
usage: sudo ./install.sh [options]

  --kernel VER   build for this kernel version (default: $(uname -r))
  --tag vX.Y.Z   kernel.org tag to download the sources from
                 (default: derived from the kernel version; any version
                 from the same X.Y series works)
  -h, --help     this help
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--kernel) KVER=${2:?missing value}; shift 2 ;;
		--tag)    TAG=${2:?missing value};  shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "unknown option: $1" >&2; usage; exit 2 ;;
	esac
done

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || die "it must be run as root (sudo ./install.sh)"

step "Checking requirements"
for t in curl make dkms python3; do
	command -v "$t" >/dev/null || die "'$t' is missing. Install it and try again."
done
BUILD=/lib/modules/$KVER/build
[[ -d $BUILD ]] || die "no kernel headers in $BUILD.
  Arch/CachyOS : sudo pacman -S linux-headers   (or linux-cachyos-headers, linux-lts-headers...)
  Debian/Ubuntu: sudo apt install linux-headers-$KVER
  Fedora       : sudo dnf install kernel-devel-$KVER"
echo "  kernel      : $KVER"
echo "  headers     : $BUILD"

# Several distros (CachyOS among them) build the kernel with clang, and the
# module must use the same toolchain, or gcc rejects clang's flags. It's read
# from the headers' .config, which every distro ships, and not from
# /proc/version: that's the running kernel, not necessarily the --kernel one.
# The generated Makefile repeats the check on every build, because DKMS also
# rebuilds for other installed kernels that may use a different compiler.
if grep -qs '^CONFIG_CC_IS_CLANG=y' "$BUILD/.config"; then
	command -v clang >/dev/null || die "the kernel was built with clang but clang is not installed"
	echo "  compiler    : clang (LLVM=1)"
else
	echo "  compiler    : gcc"
fi

# kernel.org tags .0 releases as vX.Y, NOT vX.Y.0, while several distros
# (Ubuntu, Debian) name that same kernel 7.0.0-14-generic. So deriving one tag
# isn't enough: the candidates are tried against cgit and the first one that
# actually exists wins.
if [[ -n $TAG ]]; then
	[[ $TAG == v* ]] || TAG="v$TAG"   # accept "7.0" as well as "v7.0"
	candidates=("$TAG")
else
	base=$(printf '%s' "$KVER" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?') \
		|| die "could not derive the base version of '$KVER'; pass it with --tag vX.Y.Z"
	candidates=("v$base")
	[[ $base == *.0 ]] && candidates+=("v${base%.0}")
fi

step "Downloading sound/usb"
rm -rf "$SRC"; mkdir -p "$SRC"
listing=""
for TAG in "${candidates[@]}"; do
	echo "  trying tag $TAG"
	listing=$(curl -fsL --retry 3 "$CGIT/tree/sound/usb?h=$TAG") && break
	listing=""
done
[[ -n $listing ]] || die "no kernel.org tag matches (tried: ${candidates[*]}).
  Find the closest one at
    https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/refs/tags
  and pass it with --tag. Any version from the same X.Y series works."
echo "  sources     : $TAG"
# The sources only build against kernels of their own X.Y series: ALSA's
# internal API changes between series. DKMS is limited to that series so it
# doesn't fail on every kernel from another one (an older -lts installed
# alongside, for example).
SERIES=$(printf '%s' "${TAG#v}" | grep -oE '^[0-9]+\.[0-9]+')
SERIES_RE="^${SERIES//./\\.}([.-]|\$)"
[[ $KVER =~ $SERIES_RE ]] || echo "  warning: tag $TAG is not from the $KVER series; DKMS will not build it for that kernel"
mapfile -t files < <(printf '%s' "$listing" \
	| grep -oE "/tree/sound/usb/[A-Za-z0-9_.-]+\.(c|h)\?h=" \
	| sed 's|/tree/sound/usb/||; s|?h=||' | sort -u)
[[ ${#files[@]} -gt 10 ]] || die "the sound/usb listing came back empty or incomplete"

for f in "${files[@]}"; do
	curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "$CGIT/plain/sound/usb/$f?h=$TAG" -o "$SRC/$f" \
		|| die "download of $f failed"
	[[ -s $SRC/$f ]] || die "$f came back empty"
done
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "$CGIT/plain/sound/usb/Makefile?h=$TAG" -o "$SRC/Makefile.upstream" \
	|| die "download of the Makefile failed"
echo "  ${#files[@]} files"

step "Applying the SL2 quirk"
python3 "$HERE/patch-sources.py" "$SRC"

step "Generating Makefile and dkms.conf"
# The object list changes between versions (fcp.o is recent), so it's taken
# from the original Makefile instead of being hardcoded.
python3 - "$SRC/Makefile.upstream" "$SRC/Makefile" <<'PY'
import sys
up, out = sys.argv[1], sys.argv[2]
lines = open(up, encoding="utf-8").read().split("\n")
keep, i = [], 0
while i < len(lines):
    if lines[i].startswith("snd-usb-audio-"):
        block = [lines[i]]
        # rules continue with a trailing backslash
        while block[-1].rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            block.append(lines[i])
        keep.append("\n".join(block))
    i += 1
if not keep:
    sys.exit("error: snd-usb-audio-y rules not found in the original Makefile")
open(out, "w", encoding="utf-8").write(
    "# Generated by install.sh: out-of-tree build of snd-usb-audio\n"
    "# with the Rane SL2 entry in the quirks table.\n\n"
    + "\n".join(keep)
    + "\n\nobj-m += snd-usb-audio.o\n\n"
      "KDIR ?= /lib/modules/$(shell uname -r)/build\n"
      "# same compiler as the target kernel, decided per build\n"
      "LLVM_ARG ?= $(if $(shell grep -s '^CONFIG_CC_IS_CLANG=y' $(KDIR)/.config),LLVM=1)\n\n"
      "all:\n\t$(MAKE) -C $(KDIR) M=$(CURDIR) $(LLVM_ARG) modules\n\n"
      "clean:\n\t$(MAKE) -C $(KDIR) M=$(CURDIR) $(LLVM_ARG) clean\n")
PY
rm -f "$SRC/Makefile.upstream"

cat > "$SRC/dkms.conf" <<EOF
PACKAGE_NAME="$PKG"
PACKAGE_VERSION="$VER"
MAKE[0]="make KDIR=/lib/modules/\${kernelver}/build"
BUILT_MODULE_NAME[0]="snd-usb-audio"
DEST_MODULE_LOCATION[0]="/updates"
AUTOINSTALL="yes"
BUILD_EXCLUSIVE_KERNEL="$SERIES_RE"
EOF

step "Building and installing with DKMS"
dkms remove -m "$PKG" -v "$VER" --all >/dev/null 2>&1 || true
dkms add -m "$PKG" -v "$VER"
dkms build -m "$PKG" -v "$VER" -k "$KVER"
dkms install -m "$PKG" -v "$VER" -k "$KVER" --force

step "Done"
dkms status | grep "$PKG" || true
cat <<EOF

The original module was archived; to roll back:
    sudo ./uninstall.sh

To make it take effect without rebooting, with the SL2 disconnected:
    sudo modprobe -r snd_usb_audio && sudo modprobe snd_usb_audio
If it says "Module snd_usb_audio is in use", reboot and you're done.

Then connect the SL2 BEFORE turning on the machine: many xHCI controllers
fail to enumerate it when hot-plugged (see README, section "The computer
doesn't detect it").
EOF
