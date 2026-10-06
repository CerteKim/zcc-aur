#!/bin/bash
# Install the DTB built from this tree into /boot, keeping the parked/probe
# arrangement that is in use:
#
#   sc8180x-xiaomi-book-12.4.dtb             parked  (GRUB "Arch Linux" entry)
#   sc8180x-xiaomi-book-12.4-oc.dtb          parked  (default entry's name)
#   sc8180x-xiaomi-book-12.4-parked.dtb      parked  (backup copy)
#   sc8180x-xiaomi-book-12.4-vdec-probe.dtb  same DTB, VPU node flipped to okay
#
# Unlike tools/update-probe-dtb.sh this never makes the two booted paths probe
# the VPU; it only refreshes the probe variant next to them.
#
# Rebuild the DTB first if the DTS changed, then install and reboot:
#
#   make -C src/kernel ARCH=arm64 qcom/sc8180x-xiaomi-book-12.4.dtb
#   sudo bash tools/install-dtb-from-tree.sh
#   sudo reboot
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="$REPO/src/kernel"
BASE=sc8180x-xiaomi-book-12.4
SRC="$K/arch/arm64/boot/dts/qcom/$BASE.dtb"
BDTB="${BDTB:-/boot/dtb/linux-mibook/qcom}"

if [ ! -f "$SRC" ]; then
    echo "!! $SRC is missing; build it first:" >&2
    echo "   make -C $K ARCH=arm64 qcom/$BASE.dtb" >&2
    exit 1
fi

echo "==> installing the parked DTB into $BDTB"
for n in "$BASE.dtb" "$BASE-oc.dtb" "$BASE-parked.dtb"; do
    install -Dm644 "$SRC" "$BDTB/$n"
done

echo "==> deriving the probe variant"
install -Dm644 "$SRC" "$BDTB/$BASE-vdec-probe.dtb"
fdtput -ts "$BDTB/$BASE-vdec-probe.dtb" /soc@0/video-codec@aa00000 status okay

echo "==> verification"
for n in "$BASE.dtb" "$BASE-oc.dtb" "$BASE-parked.dtb" "$BASE-vdec-probe.dtb"; do
    printf '    %-44s venus=%-9s local-bd-address=%s\n' "$n" \
        "$(fdtget -ts "$BDTB/$n" /soc@0/video-codec@aa00000 status)" \
        "$(fdtget -t x "$BDTB/$n" \
            /soc@0/geniqup@cc0000/serial@c8c000/bluetooth local-bd-address \
            2>/dev/null || echo '(none)')"
done
echo
echo "reboot to pick the new DTBs up"
