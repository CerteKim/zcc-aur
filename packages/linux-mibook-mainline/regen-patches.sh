#!/usr/bin/env bash
#
# regen-patches.sh — 从内核镜像的开发分支重新生成 patches/
#
# 权威副本在 linux-surface 仓库的内核镜像里（不是本目录）：
#
#     mirror:  /home/certe/aarch64-packages/linux-surface/kernel
#     branch:  xiaomi-mainline-7.2   （基于 upstream v7.2 的 29 个提交）
#     base:    upstream-v7.2         （= linux-7.2.tar.xz 的内容）
#
# 改补丁的流程：
#   1) 在开发树里改代码、把提交整理干净：
#          cd /home/certe/aarch64-packages/linux-surface/src/kernel-7.2
#          git commit -a --amend / git rebase -i upstream-v7.2 ...
#   2) 重新生成补丁集并核对：
#          ./regen-patches.sh
#   3) 构建：
#          makepkg -s
#
# 用法:
#   ./regen-patches.sh [分支] [基线]
#   MIRROR=/path/to/kernel ./regen-patches.sh
#
# 脚本只做两件事：清掉旧补丁、用 git format-patch 重新导出；导出后打印
# 补丁数量与总行数，方便和上次比较。

set -euo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
MIRROR=${MIRROR:-/home/certe/aarch64-packages/linux-surface/kernel}
BRANCH=${1:-xiaomi-mainline-7.2}
BASE=${2:-upstream-v7.2}
PATCHES="$HERE"

if ! git -C "$MIRROR" rev-parse --verify --quiet "$BRANCH" >/dev/null; then
    echo "找不到分支 $BRANCH（镜像 $MIRROR）" >&2
    exit 1
fi
if ! git -C "$MIRROR" rev-parse --verify --quiet "$BASE" >/dev/null; then
    echo "找不到基线 $BASE（镜像 $MIRROR）" >&2
    echo "先取上游 tag，例如：" >&2
    echo "  git -C $MIRROR fetch --no-tags https://github.com/torvalds/linux.git \\" >&2
    echo "      refs/tags/v7.2:refs/tags/upstream-v7.2" >&2
    exit 1
fi

# makepkg 只按 basename 在当前目录找本地源，所以补丁平铺在包目录里
rm -f "$PATCHES"/[0-9][0-9][0-9][0-9]-*.patch

git -C "$MIRROR" format-patch --no-signature --no-numbered \
    -o "$PATCHES" "$BASE..$BRANCH" >/dev/null

n=$(find "$PATCHES" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-*.patch' | wc -l)
lines=$(cat "$PATCHES"/[0-9][0-9][0-9][0-9]-*.patch | wc -l)
echo "==> 已生成 $n 个补丁，共 $lines 行"
git -C "$MIRROR" log --oneline "$BASE..$BRANCH" | tac | nl -w2 -s' ' | sed 's/^/    /'
echo
echo "提醒：PKGBUILD 的 sha256sums 里，tarball 之外的条目全是 SKIP，"
echo "补丁增删不需要改校验和；只有换上游版本时才要换第一项。"
