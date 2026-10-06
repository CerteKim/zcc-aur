#!/usr/bin/env bash
#
# ra9530-charge-policy.sh — RA9530 磁吸笔的守护进程，一个进程管两件事：
#
#   1) 充电策略：用笔的 BLE 电量控制 RA9530 充电（防止长期满电搁置）
#   2) 停靠闸门：笔吸在磁吸位上时，屏蔽数字化仪当成"悬停"上报的笔事件
#
# 【为什么需要 2】
#   磁吸位就在感应区内、屏幕左侧偏上（换算到桌面大约 2560x1600 上的 (103, 515)）。
#   吸附中的笔会被 HID-over-I2C 数字化仪的 Stylus 集合（0018:4858:121A @ i2c-0/0x4f，
#   即 /dev/input/event10）当成"悬停"反复上报；udev 把它标成 ID_INPUT_TABLET，而
#   GNOME/mutter 对 tablet tool 是**绝对定位并直接 warp 光标** —— 于是光标一次次
#   被拽到磁吸位那个点。
#   实测（停靠时 30 秒 evtest）：event10 有多次 BTN_TOOL_PEN 1→0 的进出，坐标恒定在
#   原生 (≈10850, 1030)，而触摸屏 event9 与触控板 event4 全程 0 事件 —— 只有它在上报。
#   触摸在 Wayland 下不搬光标，所以这个现象只能是笔造成的。
#
#   屏蔽用内核现成的 /sys/class/input/inputN/inhibited：input_get_disposition() 里
#   直接 filter-out（drivers/input/input.c），不会关掉 gnome-shell 已经打开的 evdev
#   fd，解除后立刻恢复，且抑制时会正经地把 BTN_TOOL_PEN 放开（EVIOCGRAB 做不到，
#   会让 libinput 一直以为笔还在 proximity，连 touch 仲裁也一起挂着）。
#
# 【逻辑 1：充电】
#   电量 >= HIGH  -> 写 enabled=0 停充
#   电量 <= LOW   -> 写 enabled=1 恢复
#   读不到电量（笔在睡觉/断连）-> 保持现状，什么都不做（驱动侧该停的已经停了）
#   依据：参考驱动 idtp9418 用 LIMIT_SOC 85；本机实测充电器 0x003A 从不上报电量
#   （无 CSP 中断），触屏 HID 电量不准，而笔自己的 BLE Battery Level（0x2A19）准确
#   —— 绑定后 BlueZ 暴露 org.bluez.Battery1，读数可靠。且实测【满电的笔仍会报告
#   rpp≈30】，所以驱动里那套"rpp≈0 判满"在这支笔上不会触发，策略必须由电量驱动。
#
# 【逻辑 2：停靠闸门】
#   pen_present == 1（吸附）-> stylus 的 inhibited=1
#   pen_present == 0（取下）-> inhibited=0，笔恢复正常输入
#   读不到 pen_present（驱动没加载）-> 什么都不做，宁可留着笔可用
#   每一拍都按 sysfs 里的实际值对账，所以设备重新探测（HID 复位 / 挂起恢复）
#   之后也能自动把屏蔽补回来；反过来，手工写 0 也会被下一拍改回 1（这是一条策略，
#   要停就停服务）。
#
#   已知延迟：驱动的 chg->pen_present 只在 5 秒一次的 monitor work 里更新
#   （ra9530_monitor_work()，RA9530_MONITOR_MS），IRQ 路径不更新，所以这个闸门
#   的进出最多滞后约 5 秒。想更快得在驱动侧把状态更新挪进 IRQ 路径，或者给
#   pen_present 加 sysfs_notify()。
#
#   现在两者都做了（驱动 >= 1.0.3）：两个霍尔脚各有一个双边沿中断，跳变时
#   ra9530_pen_update() 立刻回写 pen_present 并 sysfs_notify()。所以闸门改成
#   **阻塞等通知**，不再每秒读一次：
#     python3 ra9530-charge-policy-wait.py <pen_present> | apply_gate...
#   等待器只请求 POLLPRI（见它自己的注释：请求 POLLIN 会让 poll 立刻返回），
#   唤醒后 seek+read 重新武装。没有 python3 时退回 TICK 秒对账一次（用 bash 内建
#   read -t，不 fork）；即使驱动是旧版，TICK=1 也保证不比以前慢。
#
# 用法:
#   ./ra9530-charge-policy.sh                 # 前台跑（Ctrl-C 停）
#   HIGH=85 LOW=75 INTERVAL=120 ./ra9530-charge-policy.sh
#   sudo systemctl enable --now ra9530-charge-policy   # 用附带的 service
#   ./ra9530-charge-policy.sh --release       # 只放开笔输入（单元的 ExecStopPost）
#
# 依赖：ra9530-pen-battery.sh（读电量）、RA9530 驱动（enabled / pen_present 属性）、
#       可选 python3（事件驱动等待器；没有就退回轮询）

