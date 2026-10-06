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
#                              + vmlinuz + initramfs + dtb（和装好的系统同形状）
#   p2  ext4   MIBOOK_ROOT  <- live / 救援系统的根（--live 时才有内容）
#
# 默认只做 p1：**救援盘**。内部 ESP 被 grub-install 覆盖之类的灾难下用它就能重新
# 进系统（菜单第二项用 U 盘自带的内核 + 内部根分区）。
#
# --live 额外 pacstrap 一个精简系统到 p2，并放进 mibook-install.sh，做成一套
# “定制安装/救援介质”。live 系统是 ext4 根，所以 mkinitcpio 里显式写了
# MODULES=(ext4)（本机根与 SD 卡都是 btrfs，autodetect 不会带上 ext4）。
#
# 用法:
#   sudo ./maintainer/make-mibook-usb.sh /dev/sdX                 # 救援盘
#   sudo ./maintainer/make-mibook-usb.sh /dev/sdX --dry-run       # 只看要做什么
#   sudo ./maintainer/make-mibook-usb.sh /dev/sdX --live          # 额外做 live 根
#   sudo ./maintainer/make-mibook-usb.sh /dev/sdX --yes           # 不交互确认
#
# host 上需要的工具：gptfdisk(sgdisk)、dosfstools(mkfs.vfat)、e2fsprogs、
# util-linux；--live 还要 arch-install-scripts(pacstrap/arch-chroot) 与 rsync。
#
# 注意：**会清空目标设备**。脚本会拒绝内部 NVMe/eMMC/SD、已挂载的设备、以及根
# 文件系统所在的设备。

set -euo pipefail

ESP_SIZE_MB=${ESP_SIZE_MB:-1536}
KNOWN_CORE_SHA=204b6d8913d249c331ac13d689644f9342d8df7491fed0a9435b263d10a827ca

# sudo 可能把 HOME 换成 /root（取决于 sudoers 里的 always_set_home / env_keep），
# 那样 ~/mibook-usb、~/grub-spx-backup、~/aarch64-packages 全都找不到 —— 这正是
# 第一次运行时报「找不到 linux-mibook 包」的原因。默认路径一律按**调用者**的家
# 目录算。
if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    USER_HOME=$HOME
fi
[[ -d $USER_HOME ]] || USER_HOME=$HOME

STAGE=${STAGE:-$USER_HOME/mibook-usb}
GRUB_BACKUP=${GRUB_BACKUP:-$USER_HOME/grub-spx-backup}
PKGDIR=${PKGDIR:-$USER_HOME/zcc-aur/repo}
KERNEL_PKG=${KERNEL_PKG:-}
LIVE=no
DRY_RUN=no
ASSUME_YES=no
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

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

if [[ -z $DEV ]]; then
    sed -n '2,34p' "$0"
    exit 2
fi

msg() { echo "==> $*"; }
run() {
    if [[ $DRY_RUN == yes ]]; then
        echo "    [dry-run] $*"
    else
        echo "    + $*"
        "$@"
    fi
}
die() { echo "!! $*" >&2; exit 1; }

# 出错/中断时也要把挂载点收回去：上一次真实的运行就是在 cp 那里中断，把
# /dev/sdb1 挂在了 /tmp/tmp.XXXX 上，下一次运行就被自己的"已挂载"检查挡住。
ESPMNT=
ROOTMNT=
tmppac=
cleanup() {
    set +e
    [[ -n $ROOTMNT ]] && mountpoint -q "$ROOTMNT/boot" && umount "$ROOTMNT/boot"
    [[ -n $ROOTMNT ]] && mountpoint -q "$ROOTMNT" && umount "$ROOTMNT"
    [[ -n $ESPMNT ]]  && mountpoint -q "$ESPMNT"  && umount "$ESPMNT"
    [[ -n $tmppac && -f $tmppac ]] && rm -f "$tmppac"
    return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# ---------------------------------------------------------------- 前置检查
[[ $DRY_RUN == yes || $EUID -eq 0 ]] || die "需要 root：sudo $0 $DEV${LIVE:+ --live}"
[[ -b $DEV ]] || die "$DEV 不是块设备"
[[ -e /sys/class/block/$(basename "$DEV")/partition ]] && \
    die "$DEV 是分区，需要整个磁盘（/dev/sdb 而不是 /dev/sdb1）"

root_src=$(findmnt -no SOURCE / || true)
root_disk=$(lsblk -no pkname "$root_src" 2>/dev/null | head -1 || true)
[[ -n $root_disk && "/dev/$root_disk" == "$DEV" ]] && die "$DEV 上挂着根文件系统"

case "$DEV" in
    /dev/nvme*|/dev/mmcblk*) die "$DEV 看起来是内部设备（NVMe/eMMC/SD），不是 U 盘" ;;
