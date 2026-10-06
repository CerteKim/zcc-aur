#!/bin/bash
# s2idle bring-up helpers for the Xiaomi Book S 12.4 (SC8180X).
#
#   sudo bash tools/suspend-test.sh prep             # verbose PM logging + sync the journal
#   sudo bash tools/suspend-test.sh level freezer    # pm_test=freezer   (freeze tasks only)
#   sudo bash tools/suspend-test.sh level devices    # pm_test=devices   (device suspend/resume)
#   sudo bash tools/suspend-test.sh level platform   # pm_test=platform  (adds noirq/late prepare)
#   sudo bash tools/suspend-test.sh level none       # put pm_test back to none
#   sudo bash tools/suspend-test.sh rtc 30           # REAL s2idle, self-wake by RTC alarm in 30 s
#   sudo bash tools/suspend-test.sh real             # REAL s2idle, nothing armed (the failing case)
#   bash tools/suspend-test.sh report                # after a hard reset: what the last boot recorded
#
# What this can and cannot isolate
# --------------------------------
# mem_sleep is s2idle on this machine, and for suspend-to-idle the kernel accepts
# only the none/freezer/devices/platform test levels:
#
#     kernel/power/suspend.c: "Unsupported test mode for suspend to idle,
#                              please choose none/freezer/devices/platform."
#
# and with TEST_PLATFORM set, suspend_enter() jumps straight to Platform_wake,
# so even "platform" never runs s2idle_loop().  Consequences:
#
#   * "devices"  passes  -> dpm_suspend/resume of every driver is fine;
#   * "platform" passes  -> noirq + late platform prepare is fine too;
#   * neither of them can test the s2idle loop itself, so the s2idle entry
#     (cpuidle -> PSCI OSI -> cluster_sleep_aoss_sleep, wakeup via the PDC)
#     is only exercised by a real suspend.
#
# So the ladder tells you where it is NOT.  The decisive run is `rtc`: a real
# s2idle with an alarm armed, which distinguishes
#
#   * comes back by itself  -> s2idle entry/exit works; the machine was simply
#                              unwakeable (no power key, no lid/USB wake routed);
#   * never comes back      -> the hang is in the s2idle entry or wakeup path.
#
# Everything is appended to $LOG and synced, so the marker survives a hard
# reset: "ATTEMPT" without "RESUMED" means the kernel never returned, while
# "RESUMED" present means it did return and only the display stayed black.
set -euo pipefail

LOG=/var/log/suspend-test.log
STAMP=$(date -Is)
PWR=/sys/power

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }
die() { echo "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "run as root: sudo bash $0 $*"; }

dump_state() {
    {   echo "--- state $STAMP"
        echo "cmdline:  $(cat /proc/cmdline)"
        echo "state:    $(cat $PWR/state)"
        echo "mem_sleep:$(cat $PWR/mem_sleep)"
        echo "pm_test:  $(cat $PWR/pm_test)"
        echo "pm_debug_messages: $(cat $PWR/pm_debug_messages 2>/dev/null || echo n/a)"
        echo "suspend_stats: success=$(cat $PWR/suspend_stats/success) fail=$(cat $PWR/suspend_stats/fail)"
        echo "rtc wakealarm: $(cat /sys/class/rtc/rtc0/wakealarm 2>/dev/null || echo none)"
        echo "wakeup sources:"
        for d in /sys/class/wakeup/wakeup*; do
            n=$(cat "$d/name" 2>/dev/null) || continue
            [ -n "$n" ] && printf '    %-40s %s\n' "$n" "$(cat "$d/active_count" 2>/dev/null || echo -)"
        done
    } >>"$LOG"
}

prep() {
    need_root "$@"
    echo 1 > "$PWR/pm_debug_messages"
    echo 1 > "$PWR/pm_print_times" 2>/dev/null || true
    echo 1 > "$PWR/pm_async" 2>/dev/null || true
    : > "$LOG"
    dump_state
    journalctl --sync 2>/dev/null || sync
    log "prep done: pm_debug_messages=1 pm_print_times=1, log at $LOG"
    log "next: 'sudo bash $0 level devices'  (or 'rtc 30' for the real thing)"
}

# One pm_test level.  Nothing here enters the s2idle loop on purpose: the
# kernel returns on its own, so a hang at this step is a driver problem.
do_level() {
    local lvl="${1:-}"
    case "$lvl" in
        freezer|devices|platform) ;;
        none) echo none > "$PWR/pm_test"; log "pm_test reset to none"; return 0 ;;
        *) die "usage: $0 level {freezer|devices|platform|none}" ;;
    esac
    need_root "$@"
    echo "$lvl" > "$PWR/pm_test"
    log "ATTEMPT level=$lvl $(cat $PWR/pm_test)"
    journalctl --sync 2>/dev/null || sync
    local t0 t1
    t0=$(date +%s)
    echo mem > "$PWR/state" || log "write to $PWR/state failed: $?"
    t1=$(date +%s)
    # we only get here if the kernel came back
    log "RESUMED level=$lvl after $((t1 - t0))s"
    dmesg | tail -25 >>"$LOG"
    echo
    echo "returned from level=$lvl in $((t1 - t0))s.  Device/platform path is clean at this level."
    echo "pm_test is still '$lvl' - reset with: sudo bash $0 level none"
}

# The real thing, with an RTC alarm armed so the machine can wake itself.
do_rtc() {
    local secs="${1:-30}"
    need_root "$@"
    echo none > "$PWR/pm_test"
    log "ATTEMPT rtc=${secs}s (pm_test=none, real s2idle)"
    journalctl --sync 2>/dev/null || sync
    local t0 t1
    t0=$(date +%s)
    if rtcwake -d rtc0 -m mem -s "$secs" >>"$LOG" 2>&1; then
        t1=$(date +%s)
        log "RESUMED rtc after $((t1 - t0))s"
        echo "returned after $((t1 - t0))s -> s2idle entry AND RTC wakeup both work."
    else
        log "rtcwake returned non-zero (see log)"
    fi
}

do_real() {
    need_root "$@"
    echo none > "$PWR/pm_test"
    log "ATTEMPT real (pm_test=none, no alarm armed) - this is the case that hangs"
    journalctl --sync 2>/dev/null || sync
    echo mem > "$PWR/state"
    log "RESUMED real"
}

report() {
    echo "=== marker log ($LOG)"; tail -40 "$LOG" 2>/dev/null || echo "(no log)"
    echo; echo "=== previous boot: PM: messages"
    journalctl -b -1 -k --no-pager 2>/dev/null | grep -E "PM: |suspend|s2idle|cpuidle|psci" | tail -40 || true
    echo; echo "=== previous boot: last kernel lines"
    journalctl -b -1 -k --no-pager 2>/dev/null | tail -30 || true
    echo; echo "=== pstore"
    ls -la /sys/fs/pstore/ 2>/dev/null
    for f in /sys/fs/pstore/*; do [ -f "$f" ] && { echo "--- $f"; tail -40 "$f"; }; done
}

case "${1:-}" in
    prep)      shift; prep "$@" ;;
    level)     shift; do_level "$@" ;;
    rtc)       shift; do_rtc "$@" ;;
    real)      shift; do_real "$@" ;;
    report)    report ;;
    *)         sed -n '2,40p' "$0"; exit 1 ;;
esac
