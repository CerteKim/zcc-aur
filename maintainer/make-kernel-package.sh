#!/bin/bash
# Build a pacman-installable kernel package from a tree that is already built.
#
#   ./maintainer/make-kernel-package.sh <pkgrel> [kernel-build-dir]
#
# The tree is assumed to be built (`make all modules`) with
# localversion.10-pkgrel / localversion.20-pkgname present, so that
# `make kernelrelease` gives the version the package should own.
#
# Why not makepkg: PKGBUILD builds from a git source and this repository's
# mirror is 3.3 GB, so a source build costs another full copy of the tree.
# This script packages the build that is already there instead, using the
# same layout the PKGBUILD produces (/usr/lib/modules/<ver>/... and
# /boot/dtb/linux-mibook/qcom/...), plus a real .PKGINFO so pacman accepts it.
#
# This is zcc-aur's release path: the package is written straight into repo/
# (gitignored), and ./scripts/build.sh --db registers it there.
set -euo pipefail

PKGREL="${1:?usage: $0 <pkgrel> [kernel-build-dir]}"
KSRC="${2:-/home/certe/aarch64-packages/linux-surface/src/kernel}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KVER="$(make -s -C "$KSRC" ARCH=arm64 kernelrelease)"
STAGE="$(mktemp -d /home/certe/pkgstage-XXXXXX)/linux-mibook"
M="$STAGE/usr/lib/modules/${KVER}"
mkdir -p "$REPO/repo"
PKG="$REPO/repo/linux-mibook-6.18.2-1-${PKGREL}-aarch64.pkg.tar.zst"
DTB="sc8180x-xiaomi-book-12.4.dtb"

echo "==> kernel release: ${KVER}"
[ -f "$KSRC/vmlinux" ] || { echo "!! no vmlinux in $KSRC - build first"; exit 1; }
[ -f "$KSRC/arch/arm64/boot/Image" ] || { echo "!! no Image built"; exit 1; }

echo "==> staging modules listed in modules.order"
mkdir -p "$M/kernel"
python3 - "$KSRC" "$M" <<'PYEOF'
import os, shutil, sys
K, M = sys.argv[1], sys.argv[2]
n = missing = 0
for line in open(os.path.join(K, 'modules.order')):
    line = line.strip()
    if not line.endswith('.o'):
        continue
    ko = line[:-2] + '.ko'
    src = os.path.join(K, ko)
    if not os.path.exists(src):
        missing += 1
        continue
    dst = os.path.join(M, 'kernel', ko)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    n += 1
print(f"    {n} modules, {missing} missing")
PYEOF

echo "==> stripping debug info"
find "$M/kernel" -name "*.ko" -print0 | xargs -0 -r -n 8 strip --strip-debug

echo "==> kernel image (gzip), metadata and DTBs"
# The kernel image goes into the package *and* to /boot.  Shipping it matters:
# "pacman -U" without it replaces every module while /boot keeps the previous
# kernel, which leaves modules and kernel from different builds (the kernel
# then rejects each module's BTF and services that depend on those modules
# fail).  gzip keeps the package small; GRUB and mkinitcpio both handle it.
install -Dm644 "$KSRC/System.map" "$M/System.map"
install -Dm644 "$KSRC/.config" "$M/config"
install -Dm644 "$KSRC/modules.order" "$M/modules.order"
install -Dm644 "$KSRC/modules.builtin" "$M/modules.builtin"
[ -f "$KSRC/modules.builtin.modinfo" ] && install -Dm644 "$KSRC/modules.builtin.modinfo" "$M/modules.builtin.modinfo"
echo -n linux-mibook > "$M/pkgbase"
gzip -9 -c "$KSRC/arch/arm64/boot/Image" > "$M/vmlinuz"
install -Dm644 "$M/vmlinuz" "$STAGE/boot/vmlinuz-linux-mibook"

