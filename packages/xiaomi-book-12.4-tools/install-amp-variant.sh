#!/bin/sh
# Switch the WSA881x amplifier module variant.  Run with sudo.
#
#   sudo tools/install-amp-variant.sh orig     # stock driver, no local patches
#   sudo tools/install-amp-variant.sh gain     # + keep the user PA gain (default)
#   sudo tools/install-amp-variant.sh h1a      # + never power-cycle the amp
#
# Why this exists: the amplifiers are power-cycled by runtime PM
# (wsa881x_runtime_suspend() asserts SD_N), which takes them off the SoundWire
# bus while the master is still running.  That is what pops, and occasionally
# the re-attach race loses outright -- the amp ends up stuck:
#
#   wsa881x-codec sdw:...:4: Initialization not complete, timed out
#   wsa881x-codec sdw:...:4: ASoC error (-110) at ...pm_runtime_get()
#   SLIM Playback:            ASoC error (-110) at __soc_pcm_open()
#
# and then no PCM can be opened at all, so there is no sound anywhere.
# `h1a` removes that failure mode by never cutting the amp's power; the cost is
# roughly 10-30 mW of idle power per amplifier.
#
# The variants:
#   orig  tools/orig-snd-soc-wsa881x.ko   stock 6.18.2 driver
#   gain  src/kernel/.../snd-soc-wsa881x.ko
#         keeps "SpkrLeft/Right PA Volume" across DAPM power-up, so the UCM's
#         +18 dB sticks instead of being rewritten to +12 dB.  Adds one bus
#         access at PRE_PMU, which the SoundWire analysis calls an aggravator
#         of the power-up race above.
#   h1a   tools/h1a-snd-soc-wsa881x.ko
#         `gain` plus: wsa881x_runtime_suspend() no longer asserts SD_N.
set -eu

[ "$(id -u)" = 0 ] || { echo "run me with sudo" >&2; exit 1; }

here=$(cd "$(dirname "$0")/.." && pwd)
kernver=$(uname -r)
dest="/usr/lib/modules/${kernver}/kernel/sound/soc/codecs/snd-soc-wsa881x.ko"

case "${1:-gain}" in
orig) src="${here}/tools/orig-snd-soc-wsa881x.ko" ;;
gain) src="${here}/src/kernel/sound/soc/codecs/snd-soc-wsa881x.ko" ;;
h1a)  src="${here}/tools/h1a-snd-soc-wsa881x.ko" ;;
*) echo "usage: $0 [orig|gain|h1a]" >&2; exit 2 ;;
esac

[ -f "$src" ] || { echo "missing $src" >&2; exit 1; }

printf 'variant %-5s : %s\n' "$1" "$src"
printf '  spkr_pa_event = %s (0188=stock, 01e4=keeps the PA gain)\n' \
	"$(nm -S --size-sort "$src" | grep wsa881x_spkr_pa_event | awk '{print $2}')"

install -Dm644 "$src" "$dest"
depmod -a "$kernver"
echo "installed -> $dest"
echo "reboot to activate"
