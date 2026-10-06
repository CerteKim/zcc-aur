#!/usr/bin/env bash
#
# maintainer/stage-mibook-usb.sh — 从当前系统生成 U 盘暂存树
#
# 产出（默认 ~/mibook-usb/esp，就是 U 盘 p1 的内容）：
#   EFI/BOOT/BOOTAA64.EFI                     唯一验证过能引导的 GRUB 核
#   grub/grub.cfg                             启动菜单（见 maintainer/mibook-usb-grub.cfg）
#   grub/arm64-efi/                           GRUB 模块（devicetree 命令来自 fdt.mod）
#   grub/fonts/                               菜单字体
#   vmlinuz-linux-mibook                      U 盘自带一份内核
#   initramfs-linux-mibook.img                U 盘自带一份 initramfs
#   dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4.dtb
#
# 顺带把 GRUB 核备份到 ~/grub-spx-backup/（含 SHA256SUMS 与说明）—— 这是本机
# 最关键的资产，`grub-install` 会把它覆盖掉。
#
# 不需要 root（只读 /boot、/usr/lib/grub）。
#
# 用法:
#   ./maintainer/stage-mibook-usb.sh [--stage DIR] [--kernel-ver 6.18.2-1-mibook+]

set -euo pipefail

STAGE=${STAGE:-$HOME/mibook-usb}
GRUB_BACKUP=${GRUB_BACKUP:-$HOME/grub-spx-backup}
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
DTB_REL=dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4.dtb
KVER=$(uname -r)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage)      STAGE=$2; shift ;;
        --backup)     GRUB_BACKUP=$2; shift ;;
        --kernel-ver) KVER=$2; shift ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
    shift
done

msg() { echo "==> $*"; }

# ---------------------------------------------------------------- GRUB 核
CORE_SRC=
for c in /boot/EFI/arch/grubaa64.efi /boot/EFI/Boot/bootaa64.efi; do
    [[ -f $c ]] && { CORE_SRC=$c; break; }
done
[[ -n $CORE_SRC ]] || { echo "找不到能引导的 GRUB 核（/boot/EFI/arch/grubaa64.efi）" >&2; exit 1; }

msg "备份 GRUB 核: $CORE_SRC -> $GRUB_BACKUP/"
mkdir -p "$GRUB_BACKUP"
cp -f "$CORE_SRC" "$GRUB_BACKUP/grubaa64.efi"
install -m644 "$HERE/grub-spx-backup-README.md" "$GRUB_BACKUP/README.md" 2>/dev/null || \
    cp -f "$HERE/grub-spx-backup-README.md" "$GRUB_BACKUP/README.md" 2>/dev/null || true
{
    sha256sum "$GRUB_BACKUP/grubaa64.efi"
} > "$GRUB_BACKUP/SHA256SUMS"
cat "$GRUB_BACKUP/SHA256SUMS"

# ---------------------------------------------------------------- 暂存树
msg "暂存树: $STAGE/esp"
rm -rf "$STAGE/esp"
mkdir -p "$STAGE/esp/EFI/BOOT" "$STAGE/esp/grub" "$(dirname "$STAGE/esp/$DTB_REL")"

install -Dm755 "$GRUB_BACKUP/grubaa64.efi" "$STAGE/esp/EFI/BOOT/BOOTAA64.EFI"

# GRUB 模块：优先用 ESP 上装好的那份（模块版本与核匹配），否则用 grub 包里的
MODSRC=/boot/grub/arm64-efi
[[ -d $MODSRC ]] || MODSRC=/usr/lib/grub/arm64-efi
[[ -d $MODSRC ]] || { echo "找不到 GRUB 模块目录（/boot/grub/arm64-efi）" >&2; exit 1; }
cp -a "$MODSRC" "$STAGE/esp/grub/"
[[ -f $STAGE/esp/grub/arm64-efi/fdt.mod ]] || { echo "缺 fdt.mod：devicetree 命令就没了" >&2; exit 1; }
[[ -d /boot/grub/fonts ]] && cp -a /boot/grub/fonts "$STAGE/esp/grub/"

# 内核 / initramfs / DTB
[[ -f /boot/vmlinuz-linux-mibook ]] || { echo "找不到 /boot/vmlinuz-linux-mibook" >&2; exit 1; }
[[ -f /boot/initramfs-linux-mibook.img ]] || { echo "找不到 /boot/initramfs-linux-mibook.img" >&2; exit 1; }
[[ -f /boot/$DTB_REL ]] || { echo "找不到 /boot/$DTB_REL" >&2; exit 1; }
cp -a /boot/vmlinuz-linux-mibook "$STAGE/esp/"
cp -a /boot/initramfs-linux-mibook.img "$STAGE/esp/"
cp -a "/boot/$DTB_REL" "$STAGE/esp/$DTB_REL"

# 启动菜单模板
cp -f "$HERE/mibook-usb-grub.cfg" "$STAGE/esp/grub/grub.cfg"

# 内核模块也带上一份（live 系统起不来时，可以拿它做外部模块目录）
msg "（可选）内核模块目录: /usr/lib/modules/$KVER -> 暂存树/rootfs-modules/"
if [[ -d /usr/lib/modules/$KVER ]]; then
    du -sh "/usr/lib/modules/$KVER" | sed 's/^/    /'
    echo "    说明：只有 --live 时才会用到（pacstrap 那步会自己装包），默认不复制。"
fi

msg "完成"
ls -la "$STAGE/esp" | sed 's/^/    /'
echo
echo "    体积: $(du -sh "$STAGE/esp" | cut -f1)"
echo "    下一步: sudo ./maintainer/make-mibook-usb.sh /dev/sdX --dry-run"