install -Dm644 "$KSRC/arch/arm64/boot/dts/qcom/$DTB" "$M/dtb/qcom/$DTB"
BDTB="$STAGE/boot/dtb/linux-mibook/qcom"
mkdir -p "$BDTB"
# The package ships the tree's DTB under both paths GRUB references.  The tree
# keeps the video node disabled and nothing here re-enables it: the VPU probe
# road is closed (linux-surface's HARDWARE-STATUS.md records how far it got).
cp "$M/dtb/qcom/$DTB" "$BDTB/$DTB"
cp "$M/dtb/qcom/$DTB" "$BDTB/$(basename "$DTB" .dtb)-oc.dtb"

echo "==> mkinitcpio preset and .INSTALL"
# The preset must be shipped: it used to be owned by the previous package, so a
# package that omits it makes pacman delete it, and then "mkinitcpio -P" fails
# with "No presets found in /etc/mkinitcpio.d" and /boot keeps a stale
# initramfs built from another kernel's modules.
sed "s|%PKGBASE%|linux-mibook|g" "$REPO/packages/linux-mibook/linux-mibook.preset" \
    | install -Dm644 /dev/stdin "$STAGE/etc/mkinitcpio.d/linux-mibook.preset"

cat > "$STAGE/.INSTALL" <<'EOF'
build_initramfs() {
    if ! command -v mkinitcpio >/dev/null; then
        echo "mkinitcpio not installed - skipping initramfs rebuild"
        return 0
    fi
    if ls /etc/mkinitcpio.d/*.preset >/dev/null 2>&1; then
        mkinitcpio -P && return 0
        echo "mkinitcpio -P failed, falling back to an explicit build"
    fi
    mkinitcpio -k /boot/vmlinuz-linux-mibook -g /boot/initramfs-linux-mibook.img
}
post_install() {
    depmod "$1" 2>/dev/null || true
    build_initramfs
    amp_variant_note
}
post_upgrade() {
    post_install "$@"
}
amp_variant_note() {
    cat <<'NOTE'

    note: this package ships the tree's snd-soc-wsa881x.ko (the "gain" build).
          Installing it overwrites any amplifier variant selected with
          install-amp-variant.sh, and that difference is audible
          (pops / an amplifier left powered with no stream).  Re-apply the
          variant you want now:
              sudo audio-fix-install.sh         # stock driver
              sudo install-amp-variant.sh h1a   # never power-cycle
NOTE
}
EOF

echo "==> depmod"
ln -sfn usr/lib "$STAGE/lib"
depmod -b "$STAGE" "$KVER"
rm -f "$STAGE/lib"

echo "==> .PKGINFO"
SIZE=$(du -sb "$STAGE" | cut -f1)
cat > "$STAGE/.PKGINFO" <<EOF
pkgname = linux-mibook
pkgbase = linux-mibook
pkgver = 6.18.2-1
pkgdesc = Linux Xiaomi Book S 12.4 kernel and modules
url = https://github.com/CerteKim/linux-a51
builddate = $(date +%s)
packager = Certe Kim <18364439+CerteKim@users.noreply.github.com>
size = ${SIZE}
arch = aarch64
license = GPL-2.0-only
depend = coreutils
depend = kmod
depend = mkinitcpio>=0.7
depend = linux-firmware
optdepend = crda: to set the correct wireless channels of your country
EOF

echo "==> packaging"
# --uid/--gid 0: the staging tree is owned by the build user, and a package that
# records uid 1000 would install kernel modules owned by a non-root user (which
# that user could then modify and have root load) and makes pacman warn about
# every /boot file.
( cd "$STAGE" && bsdtar --zstd --uid 0 --gid 0 --uname root --gname root \
    -cf "$PKG" .PKGINFO .INSTALL boot etc usr )
rm -rf "${STAGE%/linux-mibook}"
echo
ls -la "$PKG"
pacman -Qp "$PKG"
echo
echo "install with:  sudo pacman -U $PKG"
echo "the package ships /boot/vmlinuz-linux-mibook and the DTBs"
echo "register it in the release repo with:  ./scripts/build.sh --db"