set -u

HERE=$(dirname "$(readlink -f "$0")")
BATT_SH=${BATT_SH:-$HERE/ra9530-pen-battery.sh}
ENABLED=${ENABLED:-/sys/bus/i2c/devices/1-003b/enabled}
PEN_PRESENT=${PEN_PRESENT:-/sys/bus/i2c/devices/1-003b/pen_present}
STYLUS_NAME=${STYLUS_NAME:-hid-over-i2c 4858:121A Stylus}
INPUT_CLASS=${INPUT_CLASS:-/sys/class/input}   # 只影响找节点，便于测试
NAME=${NAME:-Xiaomi Smart Pen}
HIGH=${HIGH:-85}
LOW=${LOW:-75}
INTERVAL=${INTERVAL:-120}      # 充电策略周期（秒）
TICK=${TICK:-1}                # 停靠闸门兜底对账周期（秒）
WAITER=${WAITER:-$HERE/ra9530-charge-policy-wait.py}
RUNDIR=${RUNDIR:-${RUNTIME_DIRECTORY:-/tmp}}   # systemd 会设 RUNTIME_DIRECTORY
EVENTS=${EVENTS:-$RUNDIR/ra9530-pen-events}

log() { printf '%(%F %T)T [policy] %s\n' -1 "$*"; }

# ---------------------------------------------------------------- 停靠闸门

# 按设备名找数字化仪的 Stylus 输入节点：inputN 的编号每次开机都可能变，
# 所以不能写死 input15。
stylus_inhibit_path() {
    local d name
    for d in "$INPUT_CLASS"/input*/; do
        [[ -r "$d/name" && -w "$d/inhibited" ]] || continue
        name=""
        read -r name 2>/dev/null < "$d/name"
        if [[ "$name" == "$STYLUS_NAME" ]]; then
            printf '%s' "${d%/}/inhibited"
            return 0
        fi
    done
    return 1
}

release_gate() {
    local path=$1 cur=""
    [[ -n "$path" && -w "$path" ]] || return 0
    read -r cur 2>/dev/null < "$path"
    if [[ "$cur" == "1" ]]; then
        echo 0 > "$path" 2>/dev/null && log "解除笔输入屏蔽（$path）"
    fi
}

# --release：给单元的 ExecStopPost 用。进程被 SIGKILL 时 trap 不会跑，靠这条兜底，
# 免得服务死了、笔却一直被屏蔽着。
if [[ "${1:-}" == "--release" ]]; then
    p=$(stylus_inhibit_path) || p=""
    release_gate "$p"
    exit 0
fi

[[ -x "$BATT_SH" ]] || { echo "找不到 $BATT_SH" >&2; exit 1; }

GATE_PATH=$(stylus_inhibit_path) || GATE_PATH=""
GATE_WARNED=no
GATE_WRITE_WARNED=no

# 每一拍都跟 sysfs 里的实际值对账，而不是记一个"我以为已经写进去了"的状态：
# 设备重新探测（HID 复位、挂起恢复）会给出一个 inhibited=0 的新节点，记状态的
# 话就再也不会把它补回来，光标又会开始闪。
#
# 热路径故意用 bash 内建 read 而不是 $(cat ...)：后者每拍 fork/exec 两次，实测在
# 这个 SoC 上 1 Hz 就要吃掉约 2% 的一个核；内建 read 约 1 ms/拍。
apply_gate() {
    local present="" want cur=""
    read -r present 2>/dev/null < "$PEN_PRESENT"
    case "$present" in 0|1) ;; *) return 0 ;; esac   # 读不到吸附状态就不动笔
    want=$present                                    # 吸附(1) → 屏蔽(1)

    if [[ -z "$GATE_PATH" || ! -w "$GATE_PATH" ]]; then
        GATE_PATH=$(stylus_inhibit_path) || GATE_PATH=""
    fi
    if [[ -z "$GATE_PATH" ]]; then
        if [[ "$GATE_WARNED" == no ]]; then
            log "找不到 \"$STYLUS_NAME\" 的输入节点，暂不屏蔽笔输入"
            GATE_WARNED=yes
        fi
        return 0
    fi
    GATE_WARNED=no

    read -r cur 2>/dev/null < "$GATE_PATH"
    [[ "$cur" == "$want" ]] && return 0

    if echo "$want" > "$GATE_PATH" 2>/dev/null; then
        GATE_WRITE_WARNED=no
        if [[ "$want" == 1 ]]; then
            log "笔已吸附 → 屏蔽笔输入（$GATE_PATH），避免光标被拽到磁吸位"
        else
            log "笔已取下 → 恢复笔输入"
        fi
    elif [[ "$GATE_WRITE_WARNED" == no ]]; then
        log "写 $GATE_PATH 失败，下一拍重试"
        GATE_WRITE_WARNED=yes
    fi
}

