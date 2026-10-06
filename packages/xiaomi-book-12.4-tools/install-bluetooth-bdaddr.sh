#!/bin/bash
# Install (or refresh) the WCN3998 BD address workaround.
#
#   sudo bash tools/install-bluetooth-bdaddr.sh [address]
#   sudo bash tools/install-bluetooth-bdaddr.sh --uninstall
#
# This is the fallback for DTBs without local-bd-address; the supported route
# is the device tree property (see the Bluetooth section of HARDWARE-STATUS.md).
# --uninstall removes it again, which is what the device tree route wants.
#
# The board's Bluetooth controller has no address provisioned, so it comes up
# unconfigured and invisible to BlueZ.  This installs the files below and runs
# the unit once, which usually makes Bluetooth usable without a reboot:
#
#   /usr/local/bin/bluetooth-bdaddr.sh
#   /etc/conf.d/bluetooth-bdaddr                  (kept if it already exists)
#   /etc/systemd/system/bluetooth-bdaddr.service
#   /usr/lib/udev/rules.d/60-bluetooth-bdaddr.rules
#
# Pass an address to (re)write /etc/conf.d/bluetooth-bdaddr; without one an
# existing configuration is left alone.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/systemd"

if [ "${1:-}" = "--uninstall" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "run this as root (sudo bash $0 --uninstall)" >&2
        exit 1
    fi

    echo "==> disabling and removing the unit, script and udev rule"
    systemctl disable --now bluetooth-bdaddr.service 2>/dev/null || true
    rm -f /etc/systemd/system/bluetooth-bdaddr.service
    rm -f /usr/local/bin/bluetooth-bdaddr.sh
    rm -f /usr/lib/udev/rules.d/60-bluetooth-bdaddr.rules
    systemctl daemon-reload
    udevadm control --reload

    echo "==> done; /etc/conf.d/bluetooth-bdaddr was left in place"
    exit 0
fi

ADDR="${1:-}"

if [ "$(id -u)" -ne 0 ]; then
    echo "run this as root (sudo bash $0${ADDR:+ $ADDR})" >&2
    exit 1
fi

echo "==> installing script, unit and udev rule"
install -Dm755 "$SRC/bluetooth-bdaddr.sh"       /usr/local/bin/bluetooth-bdaddr.sh
install -Dm644 "$SRC/bluetooth-bdaddr.service"  /etc/systemd/system/bluetooth-bdaddr.service
install -Dm644 "$SRC/60-bluetooth-bdaddr.rules" /usr/lib/udev/rules.d/60-bluetooth-bdaddr.rules

if [ -n "$ADDR" ]; then
    echo "==> setting the address to $ADDR"
    install -Dm644 "$SRC/bluetooth-bdaddr.conf" /etc/conf.d/bluetooth-bdaddr
    sed -i "s/^BDADDR=.*/BDADDR=\"$ADDR\"/" /etc/conf.d/bluetooth-bdaddr
elif [ -e /etc/conf.d/bluetooth-bdaddr ]; then
    echo "==> keeping the existing address: $(sed -n 's/^BDADDR=//p' /etc/conf.d/bluetooth-bdaddr)"
else
    echo "==> installing the default address config"
    install -Dm644 "$SRC/bluetooth-bdaddr.conf" /etc/conf.d/bluetooth-bdaddr
fi

echo "==> reloading systemd and udev"
systemctl daemon-reload
udevadm control --reload

echo "==> enabling and running it now"
systemctl enable bluetooth-bdaddr.service
systemctl restart bluetooth-bdaddr.service || true

echo
echo "==> result"
systemctl --no-pager --full status bluetooth-bdaddr.service | head -16 || true
echo
hciconfig hci0 2>&1 || true
echo
echo "the adapter should now be listed by 'bluetoothctl list'.  To change the"
echo "address: edit /etc/conf.d/bluetooth-bdaddr and run"
echo "  sudo systemctl restart bluetooth-bdaddr"
