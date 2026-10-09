#!/bin/sh
# /usr/lib/systemd/system-sleep/50-hexagonrpcd-suspend.sh
#
# Keep the Qualcomm sensor stack alive across s2idle.
#
# On this board every resume used to fault the SLPI's sensor process:
#
#     PDM: service 'sensor_process' crash: 'EX:sensor_process:0x1:frpc_dsp:0x6e:PC=0xb205fb9c'
#     remoteproc remoteproc0: crash detected in slpi: type fatal error
#
# remoteproc then restarts the DSP, which takes /dev/fastrpc-sdsp down and
# brings it back within the same second.  iio-sensor-proxy (Restart=no, pulled
# in by that device) drops every sensor and exits, and nothing ever restarts
# it - so auto-rotation stays dead for the rest of the session.
#
# The fault is in the DSP's FastRPC client (frpc_dsp) and it happens while
# hexagonrpcd - the DSP's file server for the sensor registry - is connected.
# The DSP keeps running through s2idle while the AP is frozen, so the most
# likely trigger is a file-serving transaction that is in flight when the AP
# freezes.  So: stop the server before the freeze, bring it back afterwards.
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
	# No FastRPC request may straddle the freeze.  `systemctl stop` waits,
	# so by the time we return the daemon is gone and its fd is closed.
	if systemctl is-active --quiet hexagonrpcd-sdsp.service; then
		log "stopping hexagonrpcd-sdsp before $KIND"
		systemctl stop hexagonrpcd-sdsp.service || log "stop failed"
	else
		log "hexagonrpcd-sdsp not running before $KIND"
	fi
	;;

post)
	# The daemon is what hands the SSC its sensor registry, so it has to be
	# back.  Do not rely on hexagonrpcd-sdsp.path here: the path was already
	# true when we stopped the service, and an explicit stop also clears the
	# service's own Restart=always.
	i=0
	while [ ! -e /dev/fastrpc-sdsp ] && [ "$i" -lt 30 ]; do
		sleep 1
		i=$((i + 1))
	done
	if [ -e /dev/fastrpc-sdsp ]; then
		log "/dev/fastrpc-sdsp is present after ${i}s; starting hexagonrpcd-sdsp"
		systemctl start hexagonrpcd-sdsp.service || log "start failed"
	else
		log "/dev/fastrpc-sdsp did not appear within ${i}s"
	fi

	# Belt and braces: if the SLPI still crashed, its recovery removed and
	# re-created the FastRPC device and the proxy will have exited with the
	# sensors.  Only touch it when it is really gone, so a healthy
	# accelerometer is never dropped on a resume that went fine.  Note that
	# mutter may then need its claim recipe re-run (~/.local/bin/
	# mutter-accelerometer-claim.sh) from the user session - a root hook
	# cannot do that.
	if command -v busctl >/dev/null 2>&1 &&
			! systemctl is-active --quiet iio-sensor-proxy.service; then
		log "iio-sensor-proxy is down; restarting it"
		systemctl restart iio-sensor-proxy.service || log "proxy restart failed"
		sleep 3
		log "HasAccelerometer=$(busctl --system get-property \
			net.hadess.SensorProxy /net/hadess/SensorProxy \
			net.hadess.SensorProxy HasAccelerometer 2>/dev/null || echo '?')"
	fi
	;;
esac

# Never fail the sleep operation.
exit 0
