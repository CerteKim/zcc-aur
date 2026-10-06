#!/usr/bin/env bash
#
# maintainer/cleanup-stale-system-files.sh
#
# 清掉"手工时代"留在系统里的、现在要么已被包接管、要么纯属调试残留的文件。
# 默认只列出（dry-run），加 --apply 才真删。
#
# 适用场景：已经装好 zcc-aur 的
#   xiaomi-book-12.4-sensors / iio-sensor-proxy-ssc /
#   xiaomi-book-12.4-config / xiaomi-book-12.4-firmware / rmtfs
# 之后，清掉那些会**盖住**包内文件、或者已经没用的手工副本。
#
# 背景与逐条理由见仓库根目录的 SYSTEM-CONFIG.md。
#
# 用法:
#   sudo ./maintainer/cleanup-stale-system-files.sh            # 看看会删什么
#   sudo ./maintainer/cleanup-stale-system-files.sh --apply    # 真删

set -uo pipefail

APPLY=no
case "${1:-}" in
    --apply) APPLY=yes ;;
    ""|-n|--dry-run) APPLY=no ;;
    *) echo "用法: $0 [--apply]" >&2; exit 2 ;;
esac

if [[ ${EUID} -ne 0 ]]; then
    echo "需要 root：sudo $0 $*" >&2
    exit 1
fi

removed=0
kept=0

remove_file() {
    # $1 = 路径, $2 = 理由
    local path=$1 reason=$2
    if [[ ! -e $path && ! -L $path ]]; then
        return
    fi
    if [[ $APPLY == yes ]]; then
        rm -f -- "$path"
        echo "  删除 $path"
        echo "       $reason"
    else
        echo "  会删除 $path"
        echo "       $reason"
    fi
    removed=$((removed + 1))
}

remove_tree() {
    # $1 = 目录, $2 = 理由
    local path=$1 reason=$2
    if [[ ! -d $path ]]; then
        return
    fi
    if [[ $APPLY == yes ]]; then
        rm -rf -- "$path"
        echo "  删除 $path/"
        echo "       $reason"
    else
        echo "  会删除 $path/"
        echo "       $reason"
    fi
    removed=$((removed + 1))
}

echo "==> 1/4 覆盖包内文件的手工副本"
# 这些文件如果留着，systemd 会优先用 /etc 里的那份，包内的改动就不生效了。
remove_file /etc/systemd/system/hexagonrpcd-sdsp.path \
    "手抄的 path 单元会盖住 xiaomi-book-12.4-sensors 装的那份"
remove_file /etc/systemd/system/hexagonrpcd-sdsp.service.d/root.conf \
    "-R <registry root> 已经写进包内单元，drop-in 不再需要"
remove_file /etc/systemd/system/rmtfs.service \
    "rmtfs 包 (pkgrel>=2) 的单元就是 -r -s -o /var/lib/rmtfs"
remove_file /etc/systemd/system/ra9530-charge-policy.service \
    "手抄的单元会盖住 xiaomi-book-12.4-config 装到 /usr/lib/systemd/system/ 的那份（新版含停靠闸门）"
remove_file /etc/systemd/system/iio-sensor-proxy.service.d/exec.conf \
    "iio-sensor-proxy-ssc 直接顶替 /usr/lib/iio-sensor-proxy，不再用 /usr/local 那份"
remove_file /etc/initcpio/install/xiaomi-book124-firmware \
    "hook 已由 xiaomi-book-12.4-firmware 装到 /usr/lib/initcpio/install/"
remove_tree /usr/local/lib/iio-sensor-proxy \
    "打补丁的 proxy 现在装在 /usr/lib/iio-sensor-proxy"
remove_tree /usr/local/share/iio-sensor-proxy \
    "补丁随 iio-sensor-proxy-ssc 装到 /usr/share/doc/"
# udev 会优先用 /etc/udev/rules.d 里那份，手抄的三条会盖住包安装到
# /usr/lib/udev/rules.d 的同名规则（内容相同，但两份并存迟早不一致）。
remove_file /etc/udev/rules.d/90-fastrpc.rules \
    "已由 xiaomi-book-12.4-sensors 安装到 /usr/lib/udev/rules.d/"
remove_file /etc/udev/rules.d/91-fastrpc-sensors.rules \
    "同上（iio-sensor-proxy 的传感器类型）"
remove_file /etc/udev/rules.d/92-fastrpc-accel-matrix.rules \
    "同上（加速度计安装矩阵）"

echo
echo "==> 2/4 调试残留"
remove_file /etc/systemd/system/iio-sensor-proxy.service.d/debug.conf \
    "G_MESSAGES_DEBUG=all 是排查传感器时加的"
remove_file /etc/modprobe.d/vdec-probe.conf \
    "blacklist qcom-iris 是 VPU 探针调试留下的"

echo
echo "==> 3/4 旧包 / 旧变体的残留"
remove_file /etc/systemd/system/btmgmt.service \
    "蓝牙地址已在设备树里 (local-bd-address)，该单元早已 disabled+inactive"
remove_file /etc/mkinitcpio.d/linux-surface.preset.bak \
    "旧内核包残留"
remove_file /etc/mkinitcpio.d/linux-surface.preset.pacsave \
    "旧内核包残留"
for f in /boot/dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4-oc.dtb \
         /boot/dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4-oc.dtb.bak \
         /boot/dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4-oc.dtb.orig-ra9530 \
         /boot/dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4-parked.dtb \
         /boot/dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4-vdec-probe.dtb \
         /boot/dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4.dtb.bak; do
    remove_file "$f" "合并 .dts / 删掉 -oc 变体之后的残留"
done

echo
echo "==> 4/4 检查（不删除，只提示）"
if [[ -d /var/lib/rmtfs ]]; then
    echo "  /var/lib/rmtfs 保留（rmtfs 的 EFS 目录）"
    kept=$((kept + 1))
fi
if [[ -e /usr/local/bin/ra9530-charge-policy.sh ]]; then
    echo "  /usr/local/bin/ra9530-*.sh 保留（已由 xiaomi-book-12.4-config 按同一路径接管）"
    kept=$((kept + 1))
fi
if [[ -e /etc/sysctl.d/99-zram-tuning.conf ]]; then
    echo "  zram 调优保留（按维护者意愿不打包）"
    kept=$((kept + 1))
fi
if [[ -e ${SUDO_USER:+/home/$SUDO_USER}/.config/autostart/mutter-accelerometer-claim.desktop \
   || -e $HOME/.config/autostart/mutter-accelerometer-claim.desktop ]]; then
    echo "  mutter#4931 workaround 保留（用户会话级，见 SYSTEM-CONFIG.md 第 6 节）"
    kept=$((kept + 1))
fi

echo
if [[ $APPLY == yes ]]; then
    echo "==> 完成：删除 $removed 项"
    echo "    建议接着执行: sudo mkinitcpio -P"
else
    echo "==> dry-run：上面 $removed 项会被删除（$kept 项保留）"
    echo "    真正执行: sudo $0 --apply"
fi