esac
if lsblk -no MOUNTPOINT "$DEV" | grep -q .; then
    echo "!! $DEV 上有分区已挂载：" >&2
    findmnt -rn -o SOURCE,TARGET | grep "^$DEV" | sed 's/^/     /' >&2
    echo "   先卸载（上次中断的运行可能留下了挂载点）：" >&2
    echo "     sudo umount $DEV?    # 或按上面列出的挂载点逐个 umount" >&2
    exit 1
fi

for c in sgdisk mkfs.ext4 partprobe blkid; do
    command -v "$c" >/dev/null || die "缺少 $c（pacman -S gptfdisk e2fsprogs util-linux）"
done
if [[ $DRY_RUN == no ]]; then
    command -v mkfs.vfat >/dev/null || die "缺少 mkfs.vfat（sudo pacman -S dosfstools）"
fi
if [[ $LIVE == yes && $DRY_RUN == no ]]; then
    for c in pacstrap arch-chroot; do
        command -v "$c" >/dev/null || die "缺少 $c（sudo pacman -S arch-install-scripts）"
    done
fi

[[ -f $STAGE/esp/EFI/BOOT/BOOTAA64.EFI ]] || \
    die "找不到 $STAGE/esp/EFI/BOOT/BOOTAA64.EFI —— 先跑 maintainer/stage-mibook-usb.sh"

core_sha=$(sha256sum "$STAGE/esp/EFI/BOOT/BOOTAA64.EFI" | awk '{print $1}')
if [[ $core_sha == "$KNOWN_CORE_SHA" ]]; then
    msg "GRUB 核校验通过（$core_sha）"
    if [[ -f $GRUB_BACKUP/SHA256SUMS ]] && ! grep -q "$core_sha" "$GRUB_BACKUP/SHA256SUMS"; then
        echo "   注意：$GRUB_BACKUP/SHA256SUMS 里记的不是这个哈希，备份可能过期了。" >&2
        echo "   重新生成备份：./maintainer/stage-mibook-usb.sh" >&2
    fi
else
    echo "!! $STAGE/esp/EFI/BOOT/BOOTAA64.EFI 的 sha256 ($core_sha)" >&2
    echo "   不是那份验证过能引导的核（应为 $KNOWN_CORE_SHA）。" >&2
    echo "   先跑 ./maintainer/stage-mibook-usb.sh 从当前系统的 /boot/EFI 重新生成。" >&2
    [[ $ASSUME_YES == yes ]] || { read -r -p "仍要继续？(yes/NO) " a; [[ $a == yes ]] || exit 1; }
fi

