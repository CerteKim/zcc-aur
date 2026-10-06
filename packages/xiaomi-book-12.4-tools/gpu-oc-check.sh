#!/bin/bash
# Is the overclocked GPU device tree booted, and does it reach its extra states?
#
#   tools/gpu-oc-check.sh                     # state only
#   tools/gpu-oc-check.sh -- <gpu workload>   # also sample the clock under load
#
# The -oc device tree (sc8180x-xiaomi-book-12.4-oc.dts) adds the three DVFS
# states the stock table lacks, taken from the firmware's own 670 MHz profile
# (ACPI ENGINE_PSTATE_SET 0x02 / GRAPHICS_FREQ_CONTROL / CORE_CLOCK):
#
#     530 MHz @ NOM      (0x100)
#     595 MHz @ NOM_L1   (0x140)
#     670 MHz @ TURBO_L1 (0x1a0)
#
# Neither the a6xx driver nor the GMU firmware needs to change for these to
# work: a6xx_hfi_send_perf_table() hands the whole OPP table to the GMU, and
# each level's GX rail vote comes from opp-level.  The device tree has no
# speed-bin nvmem cell either, so a6xx_set_supported_hw() gets -ENOENT and no
# OPP gating (opp-supported-hw) is applied.
#
# Exit status: 0 = all three states present, 2 = booted without them,
#              3 = the devfreq device is missing (driver not loaded).
set -uo pipefail

DEV=/sys/class/devfreq/2c00000.gpu
OC_STATES="530000000 595000000 670000000"
BDTB=/boot/dtb/linux-mibook/qcom
rc=0

if [ ! -d "$DEV" ]; then
    echo "!! $DEV is missing - msm/adreno not loaded?"
    exit 3
fi

echo "== booted device trees in $BDTB"
for f in "$BDTB"/sc8180x-xiaomi-book-12.4*.dtb; do
    [ -f "$f" ] || continue
    printf '   %-48s %s\n' "$(basename "$f")" "$(md5sum "$f" | cut -d' ' -f1)"
done

echo
echo "== GPU devfreq"
printf '   available_frequencies: %s\n' "$(cat "$DEV/available_frequencies")"
printf '   cur_freq: %s   max_freq: %s   governor: %s\n' \
       "$(cat "$DEV/cur_freq")" "$(cat "$DEV/max_freq")" "$(cat "$DEV/governor" 2>/dev/null || echo -)"

echo
echo "== overclocked states"
missing=""
for f in $OC_STATES; do
    if grep -qw "$f" "$DEV/available_frequencies"; then
        printf '   %3s MHz  present\n' "$((f / 1000000))"
    else
        printf '   %3s MHz  MISSING\n' "$((f / 1000000))"
        missing="$missing $f"
    fi
done
if [ -n "$missing" ]; then
    echo
    echo "-> booted without the OC states: install the -oc DTB and reboot, e.g."
    echo "   sudo install -Dm644 src/kernel/arch/arm64/boot/dts/qcom/sc8180x-xiaomi-book-12.4-oc.dtb \\"
    echo "        /boot/dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4-oc.dtb"
    rc=2
fi

if [ "${1:-}" = "--" ] && [ "$#" -gt 1 ]; then
    shift
    echo
    echo "== sampling cur_freq while running: $*"
    "$@" >/dev/null 2>&1 &
    pid=$!
    peak=0
    while kill -0 "$pid" 2>/dev/null; do
        v=$(cat "$DEV/cur_freq" 2>/dev/null) || break
        [ "${v:-0}" -gt "$peak" ] && peak="$v"
        sleep 0.2
    done
    wait "$pid"
    st=$?
    printf '   peak cur_freq %s Hz (%s MHz), %s exited %s\n' \
           "$peak" "$((peak / 1000000))" "$*" "$st"
    if [ "$peak" -ge 670000000 ]; then
        echo "   reached the 670 MHz state"
    else
        echo "   stayed below 670 MHz - the workload may be too light to reach it"
    fi
fi

echo
echo "== GPU errors in the log"
if dmesg 2>/dev/null | grep -iE "adreno|gmu|msm" | grep -iE "fail|error|fault|timeout|reset|hang" | tail -10; then
    :
else
    echo "   none"
fi

exit "$rc"
