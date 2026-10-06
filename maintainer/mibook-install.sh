#!/usr/bin/env bash
#
# mibook-install.sh — Xiaomi Book S 12.4：修复启动链 / 安装系统
#
# 这个脚本随 live U 盘提供。它存在的理由很具体：本机固件不提供设备树，而
# ALARM 的 grub 包构建出来的核在本机**起不来**；唯一能引导的是
# /boot/EFI/arch/grubaa64.efi 那一份（245760 字节，sha256
# 204b6d8913d249c331ac13d689644f9342d8df7491fed0a9435b263d10a827ca）。
# 因此**任何**正常安装流程里的 grub-install 都会让机器无法启动。
# 这个脚本按本机唯一可行的形状把启动链摆回去。
#
# 模式:
#   --status                    只看现状（默认）
#   --repair-esp                把 GRUB 核 + 模块 + 内核 + initramfs + DTB + grub.cfg
#                               写回内部 ESP（自动找 nvme 上的 EFI 分区）
#   --install-root <分区>       把 live 系统装到指定根分区（**尚未实现**，见文件末尾）
#
# 参数:
#   --esp <分区>                指定内部 ESP（默认自动探测）
#   --root-part <分区>          指定内部系统根分区（默认从旧 grub.cfg 的 root=UUID= 读，
#                               读不到就探测最大的 btrfs/ext4 分区）
#   --disk <磁盘>               内部磁盘（默认 /dev/nvme0n1）
#   --yes                       不交互确认
#
# 从 live U 盘启动后：
#   sudo mibook-install.sh --status
#   sudo mibook-install.sh --repair-esp

set -euo pipefail

KNOWN_CORE_SHA=204b6d8913d249c331ac13d689644f9342d8df7491fed0a9435b263d10a827ca
ESP_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b

MODE=status
DISK=/dev/nvme0n1
ESPDEV=
ROOTDEV=
ASSUME_YES=no

while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)       MODE=status ;;
        --repair-esp)   MODE=repair ;;
        --install-root) MODE=install; ROOTDEV=$2; shift ;;
        --esp)          ESPDEV=$2; shift ;;
        --root-part)    ROOTDEV=$2; shift ;;
        --disk)         DISK=$2; shift ;;
        --yes|-y)       ASSUME_YES=yes ;;
        -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
    shift
done

msg() { echo "==> $*"; }
die() { echo "!! $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "需要 root：sudo $0 $*"

# ---------------------------------------------------------------- live 介质自检
# 从 U 盘启动时 /boot 就是 U 盘的 ESP，所以这些东西都在 /boot 上
SRC=/boot
for f in EFI/BOOT/BOOTAA64.EFI grub/arm64-efi vmlinuz-linux-mibook \
         initramfs-linux-mibook.img dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4.dtb; do
    [[ -e $SRC/$f ]] || die "$SRC/$f 不存在 —— 这个脚本要在 live U 盘上跑（--status 也一样）"
done

src_core_sha=$(sha256sum "$SRC/EFI/BOOT/BOOTAA64.EFI" | awk '{print $1}')
if [[ $src_core_sha == "$KNOWN_CORE_SHA" ]]; then
    msg "U 盘上的 GRUB 核是验证过能引导的那份 ✓"
else
    echo "!! U 盘上的 GRUB 核 sha256 = $src_core_sha" >&2
    echo "   期望 $KNOWN_CORE_SHA —— 这不是本机能引导的那份，停下来。" >&2
    exit 1
fi

# ---------------------------------------------------------------- 目标探测
[[ -b $DISK ]] || die "$DISK 不是块设备（内部磁盘默认 /dev/nvme0n1）"

parttype() { lsblk -lno PARTTYPE "$1" 2>/dev/null | head -1; }

if [[ -z $ESPDEV ]]; then
    while read -r name; do
        dev=/dev/$name
        if [[ $(parttype "$dev") == "$ESP_TYPE" ]]; then ESPDEV=$dev; break; fi
    done < <(lsblk -lno NAME "$DISK" | tail -n +2)
fi
[[ -n $ESPDEV && -b $ESPDEV ]] || die "在 $DISK 上找不到 EFI 分区（用 --esp 指定）"

espmnt=$(mktemp -d)
mountpoint -q "$espmnt" && umount "$espmnt"
mount "$ESPDEV" "$espmnt"
cleanup() { umount "$espmnt" 2>/dev/null || true; rmdir "$espmnt" 2>/dev/null || true; }
trap cleanup EXIT

# 内部根分区：优先从现有 grub.cfg 里的 root=UUID= 反查
if [[ -z $ROOTDEV && -f $espmnt/grub/grub.cfg ]]; then
    uuid=$(grep -oE 'root=UUID=[0-9a-fA-F-]{36}' "$espmnt/grub/grub.cfg" | head -1 | cut -d= -f3 || true)
    [[ -n $uuid ]] && ROOTDEV=$(blkid -U "$uuid" 2>/dev/null || true)
fi
if [[ -z $ROOTDEV ]]; then
    # 退而求其次：内部磁盘上最大的 btrfs/ext4 分区
    while read -r name fstype size; do
        case "$fstype" in btrfs|ext4) ROOTDEV=/dev/$name ;; esac
    done < <(lsblk -lno NAME,FSTYPE,SIZE "$DISK" | tail -n +2 | sort -k3 -h)
