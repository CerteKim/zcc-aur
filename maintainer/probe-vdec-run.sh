#!/bin/bash
# Arm and run the Iris/VPU probe on the Xiaomi Book S 12.4 (SC8180X).
#
#   sudo bash /home/certe/aarch64-packages/linux-surface/tools/probe-vdec-run.sh [pkgrel]
#
# The order matters, and it is the lesson from the failed -6 attempt:
#   1. save the current known-good /boot files as the fallback set
#   2. install the VPU firmware
#   3. blacklist qcom-iris *before* the initramfs is rebuilt, so nothing
#      autoloads at boot.  A plain "blacklist" still allows an explicit
#      "modprobe qcom-iris", which is how the probe is started.
#   4. install the kernel package: it now carries /boot/vmlinuz-linux-mibook,
#      both DTBs and a .INSTALL that rebuilds the initramfs, so kernel and
#      modules can no longer come from different builds.  The DTBs it ships
#      are the *parked* ones (VPU node disabled).
#   5. swap in the probe DTB (VPU node enabled) on both GRUB paths
#   6. verify everything, and only then tell you to reboot.  Any mismatch stops
#      the script before the reboot.
#
# If the probe wedges the machine: power-cycle.  The module is blacklisted, so
# it comes back up and does not probe; then run tools/recover-working.sh.
#
# The script is idempotent: re-running it just re-saves the fallback and, if the
# installed kernel already matches this tree, skips the package install.
set -eu
# Without this, a failure anywhere above only aborts silently and prints nothing
# useful (which is how the first run stopped right after step 1).
trap 'rc=$?; echo "!! probe-vdec-run.sh FAILED at line $LINENO (exit $rc)"; echo "   nothing was changed past that point; re-run to retry"; exit $rc' ERR
# Distinguish "the script broke" from "the run was interrupted" (Ctrl-C, closed
# terminal, sudo timeout): the first -9 run stopped after step 1 with no message,
# which is what an interruption from outside looks like.
trap 'echo "!! probe-vdec-run.sh INTERRUPTED (Ctrl-C / killed) - nothing past this point was changed"; exit 130' INT TERM

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="$REPO/src/kernel"
KVER="$(make -s -C "$K" ARCH=arm64 kernelrelease)"
PKGREL="${1:-9}"
PKG="$REPO/linux-mibook-6.18.2-1-${PKGREL}-aarch64.pkg.tar.zst"
FW="$REPO/firmware/qcom/sc8180x/venus.mbn"
FALLBACK=/home/certe/vdec-poc-fallback
DTB=sc8180x-xiaomi-book-12.4
BDTB=/boot/dtb/linux-mibook/qcom

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo"; exit 1; }
[ -f "$PKG" ] || { echo "!! $PKG missing - build it first"; exit 1; }
[ -f "$FW" ]  || { echo "!! $FW missing - extract it from the Windows install"; exit 1; }
if ! bsdtar -tf "$PKG" | grep -qx "boot/vmlinuz-linux-mibook"; then
    echo "!! $PKG does not ship /boot/vmlinuz-linux-mibook (the -6 packaging bug)"
    echo "   rebuild it with tools/make-kernel-package.sh"
    exit 1
fi

