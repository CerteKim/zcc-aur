#!/usr/bin/env bash
#
# maintainer/make-mibook-usb.sh — 做一支本机能引导的 Xiaomi Book S 12.4 U 盘
#
# 为什么不能直接用现成的 archiso/ALARM 镜像：本机固件是 Windows 那套 ACPI 固件，
# **不提供设备树**，而 ALARM 的 grub 包自己构建的核在本机起不来（详见
# ~/grub-spx-backup/README.md）。唯一验证过能引导的 UEFI loader 是从 linux-surface
# 的 Surface Pro X 镜像里拷出来的那个 GRUB 核（245760 字节）。这支 U 盘就带着
# 那一份核，内嵌 prefix 是 (,gpt1)/grub，所以布局必须是：
#
#   p1  FAT32  MIBOOK_ESP   <- /EFI/BOOT/BOOTAA64.EFI + /grub/{grub.cfg,arm64-efi/}
#                              + vmlinuz + initramfs + dtb
#   p2  ext4   MIBOOK_ROOT  <- live 系统的根（可选，--live 时才有内容）
#
# 默认只做 p1（**救援盘**：不管内部 ESP 出什么事都能进系统）。加 --live 会额外
# pacstrap 一个精简系统到 p2，做成真正的 live U 盘。
#
# 用法:
#   sudo ./maintainer/make-mibook-usb.sh /dev/sdX              # 救援盘（默认）
#   sudo ./maintainer/make-mibook-usb.sh /dev/sdX --dry-run    # 只打印要做的事
#   sudo ./maintainer/make-mibook-usb.sh /dev/sdX --yes        # 不交互确认
#   sudo ./maintainer/make-mibook-usb.sh /dev/sdX --live [...]  # 额外做 live 根
#
# 注意：**会清空目标设备**。脚本会拒绝内部 NVMe、已挂载的设备、以及根文件系统。

set -euo pipefail

ESP_SIZE_MB=${ESP_SIZE_MB:-1536}
STAGE=${STAGE:-$HOME/mibook-usb}
GRUB_BACKUP=${GRUB_BACKUP:-$HOME/grub-spx-backup}
LIVE=no
DRY_RUN=no
ASSUME_YES=no
PKGDIR=${PKGDIR:-$HOME/zcc-aur/repo}
KERNEL_PKG=${KERNEL_PKG:-}

DEV=${1:-}
shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --live)     LIVE=yes ;;
        --dry-run)  DRY_RUN=yes ;;
        --yes|-y)   ASSUME_YES=yes ;;
        --stage)    STAGE=$2; shift ;;
        --pkgdir)   PKGDIR=$2; shift ;;
        --kernel)   KERNEL_PKG=$2; shift ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
    shift
done

[[ -n $DEV ]] || { sed -n '2,30p' "$0"; exit 2; }

msg()  { echo "==> $*"; }
run()  {
    if [[ $DRY_RUN == yes ]]; then
        echo "    [dry-run] $*"
    else
        echo "    + $*"
        "$@"
    fi
}

# ---------------------------------------------------------------- 前置检查
# --dry-run 只打印命令，不写盘，所以不要求 root（blkid 之类的只读调用会跳过）
if [[ $DRY_RUN == no ]]; then
    [[ $EUID -eq 0 ]] || { echo "需要 root：sudo $0 $DEV ${LIVE:+--live}" >&2; exit 1; }
fi
[[ -b $DEV ]] || { echo "$DEV 不是块设备" >&2; exit 1; }

# 整盘（不是分区）
if [[ -e /sys/class/block/$(basename "$DEV")/partition ]]; then
    echo "$DEV 是一个分区，需要整个磁盘（例如 /dev/sdb 而不是 /dev/sdb1）" >&2
    exit 1
fi

# 不能是根/关键挂载所在的盘，也不能是内部 NVMe
root_src=$(findmnt -no SOURCE / || true)
root_disk=$(lsblk -no pkname "$root_src" 2>/dev/null | head -1 || true)
if [[ -n $root_disk && "/dev/$root_disk" == "$DEV" ]]; then
    echo "拒绝：$DEV 上挂着根文件系统" >&2
    exit 1
