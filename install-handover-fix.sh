#!/usr/bin/env bash
# 手工装载补丁 0037 编出的 qcom_q6v5.ko（不重建内核包）。
#
# 背景：packages/linux-mibook-mainline/0037-*.patch 让 q6v5 的 handover IRQ
# 变成 one-shot，止住 SC8180X SLPI 每 200 ms 重发 handover 造成的
# "Handover signaled, but it already happened" 刷屏。
#
# rootfs 是 ro 挂载时脚本会临时 remount rw，退出时还原；需要 root 执行。
#
# 用法：
#   sudo ./install-handover-fix.sh          # 装模块 + depmod，然后重启生效
#   sudo ./install-handover-fix.sh --live   # 装模块 + depmod，并就地重启 remoteproc
#
# --live 会先 rmmod qcom_q6v5_pas，把 slpi/adsp/cdsp/modem 四个 remoteproc
# 停掉再拉起来（传感器栈会短暂中断），然后重载模块。如果重载失败，模块文件
# 已经装好，重启即可恢复。

set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# 内核包目录名跟着 pkgver 走，这里不写死版本
NEW_KO="$(ls -1 "$REPO"/packages/linux-mibook-mainline/src/linux-*/drivers/remoteproc/qcom_q6v5.ko 2>/dev/null | head -1 || true)"
KREL="$(uname -r)"
DEST_DIR="/lib/modules/$KREL/kernel/drivers/remoteproc"
DEST="$DEST_DIR/qcom_q6v5.ko"
BACKUP="$DEST.orig-$(date +%Y%m%d%H%M%S)"

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行（sudo $0 $*）" >&2; exit 1; }
[ -f "$NEW_KO" ] || {
    echo "找不到新模块。先在 packages/linux-mibook-mainline 里编一次（src/ 树需已应用补丁 0037）：" >&2
    echo "    make -C packages/linux-mibook-mainline/src/linux-* ARCH=arm64 \\" >&2
    echo "         CROSS_COMPILE=aarch64-linux-gnu- LD=/usr/bin/ld AR=/usr/bin/ar \\" >&2
    echo "         NM=/usr/bin/nm OBJCOPY=/usr/bin/objcopy STRIP=/usr/bin/strip \\" >&2
    echo "         READELF=/usr/bin/readelf drivers/remoteproc/qcom_q6v5.ko" >&2
    exit 1
}
echo "== 待装模块：$NEW_KO"

echo "== 校验新模块"
VERMAGIC="$(modinfo -F vermagic "$NEW_KO")"
echo "   vermagic: $VERMAGIC"
case "$VERMAGIC" in
    "$KREL "*) ;;
    *) echo "vermagic 与运行内核 $KREL 不匹配，停止。" >&2; exit 1;;
esac
if nm -u "$NEW_KO" | grep -qE '_(raw_spin_lock_irqsave|raw_spin_unlock_irqrestore)$'; then
    echo "   包含 one-shot 补丁的新符号（spinlock / synchronize_irq）"
else
    echo "   警告：模块里看不到补丁引入的符号，确认是不是编错了" >&2
fi

echo "== rootfs 只读，临时放开"
REMOUNTED=0
if findmnt -no OPTIONS / | grep -qE '(^|,)ro(,|$)'; then
    mount -o remount,rw /
    REMOUNTED=1
fi
trap '[ "$REMOUNTED" = 1 ] && mount -o remount,ro / || true' EXIT

echo "== 备份旧模块 -> $BACKUP"
cp -a "$DEST" "$BACKUP"

echo "== 安装新模块"
install -m 644 -o root -g root "$NEW_KO" "$DEST"

echo "== 刷新模块依赖"
depmod -a "$KREL"
modinfo "$DEST" | head -6

if [ "${1:-}" != "--live" ]; then
    echo
    echo "模块已装好。现在重启使新 qcom_q6v5 生效："
    echo "    sudo systemctl reboot"
    exit 0
fi

echo
echo "== 就地重载（会停掉 slpi/adsp/cdsp/modem 再拉起）"
for rp in /sys/class/remoteproc/remoteproc*; do
    [ -w "$rp/state" ] || continue
    echo "   $(cat "$rp/name"): $(cat "$rp/state") -> stop"
    echo stop > "$rp/state"
done

modprobe -r qcom_q6v5_pas qcom_q6v5 || true
modprobe qcom_q6v5_pas

echo "== 重新拉起 remoteproc"
for rp in /sys/class/remoteproc/remoteproc*; do
    [ -w "$rp/state" ] || continue
    if [ "$(cat "$rp/state")" = "offline" ]; then
        echo "   $(cat "$rp/name"): start"
        echo start > "$rp/state"
    fi
done

echo
echo "== 观察 10 秒 dmesg（不应再出现 Handover signaled）"
sleep 10
if dmesg | tail -200 | grep -q "Handover signaled"; then
    echo "   仍然出现 Handover signaled，看 dmesg 详情。" >&2
else
    echo "   OK：最近 200 行 dmesg 里没有 Handover signaled。"
fi
echo
echo "如需回退：cp -a $BACKUP $DEST && depmod -a $KREL && reboot"