fi

# ---------------------------------------------------------------- 现状
msg "内部磁盘 : $DISK"
msg "内部 ESP  : $ESPDEV  (挂载于 $espmnt)"
if [[ -n $ROOTDEV ]]; then
    msg "内部根    : $ROOTDEV  UUID=$(blkid -s UUID -o value "$ROOTDEV" 2>/dev/null || echo '?')"
else
    msg "内部根    : 没找到（repair 时会只装启动链，条目里用占位 UUID）"
fi
echo
echo "    ESP 现有的启动文件:"
ls -la "$espmnt/EFI/arch/" "$espmnt/EFI/Boot/" 2>/dev/null | sed 's/^/      /' || true
if [[ -f $espmnt/grub/grub.cfg ]]; then
    echo "    ESP 现有 grub.cfg 的 devicetree 行:"
    grep -n 'devicetree' "$espmnt/grub/grub.cfg" | sed 's/^/      /' || echo "      （没有！这就是起不来的原因之一）"
fi
echo
echo "    固件启动项:"
efibootmgr -v 2>/dev/null | grep -iE '^Boot|arch' | sed 's/^/      /' || echo "      （efibootmgr 读不到）"

if [[ $MODE == status ]]; then
    echo
    msg "只检查不修改。修启动链：sudo $0 --repair-esp"
    exit 0
fi

if [[ $MODE == install ]]; then
    cat >&2 <<'EOF'
!! --install-root 还没实现。

现在能安全自动做的是「修启动链」：--repair-esp

要装/重装根分区，按下面走（都在 live 系统里）：

  # 1) 准备根分区（会清空该分区！）
  mkfs.btrfs -L MIBOOK /dev/nvme0n1pX      # 或 mkfs.ext4
  mkdir -p /mnt && mount /dev/nvme0n1pX /mnt

  # 2) 用本机缓存里的包 pacstrap（离线可用）
  umount /mnt/boot 2>/dev/null || true
  mount <内部ESP> /mnt/boot                 # 让内核/initramfs 直接落到 ESP
  pacstrap -c -C /etc/pacman.conf /mnt base
  arch-chroot /mnt pacman -U /var/cache/mibook/linux-mibook-*.pkg.tar.* \
        /var/cache/mibook/xiaomi-book-12.4-*.pkg.tar.* \
        /var/cache/mibook/iio-sensor-proxy-ssc-*.pkg.tar.* \
        /var/cache/mibook/qrtr-*.pkg.tar.* /var/cache/mibook/qmic-*.pkg.tar.* \
        /var/cache/mibook/pd-mapper-*.pkg.tar.* /var/cache/mibook/rmtfs-*.pkg.tar.* \
        /var/cache/mibook/tqftpserv-*.pkg.tar.*

  # 3) fstab / 用户 / mkinitcpio（HOOKS 里要有 xiaomi-book124-firmware）
  genfstab -U /mnt >> /mnt/etc/fstab
  arch-chroot /mnt bash -c 'passwd root; mkinitcpio -P'

  # 4) 最后修启动链（这一步会写 GRUB 核与 grub.cfg）
  mibook-install.sh --repair-esp --root-part /dev/nvme0n1pX --yes

  # 5) 需要桌面再自己加，例如：arch-chroot /mnt pacman -S gnome gdm
EOF
    exit 2
fi

# ---------------------------------------------------------------- --repair-esp
if [[ -n $ROOTDEV ]]; then
    root_uuid=$(blkid -s UUID -o value "$ROOTDEV")
else
    root_uuid=00000000-0000-0000-0000-000000000000
fi
esp_a=$(blkid -s UUID -o value "$ESPDEV" 2>/dev/null || echo "$(basename "$ESPDEV")")

