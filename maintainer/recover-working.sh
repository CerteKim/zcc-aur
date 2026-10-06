#!/bin/bash
# Emergency: get back to a setup that does not probe the VPU.
#
#   sudo bash /home/certe/aarch64-packages/linux-surface/tools/recover-working.sh
#   sudo bash .../recover-working.sh --restore-kernel   # also swap the kernel image
#
# What this fixes, and what it deliberately does not:
#
#   * the parked device tree is put back on both GRUB DTB paths (the VPU node
#     disabled), which is what makes the machine probe at all;
#   * qcom-iris is left blacklisted so nothing autoloads, and the initramfs is
#     rebuilt so the blacklist is inside it;
#   * the kernel image is NOT touched by default.  The installed kernel and the
#     installed modules must stay the same build: restoring an older kernel from
#     the fallback while the package's modules are still installed is exactly
#     what produced the "BPF: Invalid name / failed to validate module ... BTF"
#     flood and the service failures after the -6 package.  Use
#     --restore-kernel only if the current kernel itself cannot boot, and
#     expect that mixed state afterwards.
set -euo pipefail

F=/home/certe/vdec-poc-fallback
K=/home/certe/aarch64-packages/linux-surface/src/kernel
DTB=sc8180x-xiaomi-book-12.4
BDTB=/boot/dtb/linux-mibook/qcom
RESTORE_KERNEL=0
[ "${1:-}" = "--restore-kernel" ] && RESTORE_KERNEL=1

echo "==> 1/4 parked device tree"
# Prefer the copy probe-vdec-run.sh saved; otherwise rebuild from the tree with
# the enable block stripped.
if [ -f "$BDTB/$DTB-parked.dtb" ]; then
    install -Dm644 "$BDTB/$DTB-parked.dtb" "$BDTB/$DTB.dtb"
    install -Dm644 "$BDTB/$DTB-parked.dtb" "$BDTB/$DTB-oc.dtb"
    echo "    restored $DTB-parked.dtb over both GRUB paths"
else
    sed -i '/^\/\* Iris video-codec probe:/,/^};$/d' \
        "$K/arch/arm64/boot/dts/qcom/sc8180x-xiaomi-book-12.4.dts"
    make -s -C "$K" ARCH=arm64 dtbs
    install -Dm644 "$K/arch/arm64/boot/dts/qcom/$DTB.dtb" "$BDTB/$DTB.dtb"
    install -Dm644 "$K/arch/arm64/boot/dts/qcom/$DTB.dtb" "$BDTB/$DTB-oc.dtb"
    echo "    rebuilt the parked DTB from the tree"
fi

echo "==> 2/4 keep the probe manual"
mkdir -p /etc/modprobe.d
rm -f /etc/modprobe.d/blacklist-video-poc.conf
cat > /etc/modprobe.d/vdec-probe.conf <<'CONF'
# Added by recover-working.sh.  "blacklist" stops udev from autoloading
# qcom-iris; an explicit "modprobe qcom-iris" still works.
blacklist qcom-iris
CONF
cat /etc/modprobe.d/vdec-probe.conf

if [ "$RESTORE_KERNEL" -eq 1 ]; then
    echo "==> 3/4 restoring the fallback kernel and initramfs"
    echo "    WARNING: the installed modules will then be from a different build"
    install -Dm644 "$F/vmlinuz-linux-mibook.pre-vdec" /boot/vmlinuz-linux-mibook
    [ -f "$F/initramfs-linux-mibook.img.pre-vdec" ] && \
        install -Dm644 "$F/initramfs-linux-mibook.img.pre-vdec" /boot/initramfs-linux-mibook.img
else
    echo "==> 3/4 kernel left alone (use --restore-kernel to override)"
fi

echo "==> 4/4 initramfs and verification"
mkinitcpio -P >/dev/null 2>&1 || echo "    mkinitcpio failed - run 'sudo mkinitcpio -P' by hand"
for p in "$BDTB/$DTB.dtb" "$BDTB/$DTB-oc.dtb"; do
    echo -n "    $(basename "$p") venus status: "
    fdtget -ts "$p" /soc@0/video-codec@aa00000 status
done
ls -l /boot/dtb/linux-mibook/qcom/
echo
echo "Reboot now:  sudo reboot"
