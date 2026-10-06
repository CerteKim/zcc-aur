#!/usr/bin/env bash
#
# scripts/make-firmware-tarball.sh
#   把本机已安装的厂商固件里，这台 Xiaomi Book S 12.4 真正需要的那部分
#   打成 packages/xiaomi-book-12.4-firmware/$pkgname-$pkgver.tar.zst
#
# 为什么只要这些：
#   * 参考内核 DTS 明确引用了 ADSP / CDSP / SLPI / MPSS / GPU-zap 五个 blob；
#   * MPSS 用的是 qcmpss8180_nm.mbn 这个 **no-modem** 变体，所以整棵树里
#     75 MB 的 qcmpss8180.mbn（全功能 modem）与 11 MB 的 modem_pr/ mcfg 树
#     都不会被加载，不必打进包里；
#   * venus（VPU）与 wlanmdsp 分别被视频解码与 WiFi 用到；
#   * *.jsn 是加载器元数据，很小，一起带上。
#
# 用法:
#   ./scripts/make-firmware-tarball.sh                    # 从 /usr/lib/firmware 取
#   FWROOT=/mnt/win/... ./scripts/make-firmware-tarball.sh  # 从别处取（目录结构要一致）

set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")/..
PKG=xiaomi-book-12.4-firmware
PKGVER=1
OUT="$HERE/packages/$PKG"
FWROOT=${FWROOT:-/usr/lib/firmware}

FILES=(
    # --- DTS 直接引用（见 sc8180x-xiaomi-book-12.4.dtsi 的 firmware-name）---
    qcom/XIAOMI/BOOK124/qcdxkmsuc8180.mbn    # GPU zap shader (14 KB)
    qcom/XIAOMI/BOOK124/qcadsp8180.mbn       # ADSP  (11.6 MB)
    qcom/XIAOMI/BOOK124/qccdsp8180.mbn       # CDSP  (3.1 MB)
    qcom/XIAOMI/BOOK124/qcslpi8180.mbn       # SLPI  (5.7 MB)
    qcom/XIAOMI/BOOK124/qcmpss8180_nm.mbn    # MPSS, no-modem 变体 (5.2 MB)
    # --- 其它被用到的 ---
    qcom/XIAOMI/BOOK124/qcvss8180.mbn        # VPU/venus (1.2 MB)
    qcom/XIAOMI/BOOK124/wlanmdsp.mbn         # WiFi (4.3 MB)
    qcom/XIAOMI/BOOK124/qdsp6m.qdb           # DSP 数据库 (5.4 MB)
    # --- 加载器元数据 ---
    qcom/XIAOMI/BOOK124/adspr.jsn
    qcom/XIAOMI/BOOK124/adspua.jsn
    qcom/XIAOMI/BOOK124/cdspr.jsn
    qcom/XIAOMI/BOOK124/charger.jsn
    qcom/XIAOMI/BOOK124/modemr.jsn
    qcom/XIAOMI/BOOK124/modemuw.jsn
    # --- venus 另一份（本仓库的另一处路径，见 firmware/qcom/sc8180x/README.md）---
    qcom/sc8180x/venus.mbn
    qcom/sc8180x/venus-noreloc.mbn
)

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

total=0
for f in "${FILES[@]}"; do
    src="$FWROOT/$f"
    if [[ ! -f "$src" ]]; then
        echo "缺少: $src" >&2
        exit 1
    fi
    install -Dm644 "$src" "$STAGE/usr/lib/firmware/$f"
    total=$((total + $(stat -c%s "$src")))
done

mkdir -p "$OUT"
tar -C "$STAGE" --zstd -cf "$OUT/$PKG-$PKGVER.tar.zst" usr

echo "已收集 ${#FILES[@]} 个文件，原始大小 $((total / 1024 / 1024)) MB"
ls -l "$OUT/$PKG-$PKGVER.tar.zst" | awk '{printf "打包后: %s 字节\n", $5}'
echo
echo "接着构建软件包:"
echo "  cd $OUT && makepkg --nodeps --force --cleanbuild --noconfirm"
echo "（tarball 已在 .gitignore 里，不会进 git；只有二进制包会进 Release）"
