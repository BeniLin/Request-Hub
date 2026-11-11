#!/usr/bin/env bash
# 唯讀：讀取專案 repo 的 Pull Request 資訊。不會修改任何東西。
#
# 用法：
#   bash scripts/read-pr.sh <專案KEY> view   <PR編號>   PR 標題、說明、狀態、審查紀錄
#   bash scripts/read-pr.sh <專案KEY> files  <PR編號>   修改的檔案清單與增減行數
#   bash scripts/read-pr.sh <專案KEY> diff   <PR編號>   完整 diff
#   bash scripts/read-pr.sh <專案KEY> checks <PR編號>   CI 檢查結果

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$ROOT/projects/registry.csv"

usage() {
  echo "用法：bash scripts/read-pr.sh <專案KEY> <view|files|diff|checks> <PR編號>" >&2
  exit 2
}

fail() {
  echo "錯誤：$*" >&2
  exit 1
}

[[ $# -eq 3 ]] || usage
key="$1"
action="$2"
pr="$3"

[[ "$pr" =~ ^[0-9]+$ ]] || fail "PR 編號必須是數字：$pr"
command -v gh >/dev/null 2>&1 || fail "找不到 gh 指令，請先執行工作區根目錄的 setup。"
[[ -f "$REGISTRY" ]] || fail "找不到 $REGISTRY"

row="$(tr -d '\r' < "$REGISTRY" | awk -F',' -v k="$key" 'NR > 1 && $1 == k { print; exit }')"
[[ -n "$row" ]] || fail "registry.csv 中找不到專案 $key"
IFS=',' read -r _key _name repo _rest <<< "$row"
[[ -n "$repo" ]] || fail "專案 $key 的 repo 設定不完整"

case "$action" in
  view)
    gh pr view "$pr" -R "$repo" \
      --json number,title,body,state,headRefName,baseRefName,author,createdAt,updatedAt,reviews,comments
    ;;
  files)
    gh pr view "$pr" -R "$repo" --json files \
      --jq '.files[] | "\(.path)\t+\(.additions)\t-\(.deletions)"'
    ;;
  diff)
    gh pr diff "$pr" -R "$repo" --color never
    ;;
  checks)
    # 有檢查失敗時 gh 會回傳非 0，這裡仍然要顯示結果
    gh pr checks "$pr" -R "$repo" || true
    ;;
  *)
    usage
    ;;
esac
