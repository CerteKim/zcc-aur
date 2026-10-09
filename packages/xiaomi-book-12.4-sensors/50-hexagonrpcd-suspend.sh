#!/bin/sh
# /usr/lib/systemd/system-sleep/50-hexagonrpcd-suspend.sh
#
# Keep the Qualcomm sensor stack alive across s2idle.
#
# On this board every resume faults the SLPI's sensor process:
#
#     PDM: service 'sensor_process' crash: 'EX:sensor_process:0x1:frpc_dsp:0x6f:PC=0xb205fb9c'
#     remoteproc remoteproc0: crash detected in slpi: type fatal error
#
# remoteproc then restarts the DSP, which takes /dev/fastrpc-sdsp down and
# brings it back within the same second.  iio-sensor-proxy (Restart=no, pulled
# in by that device) drops every sensor and exits, and nothing ever restarts
# it - so auto-rotation stays dead for the rest of the session.
#
# The fault is in the DSP's FastRPC client (frpc_dsp) and it happens at the
# unfreeze, so the cause is a file-serving request that is in flight when the
# AP freezes.  Confirmed on 2026-10-09 with the same kernel and two suspends:
#
#   daemon still up at freeze   -> PDM: service 'sensor_process' crash
#   (path unit had restarted it)   'EX:sensor_process:0x1:frpc_dsp:0x6f'
#                                  remoteproc: crash detected in slpi
#                                  /dev/fastrpc-sdsp re-created, proxy exits
#
#   daemon down at freeze       -> no fault at all, /dev/fastrpc-sdsp is never
#   (this hook)                    removed, iio-sensor-proxy keeps its sensors
#                                  and mutter its claim
#
# So step one is to make sure the daemon really is down across the freeze:
#
#   * the .path unit must go down as well.  `PathExists=/dev/fastrpc-sdsp` is
#     still true, and systemd re-evaluates a path unit as soon as the unit it
#     triggered deactivates - stopping only the service leaves it running again
#     a few milliseconds later.  That is how the first test of this hook got a
#     false negative: the log showed "Started ..." 15 ms after "Stopped ...",
#     systemctl warned "its triggering units are still active:
#     hexagonrpcd-sdsp.path", and the daemon was up again at freeze time.
#   * the service itself is stopped too, and `systemctl stop` waits, so by the
#     time this hook returns the daemon is gone and its fd is closed.
#
# Step two (the `post` branch) is the safety net: put both units back, and
# restart iio-sensor-proxy if the DSP crashed anyway and took the proxy with it.
# With the two steps above that branch has not been needed any more, but it
# stays for the case where the DSP dies for some other reason.
#
# Same idea as postmarketOS' device-google-sargo workaround (pmaports!5400,
# "resuming from suspend with HexagonRPCD running crashes the ADSP").
#
# systemd runs hooks from both /usr/lib/systemd/system-sleep/ (this file, so
# the package owns it) and /etc/systemd/system-sleep/ (local overrides).
#
# $1 = pre|post, $2 = suspend|hibernate|hybrid-sleep|suspend-then-hibernate.
# stdout/stderr go to the journal, so everything below is greppable with
#     journalctl -b | grep qcom-sensors

TAG="qcom-sensors"
OP=${1:-}
KIND=${2:-suspend}

log() { echo "$TAG: $*"; }

case "$OP" in
pre)
	# The path unit first: while it is active it re-triggers the service the
	# moment the service stops.
	if systemctl is-active --quiet hexagonrpcd-sdsp.path; then
		log "stopping hexagonrpcd-sdsp.path before $KIND"
		systemctl stop hexagonrpcd-sdsp.path || log "path stop failed"
	fi
	if systemctl is-active --quiet hexagonrpcd-sdsp.service; then
		log "stopping hexagonrpcd-sdsp.service before $KIND"
		systemctl stop hexagonrpcd-sdsp.service || log "service stop failed"
	fi

	# Say so explicitly: this is the line that tells the next reader whether
	# the "in-flight request" theory was actually tested.
	if systemctl is-active --quiet hexagonrpcd-sdsp.service; then
		log "WARNING: hexagonrpcd-sdsp is still active before $KIND"
	else
		log "hexagonrpcd-sdsp is down before $KIND"
	fi
	;;

post)
	# The daemon is what hands the SSC its sensor registry, so it has to be
	# back.  Wait for the FastRPC device first: if the SLPI crashed anyway,
	# remoteproc is busy re-creating it.
	i=0
	while [ ! -e /dev/fastrpc-sdsp ] && [ "$i" -lt 30 ]; do
		sleep 1
		i=$((i + 1))
	done
	if [ -e /dev/fastrpc-sdsp ]; then
		log "/dev/fastrpc-sdsp is present after ${i}s; starting the sensor stack"
		systemctl start hexagonrpcd-sdsp.service || log "service start failed"
		systemctl start hexagonrpcd-sdsp.path || log "path start failed"
	else
		log "/dev/fastrpc-sdsp did not appear within ${i}s"
	fi

	# Only touch the proxy when it is really gone, so a healthy accelerometer
	# is never dropped on a resume that went fine.  Note that mutter may then
	# need its claim recipe re-run (~/.local/bin/mutter-accelerometer-claim.sh)
	# from the user session - a root hook cannot do that.  The proxy needs a
	# while to re-discover the SSC, so HasAccelerometer is logged for the
	# record and may well read false here.
	if command -v busctl >/dev/null 2>&1 &&
			! systemctl is-active --quiet iio-sensor-proxy.service; then
		log "iio-sensor-proxy is down; restarting it"
		systemctl restart iio-sensor-proxy.service || log "proxy restart failed"
		sleep 3
		log "HasAccelerometer=$(busctl --system get-property \
			net.hadess.SensorProxy /net/hadess/SensorProxy \
			net.hadess.SensorProxy HasAccelerometer 2>/dev/null || echo '?') (early, may still be false)"
	fi
	;;
esac

# Never fail the sleep operation.
exit 0