if [[ $LIVE == yes ]]; then
    if [[ -z $KERNEL_PKG ]]; then
        # 内核包可能放在几个地方，而且 sudo 下 $HOME 未必是调用者的家目录
        # （见文件开头 USER_HOME 的说明），所以都找一遍。
        search_dirs=(
            "$USER_HOME/aarch64-packages/linux-surface"
            "$USER_HOME/zcc-aur/repo"
            "$USER_HOME/aarch64-packages"
            /var/cache/pacman/pkg
        )
        for d in /home/*/aarch64-packages/linux-surface; do
            [[ -d $d ]] && search_dirs+=("$d")
        done
        found=()
        for d in "${search_dirs[@]}"; do
            [[ -d $d ]] || continue
            for f in "$d"/linux-mibook-*.pkg.tar.*; do
                [[ -f $f ]] && found+=("$f")
            done
        done
        if ((${#found[@]})); then
            KERNEL_PKG=$(printf '%s\n' "${found[@]}" | sort -V | tail -1)
        fi
    fi
    if [[ -z $KERNEL_PKG || ! -f $KERNEL_PKG ]]; then
        if [[ -n $KERNEL_PKG ]]; then
            echo "!! --kernel 给的文件不存在：$KERNEL_PKG" >&2
        else
            echo "!! 找不到 linux-mibook 包。找过这些地方：" >&2
            for d in "${search_dirs[@]:-}"; do [[ -n $d ]] && echo "     $d" >&2; done
        fi
        echo "   用 --kernel <文件> 指定，例如：" >&2
        echo "     sudo $0 $DEV --live --kernel $USER_HOME/aarch64-packages/linux-surface/linux-mibook-6.18.2-1-21-aarch64.pkg.tar.zst" >&2
        exit 1
    fi
    [[ -f $HERE/mibook-install.sh ]] || die "缺少 $HERE/mibook-install.sh"
fi

echo
echo "目标设备 : $DEV  ($(lsblk -dno SIZE,MODEL "$DEV" 2>/dev/null | xargs))"
echo "ESP      : p1 ${ESP_SIZE_MB} MiB FAT32 (MIBOOK_ESP)"
echo "根分区   : p2 其余 ext4 (MIBOOK_ROOT)"
echo "live 系统: $([[ $LIVE == yes ]] && echo "是（pacstrap + $(basename "$KERNEL_PKG")）" || echo '否（只做救援盘）')"
if [[ $DRY_RUN == no && $ASSUME_YES == no ]]; then
    read -r -p "这会清空 $DEV 上的所有数据，继续？(yes/NO) " a
    [[ $a == yes ]] || { echo "已取消"; exit 1; }
fi

# ---------------------------------------------------------------- 分区与格式化
msg "分区"
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
run mkfs.ext4 -q -F -L MIBOOK_ROOT -m 1 "$root"

if [[ $DRY_RUN == no ]]; then
    esp_uuid=$(blkid -s UUID -o value "$esp")
    root_uuid=$(blkid -s UUID -o value "$root")
fi

# ---------------------------------------------------------------- p1：启动文件
ESPMNT=$(mktemp -d)
msg "写启动文件到 $esp"
run mount "$esp" "$ESPMNT"
# vfat 存不了属主/权限，cp -a 会因为 chown 失败而返回非零（set -e 下直接中断），
# 所以这里用 cp -r：ESP 上的权限由挂载选项（fmask/dmask）决定，够用。
run cp -r "$STAGE/esp/." "$ESPMNT/"
if [[ $DRY_RUN == no ]]; then
    sed -i "s/@USB_ROOT_UUID@/$root_uuid/" "$ESPMNT/grub/grub.cfg"
    echo "    live 根 UUID = $root_uuid（已写进 grub.cfg）"

    # 写完了当场核一遍：少了任何一件，U 盘都引导不了
    missing=0
    for f in EFI/BOOT/BOOTAA64.EFI grub/grub.cfg grub/arm64-efi/fdt.mod \
             grub/arm64-efi/linux.mod vmlinuz-linux-mibook initramfs-linux-mibook.img \
             dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4.dtb; do
        [[ -f $ESPMNT/$f ]] || { echo "    !! 少了 $f" >&2; missing=1; }
    done
    [[ $missing == 0 ]] || die "p1 上的启动文件不完整，别拔盘"
    echo "    ✓ 启动文件齐全（$(find "$ESPMNT" -type f | wc -l) 个文件，$(du -sh "$ESPMNT" | cut -f1)）"
    grep -q 'devicetree' "$ESPMNT/grub/grub.cfg" || die "grub.cfg 里没有 devicetree 行"
fi
run sync

# ---------------------------------------------------------------- p2：live 系统
if [[ $LIVE == yes ]]; then
    ROOTMNT=$(mktemp -d)
    msg "pacstrap 一个精简系统到 $root"
    run mount "$root" "$ROOTMNT"

    # 目标系统的 pacman 用 host 的配置，但去掉 host 上那个坏掉的 [aur] 段
    tmppac=$(mktemp)
    awk '/^\[aur\]/{skip=1} /^\[/{if ($0 !~ /^\[aur\]/) skip=0} !skip' /etc/pacman.conf > "$tmppac"
    run install -Dm644 "$tmppac" "$ROOTMNT/etc/pacman.conf"
    run install -Dm644 /etc/pacman.d/mirrorlist "$ROOTMNT/etc/pacman.d/mirrorlist"
    run pacstrap -C "$tmppac" "$ROOTMNT" base

    msg "拷本仓库的包进 live 系统（/var/cache/mibook，装到内部磁盘时要用）"
    run mkdir -p "$ROOTMNT/var/cache/mibook"
    run cp "$KERNEL_PKG" "$ROOTMNT/var/cache/mibook/"
    shopt -s nullglob
    for p in "$PKGDIR"/*.pkg.tar.*; do
        run cp "$p" "$ROOTMNT/var/cache/mibook/"
    done
    shopt -u nullglob

    # /boot 就是 p1：GRUB 从这里读内核/initramfs/DTB，和装好的系统一个形状
    run mkdir -p "$ROOTMNT/boot"
    run mount "$esp" "$ROOTMNT/boot"

    # live 系统的 fstab（host 侧直接写，按 UUID）
    if [[ $DRY_RUN == no ]]; then
        cat > "$ROOTMNT/etc/fstab" <<EOF
# live USB（由 make-mibook-usb.sh 生成）
UUID=$root_uuid	/	ext4	rw,relatime	0 1
UUID=$esp_uuid	/boot	vfat	rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro	0 2
EOF
    fi

    msg "在 chroot 里装运行需要的包、写 mkinitcpio 配置、生成 live initramfs"
    run cp -f "$HERE/mibook-install.sh" "$ROOTMNT/usr/local/bin/mibook-install.sh"

    run arch-chroot "$ROOTMNT" /bin/bash -c '
        set -e
        pacman -Sy --noconfirm

        # live 系统本身要用的（DKMS 那两个包只留在 /var/cache/mibook，供装到内部磁盘）
        pacman -U --noconfirm \
            /var/cache/mibook/linux-mibook-*.pkg.tar.* \
            /var/cache/mibook/xiaomi-book-12.4-*.pkg.tar.* \
            /var/cache/mibook/iio-sensor-proxy-ssc-*.pkg.tar.* \
            /var/cache/mibook/qrtr-*.pkg.tar.* \
            /var/cache/mibook/qmic-*.pkg.tar.* \
            /var/cache/mibook/pd-mapper-*.pkg.tar.* \
            /var/cache/mibook/rmtfs-*.pkg.tar.* \
            /var/cache/mibook/tqftpserv-*.pkg.tar.*

        # 救援与安装要用的工具
        pacman -S --noconfirm --needed \
            nano vim less arch-install-scripts \
            gptfdisk parted dosfstools btrfs-progs rsync efibootmgr iwd

        # ext4 根：本机 autodetect 看不见 ext4（根和 SD 卡都是 btrfs），显式带上
        sed -i "s|^HOOKS=.*|HOOKS=(base systemd autodetect microcode modconf xiaomi-book124-firmware kms keyboard sd-vconsole block filesystems fsck)|" /etc/mkinitcpio.conf
        sed -i "s|^MODULES=.*|MODULES=(ext4)|" /etc/mkinitcpio.conf

        passwd -d root
        systemctl enable iwd.service systemd-networkd.service
        systemctl set-default multi-user.target
        chmod +x /usr/local/bin/mibook-install.sh
        mkinitcpio -P
    '

    run sync
    run umount "$ROOTMNT/boot"
    run umount "$ROOTMNT"
    rmdir "$ROOTMNT" 2>/dev/null || true
    rm -f "$tmppac"
fi

run sync
run umount "$ESPMNT"
rmdir "$ESPMNT" 2>/dev/null || true

echo
msg "完成：$DEV"
echo
echo "人工验证（这一步决定后面值不值得继续做更完整的介质）："
echo "  1) 重启进固件 boot menu，选 USB / UEFI: <你的 U 盘>；"
echo "  2) 应出现 GRUB 菜单："
echo "       [1] 用内部 ESP 的内核启动内部系统"
echo "       [2] 用 U 盘的内核启动内部系统（救援：内部 ESP 坏了也能进）"
if [[ $LIVE == yes ]]; then
    echo "       [3] 启动 U 盘上的 live 系统（root 无密码，控制台）"
fi
echo "  3) 能进菜单 = 固件 -> USB ESP -> 我们的 GRUB 核 -> devicetree -> 内核 全通。"
echo
echo "live 系统里另有 /usr/local/bin/mibook-install.sh（--repair-esp 修启动链），"
echo "用法见该脚本头部。"