fi
case "$DEV" in
    /dev/nvme*|/dev/mmcblk*)
        echo "拒绝：$DEV 看起来是内部设备（NVMe / eMMC / SD），不是 U 盘" >&2
        echo "      要强制使用请自己手动分区" >&2
        exit 1 ;;
esac
if lsblk -no MOUNTPOINT "$DEV" | grep -q .; then
    echo "拒绝：$DEV 上有分区已挂载，先 umount" >&2
    exit 1
fi

[[ -d $STAGE/esp/grub/arm64-efi ]] || {
    echo "找不到暂存目录 $STAGE/esp（应包含 EFI/BOOT/BOOTAA64.EFI 与 grub/）" >&2
    echo "用 maintainer/stage-mibook-usb.sh 先生成，或用 --stage 指定" >&2
    exit 1
}
[[ -f $STAGE/esp/EFI/BOOT/BOOTAA64.EFI ]] || { echo "$STAGE/esp/EFI/BOOT/BOOTAA64.EFI 缺失" >&2; exit 1; }

# 确认这份核就是验证过能引导的那份
core_sha=$(sha256sum "$STAGE/esp/EFI/BOOT/BOOTAA64.EFI" | awk '{print $1}')
if [[ -f $GRUB_BACKUP/SHA256SUMS ]]; then
    if grep -q "$core_sha" "$GRUB_BACKUP/SHA256SUMS"; then
        msg "GRUB 核校验通过（$core_sha）"
    else
        echo "!! 注意：$STAGE/esp/EFI/BOOT/BOOTAA64.EFI 的 sha256 ($core_sha)" >&2
        echo "   不在 $GRUB_BACKUP/SHA256SUMS 里 —— 这不是备份里那份能引导的核！" >&2
        [[ $ASSUME_YES == yes ]] || { read -r -p "继续？(yes/NO) " a; [[ $a == yes ]] || exit 1; }
    fi
fi

echo
echo "目标设备 : $DEV  ($(lsblk -dno SIZE,MODEL "$DEV" 2>/dev/null | xargs))"
echo "ESP 大小 : ${ESP_SIZE_MB} MiB (FAT32)"
echo "live 根  : $([[ $LIVE == yes ]] && echo '是（会 pacstrap 到 p2）' || echo '否（只做救援盘）')"
if [[ $DRY_RUN == no && $ASSUME_YES == no ]]; then
    read -r -p "这会清空 $DEV 上的所有数据，继续？(yes/NO) " a
    [[ $a == yes ]] || { echo "已取消"; exit 1; }
fi

# ---------------------------------------------------------------- 分区与格式化
msg "分区（GPT：p1 = ${ESP_SIZE_MB}M ESP，p2 = 其余）"
run wipefs -a "$DEV"
run sgdisk --zap-all "$DEV"
run sgdisk -n "1:0:+${ESP_SIZE_MB}M" -t 1:ef00 -c 1:MIBOOK_ESP \
           -n 2:0:0               -t 2:8300 -c 2:MIBOOK_ROOT "$DEV"
run partprobe "$DEV"
run udevadm settle

esp=${DEV}1
root=${DEV}2
if [[ $DEV == *[0-9] ]]; then esp=${DEV}p1; root=${DEV}p2; fi

run mkfs.vfat -F32 -n MIBOOK_ESP "$esp"
run mkfs.ext4 -q -L MIBOOK_ROOT "$root"

# ---------------------------------------------------------------- p1：启动文件
ESPMNT=$(mktemp -d)
msg "写入启动文件到 $esp"
run mount "$esp" "$ESPMNT"
run cp -a "$STAGE/esp/." "$ESPMNT/"
if [[ $DRY_RUN == no ]]; then
    usb_root_uuid=$(blkid -s UUID -o value "$root")
    sed -i "s/@USB_ROOT_UUID@/$usb_root_uuid/" "$ESPMNT/grub/grub.cfg"
    echo "    live 根 UUID = $usb_root_uuid（已写入 grub.cfg）"
fi
run sync
run umount "$ESPMNT"
rmdir "$ESPMNT" 2>/dev/null || true

