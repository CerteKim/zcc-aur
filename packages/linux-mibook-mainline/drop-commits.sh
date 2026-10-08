#!/usr/bin/env bash
#
# drop-commits.sh — 从开发分支摘掉若干提交（等价于 git rebase -i 里删行），
#                   然后重新导出包目录里的平铺补丁集。
#
# 用法：
#   ./drop-commits.sh [-n] [-N] [-b 分支] [-B 基线] <提交>...
#
#   <提交> 可以是 hash（完整或短），也可以是 subject 里唯一的一段文字；
#   一次可以给多个。
#
#   -n, --dry-run   只打印会摘掉哪些提交，不改动任何东西
#   -N, --no-regen  摘完不跑 regen-patches.sh（只改分支，不动补丁文件）
#   -b <分支>       默认 xiaomi-mainline-7.2
#   -B <基线>       默认 upstream-v7.2
#   -h, --help      显示这段说明
#
# 例（撤掉 no_gpu_recovery 那对调试补丁和 UBWC 调试补丁）：
#   ./drop-commits.sh -n 37368a6ba212 4f4428b828f4 3f8e2efe10f8
#   ./drop-commits.sh    37368a6ba212 4f4428b828f4 3f8e2efe10f8
#
# 安全性：
#   * 改写历史前，旧 tip 记到 refs/backup/drop-commits-<时间戳>，回滚用
#         git -C <worktree> reset --hard refs/backup/drop-commits-<时间戳>
#   * rebase 冲突时**自动 abort**，仓库保持原样，不会留下半成品。
#   * 该分支的 upstream 是本地 tag upstream-v7.2，没有推到远端，改写是安全的。

set -euo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
MIRROR=${MIRROR:-/home/certe/aarch64-packages/linux-surface/kernel}
WORKTREE=${WORKTREE:-/home/certe/aarch64-packages/linux-surface/src/kernel-7.2}
BRANCH=${BRANCH:-xiaomi-mainline-7.2}
BASE=${BASE:-upstream-v7.2}
DRY=0
REGEN=1
SPECS=()

while (($#)); do
    case $1 in
        -n|--dry-run) DRY=1 ;;
        -N|--no-regen) REGEN=0 ;;
        -b) BRANCH=$2; shift ;;
        -B) BASE=$2; shift ;;
        -h|--help) sed -n '2,30p' "$(readlink -f "$0")"; exit 0 ;;
        -*) echo "未知选项：$1" >&2; exit 2 ;;
        *) SPECS+=("$1") ;;
    esac
    shift
done

((${#SPECS[@]})) || { echo "用法：$0 [-n] [-N] [-b 分支] [-B 基线] <提交>..." >&2; exit 2; }

cd "$WORKTREE"

git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || {
    echo "找不到基线 $BASE（镜像 $MIRROR）" >&2; exit 1; }
cur=$(git rev-parse --abbrev-ref HEAD)
[[ $cur == "$BRANCH" ]] || { echo "当前分支是 $cur，不是 $BRANCH" >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "工作树不干净：" >&2; git status --short >&2; exit 1; }

# <提交> → 完整 hash
resolve() {
    local spec=$1 full hits
    if [[ $spec =~ ^[0-9a-f]{7,40}$ ]]; then
        full=$(git rev-parse --verify --quiet "${spec}^{commit}") || {
            echo "找不到提交 $spec" >&2; return 1; }
        git merge-base --is-ancestor "$full" HEAD || {
            echo "$spec 不是 $BRANCH 的祖先" >&2; return 1; }
        if git merge-base --is-ancestor "$full" "$BASE"; then
            echo "$spec 已经在基线 $BASE 里，不用摘" >&2; return 1
        fi
        printf '%s\n' "$full"
        return 0
    fi
    hits=$(git log --format='%H %s' "$BASE..HEAD" | grep -F -- "$spec" | awk '{print $1}' || true)
    case $(grep -c . <<<"$hits") in
        1) printf '%s\n' "$hits" ;;
        0) echo "在 $BASE..$BRANCH 里找不到匹配 \"$spec\" 的提交" >&2; return 1 ;;
        *) echo "\"$spec\" 匹配到多个提交，请给更精确的文字或直接用 hash：" >&2
           git log --format='  %h %s' "$BASE..HEAD" | grep -F -- "$spec" >&2; return 1 ;;
    esac
}

FULL=()
for spec in "${SPECS[@]}"; do
    FULL+=("$(resolve "$spec")") || exit 1
done

echo "==> 目标分支 $BRANCH，基线 $BASE，当前 tip $(git rev-parse --short HEAD)"
echo "==> 将摘掉 ${#FULL[@]} 个提交："
for h in "${FULL[@]}"; do
    printf '    %s  %s\n' "$(git rev-parse --short "$h")" "$(git log -1 --format=%s "$h")"
done
before=$(git rev-list --count "$BASE..HEAD")
echo "==> 摘掉后：$before → $((before - ${#FULL[@]})) 个提交"

if ((DRY)); then
    echo "==> --dry-run：什么都没改。"
    exit 0
fi

stamp=$(date +%Y%m%d-%H%M%S)
backup="refs/backup/drop-commits-$stamp"
git update-ref "$backup" HEAD
echo "==> 旧 tip 已记到 $backup"

DROP_LIST=$(mktemp)
printf '%s\n' "${FULL[@]}" >"$DROP_LIST"
SEQ_EDITOR=$(mktemp)
cat >"$SEQ_EDITOR" <<'EOF'
#!/usr/bin/env bash
# git rebase 的 todo 编辑器：把 hash 在 $DROP_LIST 里的行删掉
set -euo pipefail
todo=$1
out=$(mktemp)
while IFS= read -r line; do
    h=$(awk '{print $2}' <<<"$line")
    drop=0
    if [[ $h =~ ^[0-9a-f]+$ ]]; then
        while IFS= read -r full; do
            [[ -n $full && $full == "$h"* ]] && { drop=1; break; }
        done <"$DROP_LIST"
    fi
    if ((drop)); then
        printf '    摘掉: %s\n' "$line" >&2
    else
        printf '%s\n' "$line" >>"$out"
    fi
done <"$todo"
cat "$out" >"$todo"
rm -f "$out"
EOF
chmod +x "$SEQ_EDITOR"

if ! GIT_SEQUENCE_EDITOR="$SEQ_EDITOR" GIT_EDITOR=true DROP_LIST="$DROP_LIST" \
        git rebase -i "$BASE"; then
    echo "==> rebase 失败（多半是冲突），已 abort，仓库保持原样。" >&2
    git rebase --abort 2>/dev/null || true
    rm -f "$DROP_LIST" "$SEQ_EDITOR"
    exit 1
fi
rm -f "$DROP_LIST" "$SEQ_EDITOR"

echo "==> 新 tip $(git rev-parse --short HEAD)，$(git rev-list --count "$BASE..HEAD") 个提交"
git log --oneline "$BASE..HEAD" | tac | nl -w2 -s' ' | sed 's/^/    /'

if ((REGEN)); then
    echo
    "$HERE/regen-patches.sh" "$BRANCH" "$BASE"
else
    echo
    echo "==> --no-regen：补丁文件没动，需要时跑 $HERE/regen-patches.sh"
fi
