#!/bin/bash
# Verify the S16_LE backend fix on the Xiaomi Book 12.4.
#
# Before the fix, the SLIMBUS_0_RX backend was pinned to S24_LE and lost
# 20-48 dB, so the WCD934x RX digital volume had to sit at +40 dB (raw 124)
# for anything to be audible.  With the mainline S16_LE backend, 0 dB
# (raw 84) should be plainly audible.
#
# Usage:  tools/audio-level-test.sh
#
# It waits for hw:0,0 to be free, pins the codec digital volume at 0 dB and
# plays a tone straight to the hardware -- no PipeWire, no desktop slider.
set -u

TONE=/tmp/audio-cal/beep16.raw
LOG=/tmp/audio-cal/level-test.log
mkdir -p /tmp/audio-cal
: > "$LOG"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

if [ ! -f "$TONE" ]; then
	log "generating the test tone"
	ffmpeg -y -hide_banner -loglevel error -f lavfi \
		-i "sine=frequency=880:sample_rate=48000:duration=1.5" \
		-af "volume=-12dB" -ac 2 -c:a pcm_s16le /tmp/audio-cal/_t.wav
	tail -c +45 /tmp/audio-cal/_t.wav > "$TONE"
fi

log "waiting for hw:0,0 to be free (pause the browser audio, up to 300s)"
for i in $(seq 1 300); do
	st=$(grep -m1 '^state' /proc/asound/card0/pcm0p/sub0/status 2>/dev/null | awk '{print $2}')
	[ "$st" = closed ] || [ -z "$st" ] && { log "free after ${i}s"; break; }
	sleep 1
done
sleep 3

log "pinning RX7/RX8 Digital Volume to 84 (0 dB)"
amixer -c 0 -q cset numid=2 84
log "readback: $(amixer -c 0 cget numid=32 | grep -m1 ': values' | awk '{print $2}')"

log "playing the tone directly to hw:0,0 as S16_LE  <-- LISTEN NOW"
aplay -D hw:0,0 -f S16_LE -c 2 -r 48000 "$TONE" 2>&1 | tail -2
log "playback finished"

if [ "${KEEP_0DB:-0}" != "1" ]; then
	log "restoring the codec volume to 124"
	amixer -c 0 -q cset numid=2 124
fi

cat <<'EOF'

Interpretation:
  * Heard it at 0 dB  -> the backend format was the bug; the 40 dB of digital
    gain is no longer needed and the "+40 dB or nothing" behaviour is gone.
  * Heard nothing     -> the deficit is elsewhere; say so and we keep digging.

Report back with:
  amixer -c 0 sget 'Speaker Digital'
  grep -c Memory_map_regions /dev/null; dmesg | tail -20
EOF