# 事件等待器把每个通知写进一个 fifo，这里用内建 read -t 等它：等事件或 TICK 秒
# 超时都不 fork。而且 bash 在 read -t 上能被信号打断（trap 立刻执行）——前台管道
# 做不到这点（试过：trap 会被推迟到管道结束，结果退出时笔没放开、等待器还留着）。
gate_loop() {
    apply_gate             # 启动就落实当前状态：开机时笔往往已经吸着

    rm -f "$EVENTS"
    if [[ -f "$WAITER" ]] && command -v python3 >/dev/null 2>&1 &&
       mkfifo "$EVENTS" 2>/dev/null; then
        local t0 line
        exec 9<>"$EVENTS"      # 读写都握着，所以 read 永远看不到 EOF
        while :; do
            t0=$SECONDS
            python3 "$WAITER" "$PEN_PRESENT" >&9 &
            WAITER_PID=$!
            log "停靠闸门：等 pen_present 的通知（兜底每 ${TICK}s 对账一次）"
            while kill -0 "$WAITER_PID" 2>/dev/null; do
                apply_gate
                read -t "$TICK" -r -u 9 line
            done
            wait "$WAITER_PID" 2>/dev/null
            WAITER_PID=""
            apply_gate
            if (( SECONDS - t0 < 2 )); then
                log "事件等待器起不来，5 秒后重试（期间靠兜底对账）"
                sleep 5
            else
                sleep "$TICK"
            fi
        done
    fi

    log "没有 python3 / 等待器 / fifo：停靠闸门退回每 ${TICK}s 对账"
    while :; do
        sleep "$TICK"
        apply_gate
    done
}

# ---------------------------------------------------------------- 充电策略

CHG_STATE=""         # 最近一次我们做过的动作: on / off / ""
CHG_WARNED=no

run_charge_policy() {
    local pct

    if [[ ! -w "$ENABLED" ]]; then
        if [[ "$CHG_WARNED" == no ]]; then
            log "找不到可写的 $ENABLED（驱动没加载？），跳过充电策略"
            CHG_WARNED=yes
        fi
        return 0
    fi
    CHG_WARNED=no

    pct=$("$BATT_SH" 2>/dev/null | tail -1)

    if [[ "$pct" =~ ^[0-9]+$ ]]; then
        if (( pct >= HIGH )) && [[ "$CHG_STATE" != "off" ]]; then
            echo 0 > "$ENABLED" 2>/dev/null && {
                log "笔电量 ${pct}% ≥ ${HIGH}% → 停止充电"
                CHG_STATE="off"
            }
        elif (( pct <= LOW )) && [[ "$CHG_STATE" != "on" ]]; then
            echo 1 > "$ENABLED" 2>/dev/null && {
                log "笔电量 ${pct}% ≤ ${LOW}% → 恢复充电"
                CHG_STATE="on"
            }
        else
            log "笔电量 ${pct}%（区间 ${LOW}-${HIGH}%，保持 ${CHG_STATE:-默认}）"
        fi
    else
        log "读不到电量（笔可能在睡觉/未连接/未绑定），保持现状"
    fi
}

# 充电那条路要读蓝牙（笔睡着时会连着重试，可能阻塞几十秒），所以放后台独立周期，
# 免得把 1 秒一次的停靠闸门一起卡住。
charge_loop() {
    while :; do
        run_charge_policy
        sleep "$INTERVAL"
    done
}

# ---------------------------------------------------------------- main

CHARGE_PID=""
WAITER_PID=""

cleanup() {
    local p
    trap - INT TERM EXIT
    for p in "$CHARGE_PID" "$WAITER_PID"; do
        if [[ -n "$p" ]]; then
            kill "$p" 2>/dev/null
            wait "$p" 2>/dev/null
        fi
    done
    release_gate "$GATE_PATH"
    rm -f "$EVENTS" 2>/dev/null
    log "退出"
    exit 0
}

trap cleanup INT TERM EXIT

log "启动：充电策略 ${LOW}-${HIGH}%（每 ${INTERVAL}s），停靠闸门每 ${TICK}s"
charge_loop &
CHARGE_PID=$!
gate_loop