# ---------------------------------------------------------------- p2：live 系统（可选）
if [[ $LIVE == yes ]]; then
    ROOTMNT=$(mktemp -d)
    msg "pacstrap live 系统到 $root"
    run mount "$root" "$ROOTMNT"

    # 目标系统用 host 的 pacman 配置，但去掉 host 上那个坏掉的 [aur] 段
    tmppac=$(mktemp)
    awk '/^\[aur\]/{skip=1} /^\[/{if ($0 !~ /^\[aur\]/) skip=0} !skip' /etc/pacman.conf > "$tmppac"

    base_pkgs=(base)
    run pacstrap -C "$tmppac" "$ROOTMNT" "${base_pkgs[@]}"

    msg "安装本仓库的包（zcc-aur 的 repo/ 与本机内核包）"
    if [[ -z $KERNEL_PKG ]]; then
        KERNEL_PKG=$(ls -1 "$HOME"/aarch64-packages/linux-surface/linux-mibook-*.pkg.tar.* 2>/dev/null | sort -V | tail -1 || true)
    fi
    [[ -n $KERNEL_PKG && -f $KERNEL_PKG ]] || {
        echo "找不到 linux-mibook 包；用 --kernel <文件> 指定（先构建/或使用已有产物）" >&2
        exit 1
    }
    run cp "$KERNEL_PKG" "$ROOTMNT/root/"
    shopt -s nullglob
    for p in "$PKGDIR"/*.pkg.tar.*; do
        run cp "$p" "$ROOTMNT/root/"
    done
    shopt -u nullglob

    # /boot 就是 p1，和装好的系统一样
    run mkdir -p "$ROOTMNT/boot"
    run mount "$esp" "$ROOTMNT/boot"

    msg "在 chroot 里装包（pacman -U）"
    pkgs=(/root/linux-mibook-*.pkg.tar.* /root/xiaomi-book-12.4-*.pkg.tar.*
          /root/iio-sensor-proxy-ssc-*.pkg.tar.* /root/ra9530-dkms-*.pkg.tar.*
          /root/rmtfs-*.pkg.tar.* /root/panel-himax-hx83121a-dkms-*.pkg.tar.*)
    run arch-chroot "$ROOTMNT" /bin/bash -c "pacman -U --noconfirm --overwrite '*LIBINPUT*' ${pkgs[*]}"

    msg "写 mkinitcpio 配置并生成 live initramfs（顺带把 U 盘自己的 /boot 填上）"
    run arch-chroot "$ROOTMNT" /bin/bash -c '
        set -e
        sed -i "s|^HOOKS=.*|HOOKS=(base systemd autodetect microcode modconf xiaomi-book124-firmware kms keyboard sd-vconsole block filesystems fsck)|" /etc/mkinitcpio.conf
        install -Dm644 /usr/lib/initcpio/install/xiaomi-book124-firmware /etc/initcpio/install/xiaomi-book124-firmware 2>/dev/null || true
        mkinitcpio -P
    '

    run sync
    run umount "$ROOTMNT/boot"
    run umount "$ROOTMNT"
    rmdir "$ROOTMNT" 2>/dev/null || true
    rm -f "$tmppac"
fi

echo
msg "完成。$DEV 现在应该能从 UEFI 启动菜单进入 GRUB（固件菜单里选 USB 设备，"
echo "    或默认走 \\EFI\\BOOT\\bootaa64.efi）。"
echo
echo "接着请人工验证（这决定后面值不值得做完整 ISO）："
echo "  1) 断电插上 U 盘，开机进固件 boot menu，选 USB / UEFI: SanDisk ...；"
echo "  2) 应看到 GRUB 菜单，先选【用本 U 盘上的内核 / 救援用】；"
echo "  3) 起来了说明整条链 OK：固件 -> USB ESP -> 我们的 GRUB 核 -> devicetree -> 内核。"
echo
echo "若进不了菜单，问题只可能在两处：固件不肯从 USB 引导（换端口/换盘试），"
echo "或 GRUB 核的 prefix 找不到 /grub/grub.cfg（确认 p1 是 FAT 且含 /grub/）。"
