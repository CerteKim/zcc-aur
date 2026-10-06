#!/usr/bin/env bash
#
# scripts/publish.sh — 把 repo/ 里的数据库与所有包发布成一个 GitHub Release
#
# 客户端把 Release 的 latest/download 当作 pacman 的 Server：
#     Server = https://github.com/CerteKim/zcc-aur/releases/latest/download
# 因为 pacman 会请求 <Server>/zcc-aur.db 与 <Server>/<包文件名>，
# 而 /releases/latest/download/<文件名> 会 302 到该 Release 的资源，
# 所以每次发布都必须把【数据库 + 全部包】一起传上去。
#
# 用法:
#   ./scripts/publish.sh                 # 自动用日期做 tag
#   TAG=2026-10-06 ./scripts/publish.sh  # 指定 tag
#
# 依赖: GitHub CLI（sudo pacman -S github-cli && gh auth login）

set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")/..
REPO="$HERE/repo"
TAG=${TAG:-repo-$(date +%Y%m%d-%H%M%S)}
NOTES=${NOTES:-"pacman repository snapshot $TAG"}

command -v gh >/dev/null || {
    echo "需要 GitHub CLI：" >&2
    echo "  sudo pacman -S github-cli" >&2
    echo "  gh auth login" >&2
    exit 1
}

shopt -s nullglob
files=("$REPO"/*.pkg.tar.*)
[[ -f "$REPO/zcc-aur.db" ]] || { echo "repo/ 里没有 zcc-aur.db，先跑 scripts/build.sh" >&2; exit 1; }
[[ ${#files[@]} -gt 0 ]] || { echo "repo/ 里没有包，先跑 scripts/build.sh" >&2; exit 1; }

echo "==> 发布 $TAG"
echo "    db    : repo/zcc-aur.db"
echo "    包数量: ${#files[@]}"
for f in "${files[@]}"; do printf '      %s (%s 字节)\n' "$(basename "$f")" "$(stat -c%s "$f")"; done

# 数据库 + 解引用副本 + 所有包，全部放进同一个 Release
assets=("$REPO/zcc-aur.db" "$REPO/zcc-aur.db.tar.gz")
for f in "$REPO"/zcc-aur.files "$REPO"/zcc-aur.files.tar.gz; do
    [[ -e "$f" ]] && assets+=("$f")
done
assets+=("${files[@]}")

gh release create "$TAG" "${assets[@]}" \
    --title "pacman repo $TAG" \
    --notes "$NOTES"

cat <<EOF

已发布。客户端配置（/etc/pacman.conf）：

  [zcc-aur]
  SigLevel = Optional TrustAll
  Server = https://github.com/CerteKim/zcc-aur/releases/latest/download

然后： sudo pacman -Syu && sudo pacman -Ss zcc

注意：latest 只会指向【最新】的 Release，而每个 Release 里都是完整快照，
所以请始终用本脚本发布（它一次上传 db + 全部包）。
EOF
