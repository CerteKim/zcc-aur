#!/bin/bash
# Set the BD address of the on-board WCN3998, which has none provisioned.
#
# Without an address the controller comes up unconfigured (HCI_UNCONFIGURED):
# it does exist as hci0 with the placeholder address that the generic
# qca/crnv21.bin NVM carries, but it is left out of the management index list,
# so bluetoothd, bluetoothctl, btmgmt and GNOME all report no adapter at all.
# Userspace has to supply an address with MGMT_OP_SET_PUBLIC_ADDRESS (btmgmt
# public-addr); the kernel then clears HCI_UNCONFIGURED, programs the address
# into the chip and re-programs it on every later power-on of the same hci
# device.
#
# The obvious one-liner does not work, for two reasons:
#
#   * The command is only accepted once the controller has finished its setup
#     and is in neither HCI_SETUP nor HCI_CONFIG.  Before that the kernel
#     answers 0x11 (Invalid Index).  hci0 appears in sysfs well before then,
#     so the command has to be retried.
#   * btmgmt with --timeout ignores the command result and exits 0 when the
#     timer fires (bt_shell_noninteractive_quit() returns early when a timeout
#     is set), so its exit status must not be used as the success check.
#
# The result is therefore verified against the controller with hciconfig.
set -euo pipefail

for tool in btmgmt hciconfig; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool is not installed (bluez-utils)" >&2
        exit 1
    fi
done

[ -r /etc/conf.d/bluetooth-bdaddr ] && . /etc/conf.d/bluetooth-bdaddr
BDADDR="${BDADDR:-02:00:00:12:34:56}"

# This kernel does not expose the address in sysfs (the bluetooth class only
# has a reset attribute), so read it through the HCI socket ioctl instead.
current_addr() {
    hciconfig hci0 2>/dev/null |
        sed -n 's/.*BD Address: *\([0-9A-Fa-f:]*\).*/\1/p' | tr 'A-F' 'a-f'
}

# HCI_RAW is set while the controller is unconfigured and cleared once the
# address has been accepted.  A missing controller is not "configured".
is_configured() {
    local out
    out="$(hciconfig hci0 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1
    ! printf '%s\n' "$out" | grep -qw RAW
}

# The UART attach and the QCA patch/NVM download take a moment, and the
# controller only becomes configurable after them.
for _ in $(seq 1 40); do
    [ -d /sys/class/bluetooth/hci0 ] && break
    sleep 0.5
done

if [ ! -d /sys/class/bluetooth/hci0 ]; then
    echo "hci0 never appeared, not setting the address" >&2
    exit 0
fi

if is_configured; then
    echo "hci0 is already configured (address $(current_addr))"
    exit 0
fi

for _ in $(seq 1 30); do
    # --timeout 1 makes btmgmt exit on its own; the exit status is meaningless
    # (see above), so the outcome is checked with hciconfig below.
    btmgmt --index 0 --timeout 1 public-addr "$BDADDR" >/dev/null 2>&1 || true

    if is_configured; then
        echo "hci0 configured, address $(current_addr)"
        exit 0
    fi

    sleep 0.5
done

echo "failed to set the hci0 address to $BDADDR" >&2
hciconfig hci0 >&2 || true
exit 1
