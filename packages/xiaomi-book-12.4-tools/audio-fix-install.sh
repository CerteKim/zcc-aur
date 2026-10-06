#!/bin/sh
# Install the Xiaomi Book 12.4 audio fixes.  Run with sudo.
#
#   sudo tools/audio-fix-install.sh
#
# The root cause of this machine's "quiet compared to Windows, with the
# occasional crackle" was the speaker backend: sdm845_be_hw_params_fixup()
# pinned SLIMBUS_0_RX to S24_LE, one byte of misalignment, 20-48 dB down.
# PipeWire picks the front-end format from those backend constraints, so every
# player was on the quiet path and the only way to hear anything was to push
# the WCD934x RX digital volume to its +40 dB maximum.  Everything below
# follows from that.
#
# What this installs, and why the pieces belong together:
#
#   1. snd-soc-sdm845.ko -- back to the generic S16_LE backend (the actual
#      fix), plus a cap of RX1/RX2/RX7/RX8 Digital Volume at 84 = 0 dB.
#      Those are signed dB controls running to +40 dB and the UCM exposes them
#      as the playback volumes, so with the level now correct 100% on the
#      desktop slider would mean +40 dB of overdrive.  The cap is only
#      correct together with the format fix: while the path was still 20-48 dB
#      down it made the speakers completely silent.
#
#   2. snd-soc-wsa881x.ko -- the *stock* driver.  The local PA-gain patch
#      (which stops wsa881x_spkr_pa_event() rewriting SPKR_DRV_GAIN back to
#      +12 dB on every DAPM power-up) is deliberately NOT installed here: it
#      adds a bus access at PRE_PMU which aggravates the amplifier power-up
#      race, and that race is what occasionally leaves an amp stuck with
#      power/runtime_status=error and no audio at all.  Use
#      `tools/install-amp-variant.sh h1a` for the +6 dB -- that variant also
#      stops the amplifier being power-cycled, which removes the race and the
#      pops rather than aggravating them.
#
#   3. The UCM verb -- uses the simple-mixer element names ("Speaker
#      Digital" / "HP Digital") so WirePlumber can actually take over the
#      hardware gain instead of falling back to software volume.
#
#   4. Pins the stored mixer state at 0 dB and re-stores it, so alsa-restore
#      stops writing a stale 124 (+40 dB) into the codec at every boot.
#
# Everything takes effect on the next reboot.
set -eu

[ "$(id -u)" = 0 ] || { echo "run me with sudo" >&2; exit 1; }

here=$(cd "$(dirname "$0")/.." && pwd)
kernver=$(uname -r)
moddir="/usr/lib/modules/${kernver}/kernel/sound/soc"
ucmdir=/usr/share/alsa/ucm2/Qualcomm/xiaomi-book-12.4

for f in \
	"${here}/tools/orig-snd-soc-wsa881x.ko" \
	"${here}/src/kernel/sound/soc/qcom/snd-soc-sdm845.ko" \
	"${here}/ucm2/Qualcomm/xiaomi-book-12.4/HiFi.conf"
do
	[ -f "$f" ] || { echo "missing $f -- build it first" >&2; exit 1; }
done

echo "== kernel release: ${kernver} =="
case "$kernver" in
	6.18.2-1-mibook*) ;;
	*) echo "WARNING: these modules were built for 6.18.2-1-mibook+;" >&2
	   echo "         ${kernver} will refuse to load them." >&2 ;;
esac

echo "== installing modules =="
install -Dm644 "${here}/tools/orig-snd-soc-wsa881x.ko" \
	"${moddir}/codecs/snd-soc-wsa881x.ko"
install -Dm644 "${here}/src/kernel/sound/soc/qcom/snd-soc-sdm845.ko" \
	"${moddir}/qcom/snd-soc-sdm845.ko"
depmod -a "${kernver}"
echo "   (the stock amplifier driver is installed on purpose -- see the header;"
echo "    for +6 dB and no amplifier power-cycling instead:"
echo "      sudo tools/install-amp-variant.sh h1a )"

echo "== installing the UCM verb =="
install -Dm644 "${here}/ucm2/Qualcomm/xiaomi-book-12.4/HiFi.conf" \
	"${ucmdir}/HiFi.conf"

echo "== pinning the stored gain at 0 dB =="
if [ -e /dev/snd/controlC0 ]; then
	# Speaker Digital Volume is the ctl-remap of RX7/RX8; 84 is 0 dB.
	amixer -c 0 -q cset numid=2 84 2>/dev/null || true
	amixer -c 0 -q cset numid=4 12 2>/dev/null || true   # SpkrLeft  PA: +18 dB
	amixer -c 0 -q cset numid=10 12 2>/dev/null || true  # SpkrRight PA: +18 dB
	alsactl store
	echo
	echo "current speaker gain:"
	amixer -c 0 sget 'Speaker Digital' | tail -2 || true
else
	echo "(no controlC0; run 'amixer -c 0 cset numid=2 84 && alsactl store' after boot)"
fi

cat <<'EOF'

== done -- reboot to activate ==

After the reboot check:

  # 1. the cap is in place: expect "Limits: 0 - 84" and 0.00dB at 100%
  amixer -c 0 sget 'Speaker Digital'

  # 2. WirePlumber took the hardware volume: no warning, and the slider moves
  #    the codec register (nothing needs to be playing)
  journalctl --user -u wireplumber --since "-2min" | grep "not a volume" || echo "clean"
  wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.5 && amixer -c 0 sget 'Speaker Digital'

  # 3. the amplifier gain sticks across playback (PA*12 = +18 dB = "12")
  amixer -c 0 cget numid=4     # SpkrLeft PA Volume
  aplay -D hw:0,0 /usr/share/sounds/alsa/Front_Center.wav
  amixer -c 0 cget numid=4     # should still read 12, not 8

If step 3 reads 8 again after playback, the wsa881x module did not load:
  dmesg | grep -i wsa881x ; modinfo snd_soc_wsa881x | grep vermagic
EOF
