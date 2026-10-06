#!/usr/bin/env bash
# Install /etc/libinput/local-overrides.quirks so the Xiaomi Book 12.4 cover
# keyboard is treated as an internal keyboard, which enables libinput's
# disable-while-typing (DWT) for the cover touchpad.
#
# Usage: sudo ./install-dwt-fix.sh
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
src="$here/local-overrides.quirks"
dst="/etc/libinput/local-overrides.quirks"

if [[ ! -f $src ]]; then
    echo "missing $src" >&2
    exit 1
fi

if [[ ${EUID} -ne 0 ]]; then
    echo "run me as root: sudo $0" >&2
    exit 1
fi

install -d -m 0755 /etc/libinput

if [[ -e $dst ]]; then
    backup="$dst.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a -- "$dst" "$backup"
    echo "backed up existing file to $backup"
fi

install -m 0644 -- "$src" "$dst"
echo "installed $dst"

cat <<'EOF'

libinput parses the quirk database when the compositor creates its libinput
context, so this needs a new session: log out and back in (or reboot).
`udevadm trigger` is NOT enough.

Verify afterwards:
  1) hold a letter key down and drag a finger over the touchpad
     -> the pointer must not move while the key is held
  2) optional, with a debug build of libinput:
     journalctl -b -o cat | grep -i 'dwt activated'
EOF
