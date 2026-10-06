#!/bin/bash
# Rebuild the DTBs from the tree and install the probe variant (VPU node
# enabled) into both GRUB-referenced paths, keeping the parked ones as backups.
#
#   sudo bash /home/certe/aarch64-packages/linux-surface/tools/update-probe-dtb.sh
#
# The tree's board DTS stays parked (VPU node disabled); the probe variant is
# the same DTB with the node's status flipped to "okay", which is also how
# tools/make-kernel-package.sh derives it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="$REPO/src/kernel"
DTB=sc8180x-xiaomi-book-12.4
BDTB=/boot/dtb/linux-mibook/qcom

echo "==> building DTBs from the tree"
make -s -C "$K" ARCH=arm64 dtbs

SRC="$K/arch/arm64/boot/dts/qcom/$DTB.dtb"
[ -f "$SRC" ] || { echo "!! $SRC missing"; exit 1; }

echo "==> installing parked + probe variants"
install -Dm644 "$SRC" "$BDTB/$DTB-parked.dtb"
install -Dm644 "$SRC" "$BDTB/$DTB-vdec-probe.dtb"
fdtput -ts "$BDTB/$DTB-vdec-probe.dtb" /soc@0/video-codec@aa00000 status okay
install -Dm644 "$BDTB/$DTB-vdec-probe.dtb" "$BDTB/$DTB.dtb"
install -Dm644 "$BDTB/$DTB-vdec-probe.dtb" "$BDTB/$DTB-oc.dtb"

echo "==> verification"
for p in "$BDTB/$DTB.dtb" "$BDTB/$DTB-oc.dtb"; do
    echo -n "    $(basename "$p") venus: "
    fdtget -ts "$p" /soc@0/video-codec@aa00000 status
done
echo -n "    ramoops node: "
fdtget -ts "$BDTB/$DTB.dtb" /reserved-memory/ramoops@a0500000 compatible
echo
echo "reboot to pick the new DTBs up"
