#!/usr/bin/env bash
#
# scripts/make-sensors-registry-tarball.sh — 打包 SSC 传感器注册表
#
# 传感器注册表（icm4x6xx / stk3a5x 等）是从本机 Windows 安装里提取的厂商数据，
# 与固件同属一类，所以不进 git：只把打好的 tarball 交给 PKGBUILD。
#
# 用法:
#   ./scripts/make-sensors-registry-tarball.sh [源目录]
#   SENSORS_SRC=~/qcom-slpi/root/sensors ./scripts/make-sensors-registry-tarball.sh
#
# 源目录默认按顺序找：
#   1) 参数 / $SENSORS_SRC
#   2) ~/qcom-slpi/root/sensors          （bring-up 时留下的工作副本）
#   3) /usr/share/qcom/sc8180x/XIAOMI/BOOK124/sensors   （已装好的系统）
#
# 产出（按 PKGBUILD 期望的 usr/ 布局）：
#   packages/xiaomi-book-12.4-sensors/xiaomi-book-12.4-sensors-registry-<ver>.tar.zst

set -euo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
PKDIR="$HERE/packages/xiaomi-book-12.4-sensors"
VER=${REGISTRY_VER:-1}
ROOT=/usr/share/qcom/sc8180x/XIAOMI/BOOK124/sensors

src=${1:-${SENSORS_SRC:-}}
if [[ -z $src ]]; then
    for cand in "$HOME/qcom-slpi/root/sensors" "$ROOT"; do
        if [[ -d $cand/config && -d $cand/registry ]]; then src=$cand; break; fi
    done
fi

if [[ -z $src ]]; then
    echo "找不到传感器注册表目录。" >&2
    echo "用法: $0 [源目录]（目录下应有 config/ 与 registry/）" >&2
    exit 1
fi
if [[ ! -d $src/config || ! -d $src/registry ]]; then
    echo "$src 下没有 config/ 与 registry/ 两个子目录" >&2
    exit 1
fi

out="$PKDIR/xiaomi-book-12.4-sensors-registry-$VER.tar.zst"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

install -d "$stage$ROOT"
cp -a "$src/config" "$src/registry" "$stage$ROOT/"

tar --zstd -cf "$out" -C "$stage" usr

echo "==> 已生成 $out"
echo "    来源:   $src"
echo "    文件数: $(find "$stage$ROOT" -type f | wc -l)"
echo "    大小:   $(du -h "$out" | cut -f1)"
echo "    sha256: $(sha256sum "$out" | awk '{print $1}')"
echo
echo "接下来：把上面的 sha256 填进 $PKDIR/PKGBUILD 里 registry tarball 那一行，"
echo "然后 ./scripts/build.sh xiaomi-book-12.4-sensors"
