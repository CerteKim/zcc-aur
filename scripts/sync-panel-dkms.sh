#!/usr/bin/env bash
#
# scripts/sync-panel-dkms.sh — 把内核树里的 panel 驱动同步进 DKMS 包
#
# 权威副本在 linux-a51 分支里：
#     drivers/gpu/drm/panel/panel-himax-hx83121a.c
# zcc-aur 的 DKMS 包带一份拷贝，好让这个包能脱离内核树独立构建。
# 改过内核那边之后就运行本脚本，免得两份悄悄跑偏。
#
# 用法:
#   ./scripts/sync-panel-dkms.sh [内核树路径]
#   KERNEL_TREE=~/src/linux ./scripts/sync-panel-dkms.sh
#
# 脚本做三件事：同步文件、把 PKGBUILD 里的 _kcommit 记成内核树当前提交、
# 立刻对当前内核做一次出树编译作为体检（用到了非导出符号会在这里暴露）。

set -euo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
PKDIR="$HERE/packages/panel-himax-hx83121a-dkms"
KERNEL_TREE=${1:-${KERNEL_TREE:-/home/certe/aarch64-packages/linux-surface/src/kernel}}
SRC="$KERNEL_TREE/drivers/gpu/drm/panel/panel-himax-hx83121a.c"
DST="$PKDIR/panel-himax-hx83121a.c"

if [[ ! -f "$SRC" ]]; then
    echo "找不到内核树里的驱动: $SRC" >&2
    echo "用法: $0 [内核树路径]" >&2
    exit 1
fi

if cmp -s "$SRC" "$DST"; then
    echo "==> 内容相同，无需同步"
else
    cp -f "$SRC" "$DST"
    echo "==> 已同步 panel-himax-hx83121a.c"

    commit=$(git -C "$KERNEL_TREE" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
    if [[ "$commit" != unknown ]]; then
        sed -i "s/^_kcommit=.*/_kcommit=$commit/" "$PKDIR/PKGBUILD"
        echo "    来源提交: $commit"
    fi
    echo "    sha256:   $(sha256sum "$DST" | awk '{print $1}')"
fi

echo "==> 出树编译体检（对着 $(uname -r)）"
if [[ -d "/lib/modules/$(uname -r)/build" ]]; then
    if ! make -C "$KERNEL_TREE" M="$PKDIR" modules >/tmp/panel-dkms-check.log 2>&1; then
        echo "!! 编译失败，日志：/tmp/panel-dkms-check.log" >&2
        grep -E 'error:|ERROR: modpost|undefined!' /tmp/panel-dkms-check.log | head -10 >&2
        exit 1
    fi
    echo "    ✓ panel-himax-hx83121a.ko 构建通过"
    make -C "$KERNEL_TREE" M="$PKDIR" clean >/dev/null 2>&1 || true
else
    echo "    跳过：/lib/modules/$(uname -r)/build 不存在（没装内核头文件包）"
fi

echo
echo "接下来（需要出新版本时）："
echo "  1) 改 $PKDIR/PKGBUILD 的 pkgver/pkgrel，并同步 dkms.conf 的 PACKAGE_VERSION"
echo "  2) ./scripts/build.sh panel-himax-hx83121a-dkms"
