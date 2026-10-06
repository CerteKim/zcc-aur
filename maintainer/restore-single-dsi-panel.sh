#!/bin/bash
# Restore the previous single-DSI panel state (kernel, initramfs, DTBs) from
# the fallback directory created by install-mainline-panel.sh.
#
#   sudo ./tools/restore-single-dsi-panel.sh [FALLBACK_DIR]
#
# The old initramfs is regenerated from the current modules tree, which is
# still the tree the fallback kernel was built from unless a new kernel has
# been installed in the meantime.
set -euo pipefail

FALLBACK="${1:-/home/certe/panel-fallback-single-dsi}"
BOOT_DTB_DIR="/boot/dtb/linux-mibook/qcom"
DTB="sc8180x-xiaomi-book-12.4.dtb"
KVER="$(ls -d /usr/lib/modules/6.18.2-* 2>/dev/null | sed 's|.*/||' | head -1)"

[ -d "$FALLBACK" ] || { echo "!! no fallback directory at $FALLBACK"; exit 1; }

echo "==> restoring kernel image"
install -Dm644 "$FALLBACK/vmlinuz-linux-mibook.single-dsi" /boot/vmlinuz-linux-mibook

echo "==> restoring DTBs"
install -Dm644 "$FALLBACK/${DTB}.single-dsi" "$BOOT_DTB_DIR/${DTB}"
install -Dm644 "$FALLBACK/sc8180x-xiaomi-book-12.4-oc.dtb.single-dsi" \
    "$BOOT_DTB_DIR/sc8180x-xiaomi-book-12.4-oc.dtb"

echo "==> regenerating initramfs for ${KVER}"
rm -f /boot/initramfs-linux-mibook.img
mkinitcpio -k "$KVER" -g /boot/initramfs-linux-mibook.img
chmod 644 /boot/initramfs-linux-mibook.img

echo "Done.  Reboot to return to the previous display stack."
