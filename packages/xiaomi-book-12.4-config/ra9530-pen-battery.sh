#!/usr/bin/env bash
#
# ra9530-pen-battery.sh — 通过 BLE 读 Xiaomi Smart Pen 的准确电量
#
# 背景：
#   * RA9530 充电器【从不上报】笔电量（irq_seen 里没有 bit15/CSP，已实测证实）；
#   * 触屏控制器的 HID 电量不准（会跳变）；
#   * 而笔自己是一个 BLE 外设，暴露标准的 Battery Service：
#         service0019/char001a = 00002a19 "Battery Level"  (read + notify)
#     这就是准确值。
#
# 注意：
#   * 笔的 BLE 地址是 **随机地址、会轮换** —— 所以本脚本按【名字】查找，不写死 MAC；
#   * 笔是睡眠型设备，容易掉线：脚本会先尝试连接，连上后立刻读；
#   * 读不到时试试让笔动一下（用它在屏幕上划、按按键）把它唤醒后重跑。
#
# 用法:
#   ./ra9530-pen-battery.sh              # 输出百分比数字
#   ./ra9530-pen-battery.sh --verbose    # 输出细节
#   NAME="Xiaomi Smart Pen" ./ra9530-pen-battery.sh

set -u

NAME=${NAME:-Xiaomi Smart Pen}
VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

log() { [[ $VERBOSE -eq 1 ]] && echo "$@" >&2; return 0; }
die() { echo "错误: $*" >&2; exit 1; }

command -v bluetoothctl >/dev/null || die "缺少 bluetoothctl（bluez-utils）"
command -v busctl      >/dev/null || die "缺少 busctl（systemd）"

# 1) 按名字找设备（地址会变，不能写死）
addr=$(bluetoothctl devices 2>/dev/null | awk -v n="$NAME" 'index($0,n){print $2; exit}')
if [[ -z "$addr" ]]; then
    echo "没找到 \"$NAME\"。先扫描一次（同时用笔在屏幕上划一下唤醒它）：" >&2
    echo "  bluetoothctl --timeout 25 scan on" >&2
    exit 1
fi
log "找到 $NAME -> $addr"
path="/org/bluez/hci0/dev_${addr//:/_}"

# 2) 未连接就先连
state=$(bluetoothctl info "$addr" 2>/dev/null | awk -F': ' '/Connected/{print $2}')
if [[ "$state" != "yes" ]]; then
    log "未连接，尝试连接 ..."
    bluetoothctl --timeout 25 connect "$addr" >/dev/null 2>&1
    state=$(bluetoothctl info "$addr" 2>/dev/null | awk -F': ' '/Connected/{print $2}')
fi
[[ "$state" == "yes" ]] || die "连不上（笔可能在睡觉：用它在屏幕上划一下再试；也确认手机 App 没有占着它）"
log "已连接"

# 2.4) 未绑定就先配对 —— 经验上「所有 GATT 读取都失败」的最常见原因就是
#      设备要求加密链路，而未配对时连 harmless 的特征也不让读，甚至直接掉线。
paired=$(bluetoothctl info "$addr" 2>/dev/null | awk -F': ' '/Bonded/{print $2}')
if [[ "$paired" != "yes" ]]; then
    log "尚未绑定，尝试配对（Just Works；若屏幕有提示请确认）..."
    bluetoothctl >/dev/null 2>&1 <<EOF
agent on
default-agent
pair $addr
trust $addr
EOF
    paired=$(bluetoothctl info "$addr" 2>/dev/null | awk -F': ' '/Bonded/{print $2}')
    log "配对后 Bonded=$paired"
    if [[ "$paired" != "yes" ]]; then
        echo "配对未成功 —— 请手动跑一次并把输出贴出来：" >&2
        echo "  bluetoothctl" >&2
        echo "  > agent on" >&2
        echo "  > default-agent" >&2
        echo "  > pair $addr" >&2
        echo "  > trust $addr" >&2
    fi
fi

# 2.5) 优先用 BlueZ 的 Battery1（设备【已绑定】时才会出现，最省事也最稳）
batt=$(busctl --system get-property org.bluez "$path" \
           org.bluez.Battery1 Percentage 2>/dev/null | awk '{print $2}')
if [[ "$batt" =~ ^[0-9]+$ ]]; then
    log "来自 org.bluez.Battery1"
    echo "$batt"
    exit 0
fi
log "没有 Battery1 接口（设备多半还没绑定/bonded），改为直接读 0x2A19"

# 3) 找到 Battery Level (0x2a19) 特征对象
char=""
while read -r p; do
    u=$(busctl --system get-property org.bluez "$p" \
             org.bluez.GattCharacteristic1 UUID 2>/dev/null | awk -F'"' '{print $2}')
    if [[ "$u" == "00002a19-0000-1000-8000-00805f9b34fb" ]]; then
        char="$p"; break
    fi
done < <(busctl --system tree org.bluez 2>/dev/null | grep -oE "${path}[a-zA-Z0-9/]*")
[[ -n "$char" ]] || die "找不到电量特征 0x2A19（GATT 还没枚举完？稍后重试）"
log "电量特征: $char"

# 4) 读值（返回形如: ay 1 96  -> 最后一个数字就是百分比）
# 笔空闲时会掉线：连上后立刻反复重试，并允许重新连接
out=""; pct=""
for round in 1 2 3; do
    for try in 1 2 3 4 5 6 7 8; do
        out=$(busctl --system call org.bluez "$char" \
                  org.bluez.GattCharacteristic1 ReadValue 'a{sv}' 0 2>&1) && {
            pct=$(awk '{print $NF}' <<<"$out")
            [[ "$pct" =~ ^[0-9]+$ ]] && break 2
        }
        sleep 0.2
    done
    log "第 $round 轮失败（$out），重新连接再试 ..."
    bluetoothctl --timeout 20 connect "$addr" >/dev/null 2>&1
done
[[ "$pct" =~ ^[0-9]+$ ]] || {
    echo "读取失败（最后一轮: $out）" >&2
    echo "这笔是睡眠型设备，空闲即掉线。建议：" >&2
    echo "  1) 先【配对】：bluetoothctl -> agent on; default-agent; pair <MAC>; trust <MAC>" >&2
    echo "     绑定后 BlueZ 会建 Battery1，读起来就稳了（本脚本会自动优先用它）" >&2
    echo "  2) 或读的时候用笔在屏幕上划，让它保持活跃" >&2
    exit 1
}

log "原始返回: $out"
# 只输出数字，便于脚本使用
echo "$pct"
