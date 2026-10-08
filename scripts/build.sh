#!/usr/bin/env bash
#
# scripts/build.sh — 构建 zcc-aur 里的包，并登记进本地仓库目录 repo/
#
# 用法:
#   ./scripts/build.sh                    # 构建 packages/ 下所有包
#   ./scripts/build.sh ra9530-dkms        # 只构建指定的包（可多个）
#   ./scripts/build.sh --collect <目录>    # 不构建，把目录里已有的 *.pkg.tar.* 收进 repo/
#   ./scripts/build.sh --list             # 列出仓库里现有的包
#   ./scripts/build.sh --db               # 只重建数据库（产物已在 repo/ 时）
#
# 说明:
#   * 内核包（linux-mibook）在 aarch64 上编译需要 1~2 小时，通常用
#     tools/make-kernel-package.sh 或 makepkg 单独构建，再用 --collect 收进来。
#   * repo/ 里同一 pkgname 只保留最新版本；每次都会重建 db。
#   * 产物：repo/zcc-aur.db.tar.gz（+ 解引用副本 zcc-aur.db、zcc-aur.files）

set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")/..
PKGDIR="$HERE/packages"
REPO="$HERE/repo"
DBNAME=zcc-aur

mkdir -p "$REPO"

pkgname_of() {
    # 从文件名解析包名：<pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.<ext>
    printf '%s\n' "${1##*/}" |
        sed -E 's/-[^-]+-[^-]+-(any|aarch64)\.pkg\.tar\.[a-z0-9]+$//'
}

prune_old() {
    # 同名包只留最新（按版本排序，取最后一个）。
    #
    # 分组必须按"每个文件自己解析出的包名"来做，不能用 ${n}-*.pkg.tar.* 这种
    # 前缀 glob：linux-mibook-mainline 是 linux-mibook-mainline-headers 的前缀，
    # 前缀 glob 会让前者的分组把后者的文件也吞进来，然后"保留最新的那个"把
    # 内核包删掉、留下它的 -headers 兄弟包。
    #
    # 内层循环一律用进程替换喂数据：`find | while read` 会和外层 while 抢同一个
    # stdin，把外层循环一次读空（第一组之后就再也不进循环了）。
    local f n
    local -A newest=()
    while IFS= read -r f; do
        n=$(pkgname_of "$f")
        if [[ -z ${newest[$n]:-} ]] ||
           [[ "$(printf '%s\n%s\n' "${newest[$n]}" "$f" | sort -V | tail -1)" == "$f" ]]; then
            newest[$n]=$f
        fi
    done < <(find "$REPO" -maxdepth 1 -name '*.pkg.tar.*' -printf '%f\n' 2>/dev/null)

    while IFS= read -r f; do
        n=$(pkgname_of "$f")
        if [[ "$f" != "${newest[$n]}" ]]; then
            echo "    移除旧版本: $f"
            rm -f "$REPO/$f"
        fi
    done < <(find "$REPO" -maxdepth 1 -name '*.pkg.tar.*' -printf '%f\n' 2>/dev/null)
}

make_db() {
    rm -f "$REPO/$DBNAME.db"* "$REPO/$DBNAME.files"*
    if ! compgen -G "$REPO/*.pkg.tar.*" >/dev/null; then
        echo "    repo/ 里没有包，跳过 db 生成"
        return
    fi
    repo-add -q "$REPO/$DBNAME.db.tar.gz" "$REPO"/*.pkg.tar.*
    # GitHub Releases 不能存符号链接：用 --remove-destination 生成真实副本
    cp -Lf --remove-destination "$REPO/$DBNAME.db.tar.gz" "$REPO/$DBNAME.db"
    if [[ -e "$REPO/$DBNAME.files.tar.gz" ]]; then
        cp -Lf --remove-destination "$REPO/$DBNAME.files.tar.gz" "$REPO/$DBNAME.files"
    fi
    echo "    db 已生成: repo/$DBNAME.db（$(find "$REPO" -maxdepth 1 -name '*.pkg.tar.*' | wc -l) 个包）"
}

case "${1:-}" in
    --collect)
        dst=${2:?用法: --collect <目录>}
        found=0
        while IFS= read -r -d '' f; do
            echo "    收入: $(basename "$f")"
            cp -f "$f" "$REPO/"
            found=$((found + 1))
        done < <(find "$dst" -maxdepth 2 -name '*.pkg.tar.*' -print0)
        [[ $found -gt 0 ]] || { echo "在 $dst 下没找到 *.pkg.tar.zst" >&2; exit 1; }
        prune_old
        make_db
        ;;
    --list)
        find "$REPO" -maxdepth 1 -name '*.pkg.tar.*' -printf '  %f  (%s 字节)\n' | sort
        ;;
    --db)
        # 已经有产物时只重建数据库（例如用 PKGDEST=repo/ 直接构建之后）
        prune_old
        make_db
        ;;
    ""|--all)
        shopt -s nullglob
        for d in "$PKGDIR"/*/; do
            name=$(basename "$d")
            echo "==> 构建 $name"
            ( cd "$d" && PKGDEST="$REPO" makepkg --nodeps --force --cleanbuild --noconfirm )
        done
        prune_old
        make_db
        ;;
    *)
        for name in "$@"; do
            d="$PKGDIR/$name"
            [[ -d "$d" ]] || { echo "没有这个包: $name" >&2; exit 1; }
            echo "==> 构建 $name"
            ( cd "$d" && PKGDEST="$REPO" makepkg --nodeps --force --cleanbuild --noconfirm )
        done
        prune_old
        make_db
        ;;
esac

echo
echo "仓库内容:"
find "$REPO" -maxdepth 1 -type f -printf '  %f\n' | sort
