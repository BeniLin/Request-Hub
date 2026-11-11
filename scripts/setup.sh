#!/usr/bin/env bash
# 需求工作區初始設定（Mac / Linux）
# 用法：在工作區根目錄執行 bash scripts/setup.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

step() { printf '\n== %s ==\n' "$1"; }
ok()   { printf '  [OK] %s\n' "$1"; }
bad()  { printf '  [X]  %s\n' "$1"; }
has_problem=0

step "檢查 GitHub CLI（gh）"
if ! command -v gh >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install gh
  else
    bad "找不到 gh，請依 https://cli.github.com 的說明安裝後重新執行。"
    exit 1
  fi
fi
ok "$(gh --version | head -1)"

step "檢查 GitHub 登入狀態"
if gh auth status --hostname github.com >/dev/null 2>&1; then
  ok "已登入 GitHub"
else
  echo "  即將開啟瀏覽器登入 GitHub，請依畫面指示操作。"
  gh auth login --hostname github.com --git-protocol https --web || { bad "GitHub 登入失敗"; exit 1; }
  ok "登入完成"
fi

step "檢查各專案規格的讀取權限"
while IFS=',' read -r key _name repo branch specs_dir _dirs; do
  [[ "$key" == "key" || -z "$key" ]] && continue
  if gh api "repos/$repo/contents/$specs_dir/INDEX.md?ref=$branch" --silent >/dev/null 2>&1; then
    ok "$key（$repo）"
  else
    bad "$key（$repo）：讀不到 $specs_dir/INDEX.md。可能是沒有 repo 權限、repo 名稱錯誤，或尚未建立索引檔。"
    has_problem=1
  fi
done < <(tr -d '\r' < projects/registry.csv)

step "更新需求工作區"
if git pull --ff-only --quiet >/dev/null 2>&1; then ok "已是最新版"; else bad "自動更新失敗，請稍後手動執行 git pull。"; fi

step "完成"
[[ $has_problem -eq 1 ]] && echo "  部分專案讀取失敗，請將上方訊息提供給工作區管理員。"
cat <<MSG

接下來：
  1. 開啟 Claude Desktop，切換到 Code 分頁
  2. 選擇這個資料夾：$ROOT
  3. 第一次開啟時，選擇信任這個資料夾
  4. 輸入 /mcp，選擇 jira，用瀏覽器登入你的 Atlassian 帳號
  5. 直接描述你的需求，例如「我想討論一個 SHOP 的新需求」

MSG
