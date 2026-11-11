#!/usr/bin/env bash
# 唯讀：從 GitHub 讀取專案 repo 的文件。不會修改任何東西。
#
# 用法：
#   bash scripts/read-spec.sh <專案KEY> <檔案路徑> [分支]
#   bash scripts/read-spec.sh --list <專案KEY> <資料夾路徑> [分支]
#
# 未指定分支時，使用 projects/registry.csv 設定的主分支。
# 只能讀取 registry.csv 中 read_dirs 欄位允許的資料夾。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$ROOT/projects/registry.csv"

usage() {
  echo "用法：bash scripts/read-spec.sh [--list] <專案KEY> <路徑> [分支]" >&2
  exit 2
}

fail() {
  echo "錯誤：$*" >&2
  exit 1
}

# 將路徑做 URL 編碼（支援中文檔名與空白）
urlencode() {
  local LC_ALL=C s="$1" out="" c i hex
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~/-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

mode="read"
if [[ "${1:-}" == "--list" ]]; then
  mode="list"
  shift
fi

key="${1:-}"
path="${2:-}"
ref="${3:-}"
[[ -n "$key" && -n "$path" ]] || usage
[[ $# -le 3 ]] || usage

command -v gh >/dev/null 2>&1 || fail "找不到 gh 指令，請先執行工作區根目錄的 setup。"
[[ -f "$REGISTRY" ]] || fail "找不到 $REGISTRY"

# 從 registry.csv 找出專案設定（去除 Windows 換行符號）
row="$(tr -d '\r' < "$REGISTRY" | awk -F',' -v k="$key" 'NR > 1 && $1 == k { print; exit }')"
[[ -n "$row" ]] || fail "registry.csv 中找不到專案 $key"

IFS=',' read -r _key _name repo branch _specs_dir read_dirs <<< "$row"
[[ -n "$repo" && -n "$branch" ]] || fail "專案 $key 的 repo 或 branch 設定不完整"

ref="${ref:-$branch}"

# 檢查路徑：不可為絕對路徑、不可包含 ..
path="${path#./}"
path="${path%/}"
[[ "$path" != /* ]] || fail "路徑不可以 / 開頭：$path"
[[ "$path" != *..* ]] || fail "路徑不可包含 ..：$path"

# 檢查分支名稱
[[ "$ref" =~ ^[A-Za-z0-9._/-]+$ && "$ref" != *..* ]] || fail "分支名稱格式不正確：$ref"

# 檢查路徑是否在允許讀取的資料夾內
allowed=0
IFS=';' read -r -a dirs <<< "${read_dirs:-}"
for d in "${dirs[@]}"; do
  d="${d%/}"
  [[ -z "$d" ]] && continue
  if [[ "$path" == "$d" || "$path" == "$d"/* ]]; then
    allowed=1
    break
  fi
done
[[ $allowed -eq 1 ]] || fail "不允許讀取此路徑：$path（允許的資料夾：${read_dirs:-未設定}）"

endpoint="repos/$repo/contents/$(urlencode "$path")?ref=$(urlencode "$ref")"

if [[ "$mode" == "list" ]]; then
  if ! out="$(gh api "$endpoint" --jq 'if type == "array" then .[] | "\(.type)\t\(.path)" else "file\t\(.path)" end' 2>&1)"; then
    fail "無法列出 $repo@$ref:$path
$out"
  fi
  printf '%s\n' "$out"
else
  if ! out="$(gh api -H "Accept: application/vnd.github.raw+json" "$endpoint" 2>&1)"; then
    fail "無法讀取 $repo@$ref:$path（檔案不存在、路徑是資料夾，或沒有權限）
$out"
  fi
  printf '%s\n' "$out"
fi