echo "==> 0/6 saving the current boot files as the fallback"
mkdir -p "$FALLBACK"
if [ -f "$FALLBACK/vmlinuz-linux-mibook.pre-vdec" ]; then
    keep="$FALLBACK/prev-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$keep"
    mv "$FALLBACK"/*.pre-vdec "$keep"/ 2>/dev/null || true
    echo "    previous fallback moved to $keep"
fi
# Each saved set is ~90 MB; keep the two most recent ones and drop the rest.
ls -1dt "$FALLBACK"/prev-* 2>/dev/null | tail -n +3 | while read -r old; do
    case "$old" in
        "$FALLBACK"/prev-*) rm -rf -- "$old" && echo "    pruned old fallback $old" ;;
        *) echo "    skipping unexpected path $old" ;;
    esac
done
install -Dm644 /boot/vmlinuz-linux-mibook "$FALLBACK/vmlinuz-linux-mibook.pre-vdec"
install -Dm644 /boot/initramfs-linux-mibook.img "$FALLBACK/initramfs-linux-mibook.img.pre-vdec"
install -Dm644 "$BDTB/$DTB.dtb" "$FALLBACK/$DTB.dtb.pre-vdec"
ls -l "$FALLBACK" | tail -5

echo "==> 1/6 firmware"
install -Dm644 "$FW" /lib/firmware/qcom/sc8180x/venus.mbn
strings /lib/firmware/qcom/sc8180x/venus.mbn | grep -m1 QC_IMAGE_VERSION_STRING || true

echo "==> 2/6 keeping the probe manual"
# Written before the package install, so the initramfs the .INSTALL builds
# carries the blacklist too.
rm -f /etc/modprobe.d/blacklist-video-poc.conf /etc/modprobe.d/vdec-probe.conf
cat > /etc/modprobe.d/vdec-probe.conf <<'CONF'
# Added by probe-vdec-run.sh.  "blacklist" only stops udev from autoloading
# qcom-iris at boot; an explicit "modprobe qcom-iris" still works, which is how
# the VPU probe is meant to be started.  videocc-sm8150 is not blacklisted: it
# is harmless and the codec node needs it as a supplier.
blacklist qcom-iris
CONF
cat /etc/modprobe.d/vdec-probe.conf

echo "==> 3/6 kernel package (pkgrel $PKGREL)"
CUR_A="$(gzip -dc /boot/vmlinuz-linux-mibook 2>/dev/null | md5sum | cut -d' ' -f1)"
TREE_B="$(md5sum "$K/arch/arm64/boot/Image" | cut -d' ' -f1)"
IRIS_KO="/usr/lib/modules/$KVER/kernel/drivers/media/platform/qcom/iris/qcom-iris.ko"
KO_MEMBER="usr/lib/modules/$KVER/kernel/drivers/media/platform/qcom/iris/qcom-iris.ko"
CUR_OWN="$(stat -c %u "$IRIS_KO" 2>/dev/null || echo none)"
# Compare the installed module against the copy inside the package, byte for
# byte.  The iris module is what most of these rebuilds change, and a
# module-only rebuild leaves the kernel image byte-identical - so a check that
# only looks at /boot/vmlinuz and file ownership says "already this build" and
# the probe silently runs the *previous* module.  mtimes are not usable here
# (the package's copy is stripped, which rewrites it), the bytes are.
PKG_KO_SUM="$(bsdtar -xOf "$PKG" "$KO_MEMBER" 2>/dev/null | sha256sum | cut -d' ' -f1)"
CUR_KO_SUM="$(sha256sum "$IRIS_KO" 2>/dev/null | cut -d' ' -f1)"
if [ "$CUR_A" = "$TREE_B" ] && [ /boot/initramfs-linux-mibook.img -nt /boot/vmlinuz-linux-mibook ] \
   && [ "$CUR_OWN" = "0" ] && [ -n "$PKG_KO_SUM" ] && [ "$PKG_KO_SUM" = "$CUR_KO_SUM" ]; then
    echo "    already this build (kernel matches, initramfs newer, modules root-owned,"
    echo "    installed iris module is the one in $PKG)"
    echo "    skipping the package install"
else
    pacman -U --noconfirm "$PKG"
fi

echo "==> 4/6 probe DTB"
install -Dm644 "$BDTB/$DTB.dtb" "$BDTB/$DTB-parked.dtb"
install -Dm644 "$BDTB/$DTB-vdec-probe.dtb" "$BDTB/$DTB.dtb"
install -Dm644 "$BDTB/$DTB-vdec-probe.dtb" "$BDTB/$DTB-oc.dtb"

echo "==> 5/6 verification"
fail=0
A="$(gzip -dc /boot/vmlinuz-linux-mibook | md5sum | cut -d' ' -f1)"
B="$(md5sum "$K/arch/arm64/boot/Image" | cut -d' ' -f1)"
if [ "$A" = "$B" ]; then
    echo "    ok   /boot/vmlinuz is this tree's build ($A)"
else
    echo "    FAIL /boot/vmlinuz ($A) != tree Image ($B) - kernel/module mix-up"; fail=1
fi
if [ /boot/initramfs-linux-mibook.img -nt /boot/vmlinuz-linux-mibook ]; then
    echo "    ok   initramfs is newer than the kernel"
else
    echo "    FAIL initramfs is older than the kernel - run: mkinitcpio -P"; fail=1
fi
for p in "$BDTB/$DTB.dtb" "$BDTB/$DTB-oc.dtb"; do
    st="$(fdtget -ts "$p" /soc@0/video-codec@aa00000 status)"
    if [ "$st" = "okay" ] && fdtget -t x "$p" /soc@0/video-codec@aa00000 memory-region >/dev/null 2>&1; then
        echo "    ok   $(basename "$p"): venus status=$st, memory-region set"
    else
        echo "    FAIL $(basename "$p"): venus status=$st or memory-region missing"; fail=1
    fi
done
if grep -q "^blacklist qcom-iris" /etc/modprobe.d/vdec-probe.conf && \
   ! grep -q "^install qcom-iris" /etc/modprobe.d/vdec-probe.conf; then
    echo "    ok   qcom-iris is blacklisted (manual modprobe still allowed)"
else
    echo "    FAIL qcom-iris is not safely blacklisted"; fail=1
fi
VERMAGIC="$(modinfo -F vermagic /usr/lib/modules/$KVER/kernel/drivers/media/platform/qcom/iris/qcom-iris.ko 2>/dev/null || true)"
if [ -n "$VERMAGIC" ] && gzip -dc /boot/vmlinuz-linux-mibook | strings -n 10 | grep -qxF "$VERMAGIC"; then
    echo "    ok   module vermagic matches the kernel image"
else
    echo "    warn could not confirm vermagic '$VERMAGIC' in the image"
fi
OWNER="$(stat -c %u /usr/lib/modules/$KVER/kernel/drivers/media/platform/qcom/iris/qcom-iris.ko)"
if [ "$OWNER" = "0" ]; then
    echo "    ok   module files are owned by root"
else
    echo "    FAIL module files are owned by uid $OWNER (packaging bug - reinstall)"; fail=1
fi
KO_NOW="$(sha256sum "$IRIS_KO" 2>/dev/null | cut -d' ' -f1)"
if [ -n "$PKG_KO_SUM" ] && [ "$PKG_KO_SUM" = "$KO_NOW" ]; then
    echo "    ok   installed iris module is the one in $PKG"
else
    echo "    FAIL the installed iris module is NOT the one in $PKG"
    echo "         package   ${PKG_KO_SUM:-<not readable>}"
    echo "         installed ${KO_NOW:-<not readable>}"
    echo "         the package was not installed - run: sudo pacman -U $PKG"; fail=1
fi

echo "==> 6/6 result"
if [ "$fail" -ne 0 ]; then
    echo "!! verification failed - do NOT reboot.  Report the FAIL lines above."
    exit 1
fi

cat <<'EOF'

Everything checks out.  Reboot now:

    sudo reboot

Then start the probe by hand and watch the log:

    sudo dmesg -w
    # in another console:
    sudo modprobe qcom-iris

A good run ends with /dev/video0 (see `v4l2-ctl --list-devices`, `dmesg | grep -i iris`).
An arm-smmu fault prints the real stream id - compare it with the 0x2100 in the DTB.

If it wedges: power-cycle.  qcom-iris is blacklisted, so the machine boots
normally and does not probe; then run tools/recover-working.sh to return to the
parked DTB.
EOF