echo
msg "即将写入 $ESPDEV："
echo "      EFI/arch/grubaa64.efi        <- U 盘上那份能引导的核"
echo "      EFI/Boot/bootaa64.efi        <- 同上（fallback 路径）"
echo "      grub/arm64-efi/              <- 模块（缺 fdt.mod 时会补，已有则不动）"
echo "      grub/grub.cfg                <- 带 devicetree 的菜单，root=UUID=$root_uuid"
echo "      vmlinuz-linux-mibook"
echo "      initramfs-linux-mibook.img（+ fallback，如果 U 盘上有）"
echo "      dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4.dtb"
echo
echo "     !! 不要在任何时候运行 grub-install：它会用 ALARM 构建的核覆盖这两份。"
if [[ $ASSUME_YES == no ]]; then
    read -r -p "继续？(yes/NO) " a
    [[ $a == yes ]] || { echo "已取消"; exit 1; }
fi

install -Dm755 "$SRC/EFI/BOOT/BOOTAA64.EFI" "$espmnt/EFI/arch/grubaa64.efi"
install -Dm755 "$SRC/EFI/BOOT/BOOTAA64.EFI" "$espmnt/EFI/Boot/bootaa64.efi"

if [[ ! -f $espmnt/grub/arm64-efi/fdt.mod ]]; then
    msg "补 GRUB 模块（含提供 devicetree 命令的 fdt.mod）"
    # vfat 上 chown 会失败、cp -a 会因此返回非零，所以用 cp -r
    cp -r "$SRC/grub/arm64-efi" "$espmnt/grub/"
    [[ -d $SRC/grub/fonts && ! -d $espmnt/grub/fonts ]] && cp -r "$SRC/grub/fonts" "$espmnt/grub/"
else
    msg "GRUB 模块已在 ESP 上（保留现有）"
fi

install -Dm644 "$SRC/vmlinuz-linux-mibook" "$espmnt/vmlinuz-linux-mibook"
install -Dm644 "$SRC/initramfs-linux-mibook.img" "$espmnt/initramfs-linux-mibook.img"
[[ -f $SRC/initramfs-linux-mibook-fallback.img ]] && \
    install -Dm644 "$SRC/initramfs-linux-mibook-fallback.img" "$espmnt/initramfs-linux-mibook-fallback.img"
install -Dm644 "$SRC/dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4.dtb" \
    "$espmnt/dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4.dtb"

fallback_entry=""
if [[ -f $SRC/initramfs-linux-mibook-fallback.img ]]; then
    fallback_entry="
menuentry 'Arch Linux (Xiaomi Book S 12.4, fallback initramfs)' --class arch {
	insmod part_gpt
	insmod fat
	insmod gzio
	search --no-floppy --fs-uuid --set=root $esp_a
	linux /vmlinuz-linux-mibook root=UUID=$root_uuid rw clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 efi=noruntime loglevel=3 quiet
	devicetree /dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4.dtb
	initrd /initramfs-linux-mibook-fallback.img
}
"
fi

cat > "$espmnt/grub/grub.cfg" <<EOF
# 由 mibook-install.sh --repair-esp 生成 $(date '+%Y-%m-%d %H:%M')
#
# 本机固件不提供设备树，devicetree 行是必需的；
# /EFI/arch/grubaa64.efi 与 /EFI/Boot/bootaa64.efi 是唯一能引导的 GRUB 核，
# 永远不要用 grub-install 覆盖它们（详见 /root/grub-spx-backup/README.md）。
set timeout=5
set default=0

menuentry 'Arch Linux (Xiaomi Book S 12.4)' --class arch {
	insmod part_gpt
	insmod fat
	insmod gzio
	search --no-floppy --fs-uuid --set=root $esp_a
	linux /vmlinuz-linux-mibook root=UUID=$root_uuid rw clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 efi=noruntime loglevel=3 quiet
	devicetree /dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4.dtb
	initrd /initramfs-linux-mibook.img
}
$fallback_entry
EOF

sync
msg "写好了。校验："
sha256sum "$espmnt/EFI/arch/grubaa64.efi" "$espmnt/EFI/Boot/bootaa64.efi" | sed 's/^/      /'
grep -c devicetree "$espmnt/grub/grub.cfg" | sed 's/^/      grub.cfg 里 devicetree 行数: /'

if ! efibootmgr -v 2>/dev/null | grep -q 'EFI.arch.grubaa64.efi'; then
    echo
    msg "固件启动项里没有指向 \\EFI\\arch\\grubaa64.efi 的项，试着建一个："
    echo "      efibootmgr -c -d $DISK -p $(cat /sys/class/block/$(basename "$ESPDEV")/partition) -L arch -l '\\EFI\\arch\\grubaa64.efi'"
    echo "    （本固件还有一套厂商启动顺序变量，见仓库 SYSTEM-CONFIG.md；"
    echo "      建完若进不去，用固件 boot menu 直接选 arch 或浏览到该文件）"
fi

echo
msg "可以重启了。"
