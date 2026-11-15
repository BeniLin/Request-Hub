#!/usr/bin/env bash
# 步驟 8 與步驟 12 共用的函式。由各步驟的 run.sh source。
# 這裡不包含任何專案的部署細節：系統怎麼部署、部署到哪裡，由各專案自己的部署 Job 負責。

WORK="${WORKSPACE:-$ROOT}/work"
REPO_DIR="$WORK/repo"
REPORTS="$WORK/reports"
E2E_IMAGE="${E2E_IMAGE:-mcr.microsoft.com/playwright:v1.49.1-noble}"
LOCK_FIELD_NAME="處理中"
RETRY_FIELD_NAME="退回次數"
LOCK_TIMEOUT="2h"
STATUS_RELEASED="J 已發版"

log() { echo "$*" >&2; }

# 單號會被帶進指令，先確認格式
valid_key() {
  [[ "$1" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]] || { log "單號格式不正確：$1"; exit 2; }
}

report_dir() { mkdir -p "$REPORTS/$1"; printf '%s' "$REPORTS/$1"; }

# 記錄這張單失敗的原因。用法：set_reason <單號> <原因> [相關的 log 檔]
set_reason() {
  local r; r="$(report_dir "$1")"
  printf '%s' "$2" > "$r/reason"
  printf '%s' "${3:-}" > "$r/reason-log"
}
get_reason() { cat "$REPORTS/$1/reason" 2>/dev/null || true; }

# 「處理中」「退回次數」的欄位 ID（查一次後快取）
load_field_ids() {
  local cache="$WORK/field-ids"
  if [[ ! -s "$cache" ]]; then
    mkdir -p "$WORK"
    { jira_field_id "$LOCK_FIELD_NAME"; jira_field_id "$RETRY_FIELD_NAME"; } > "$cache"
  fi
  LOCK_ID="$(sed -n 1p "$cache")"
  RETRY_ID="$(sed -n 2p "$cache")"
}

# 帶認證的 git（token 不會出現在網址或 log 中）
git_auth() {
  local auth
  auth="$(printf '%s:%s' "$GIT_USER" "$GIT_TOKEN" | base64 | tr -d '\n')"
  git -c credential.helper= -c "http.extraHeader=Authorization: Basic $auth" "$@"
}

# 重新 clone 專案 repo 到工作目錄
clone_repo() {
  rm -rf "$WORK"
  mkdir -p "$REPORTS"
  git_auth clone --quiet "https://github.com/$PROJECT_REPO.git" "$REPO_DIR"
  git -C "$REPO_DIR" config user.name "${GIT_COMMIT_NAME:-jenkins-bot}"
  git -C "$REPO_DIR" config user.email "${GIT_COMMIT_EMAIL:-jenkins-bot@users.noreply.github.com}"
}

fetch_refs() {
  git_auth -C "$REPO_DIR" fetch --quiet --prune --tags origin '+refs/heads/*:refs/remotes/origin/*'
}

# 執行一個步驟並把輸出寫到 log，結果放在 STEP_RC，不會中斷腳本。
# 必須當成獨立的一行呼叫（不要接在 if 或 || 後面），步驟內的錯誤才會被正確偵測。
STEP_RC=0
run_step() {
  local logfile="$1"; shift
  set +e
  ( set -e; "$@" ) >"$logfile" 2>&1
  STEP_RC=$?
  set -e
}

# 受保護的資料夾只能由特定步驟修改，以 commit 訊息的前綴判斷：
#   specs/      只能出現在 spec(...) 開頭的 commit（步驟 3）
#   tests/e2e/  只能出現在 test(...) 開頭的 commit（步驟 5）
check_protected() {
  local sha subject files bad=0
  while read -r sha; do
    subject="$(git -C "$REPO_DIR" log -1 --format=%s "$sha")"
    files="$(git -C "$REPO_DIR" diff-tree --no-commit-id --name-only -r "$sha")"
    if grep -q '^specs/' <<<"$files" && [[ "$subject" != spec\(* ]]; then
      echo "commit ${sha:0:8}「$subject」修改了 specs/"; bad=1
    fi
    if grep -q '^tests/e2e/' <<<"$files" && [[ "$subject" != test\(* ]]; then
      echo "commit ${sha:0:8}「$subject」修改了 tests/e2e/"; bad=1
    fi
  done < <(git -C "$REPO_DIR" log --no-merges --format=%H "origin/$BASE_BRANCH..HEAD")
  return $bad
}

# 對已部署的環境執行這張單的 Playwright 測試。
# 測試在 Jenkins 上的容器中執行，透過網址連到受測系統，系統可以在任何機器上。
# 傳給測試的環境變數：E2E_BASE_URL（Job 參數），以及 E2E_ENV_FILE（選用的憑證檔，每行 KEY=VALUE）的內容。
run_e2e() {
  local key="$1" rdir="$2" envfile="$WORK/e2e.env" cid rc=0 p
  echo "E2E_BASE_URL=$E2E_BASE_URL" > "$envfile"
  if [[ -n "${E2E_ENV_FILE:-}" && -f "$E2E_ENV_FILE" ]]; then
    grep -Ev '^[[:space:]]*(#|$)' "$E2E_ENV_FILE" | sed 's/\r$//' >> "$envfile"
  fi
  cid="$(docker create --network host --ipc=host --env-file "$envfile" \
    -e CI=1 -e PLAYWRIGHT_HTML_OPEN=never -e PLAYWRIGHT_JSON_OUTPUT_NAME=results.json \
    -w /e2e "$E2E_IMAGE" sh -c \
    '(npm ci || npm install) && npx playwright install chromium && npx playwright test "$0/" --reporter=list,json,html' \
    "$key")"
  rm -f "$envfile"
  docker cp "$REPO_DIR/tests/e2e/." "$cid:/e2e"
  docker start -a "$cid" || rc=$?
  rm -rf "$rdir/results.json" "$rdir/test-results" "$rdir/playwright-report"
  for p in results.json test-results playwright-report; do
    docker cp "$cid:/e2e/$p" "$rdir/" 2>/dev/null || true
  done
  docker rm -f "$cid" >/dev/null
  return $rc
}

# 執行測試並記錄結果（失敗時寫入原因，不中斷）
test_ticket() {
  local key="$1" r
  r="$(report_dir "$key")"
  run_step "$r/e2e.log" run_e2e "$key" "$r"
  if (( STEP_RC != 0 )); then
    set_reason "$key" "自動化測試未全部通過" "$r/e2e.log"
  elif [[ ! -f "$r/results.json" || "$(jq '.stats.expected // 0' "$r/results.json")" -eq 0 ]]; then
    set_reason "$key" "沒有執行到任何測試" "$r/e2e.log"
  fi
}

# 把測試結果寫到 Jira：上傳截圖與報告，新增留言。
# 用法：publish_result <單號> <通過時的標題> <失敗時的標題> [留言最後要加的一段話]
publish_result() {
  local key="$1" title_ok="$2" title_fail="$3" extra="${4:-}"
  local r reason rlog sha passed=0 failed=0 flaky=0 skipped=0 failed_list="" shots=0 f name text
  r="$(report_dir "$key")"
  reason="$(get_reason "$key")"
  rlog="$(cat "$r/reason-log" 2>/dev/null || true)"
  sha="$(cat "$r/sha" 2>/dev/null || true)"

  if [[ -f "$r/results.json" ]]; then
    passed="$(jq '.stats.expected // 0' "$r/results.json")"
    failed="$(jq '.stats.unexpected // 0' "$r/results.json")"
    flaky="$(jq '.stats.flaky // 0' "$r/results.json")"
    skipped="$(jq '.stats.skipped // 0' "$r/results.json")"
    failed_list="$(jq -r '[.. | objects | select(has("ok") and has("title") and has("tests") and .ok == false) | .title] | unique | .[]' "$r/results.json")"
  fi

  # 截圖最多 60 張，檔名加上所在資料夾，避免全部同名
  if [[ -d "$r/test-results" ]]; then
    while IFS= read -r -d '' f; do
      name="$(basename "$(dirname "$f")")-$(basename "$f")"
      if jira_attach "$key" "$f" "$name"; then shots=$(( shots + 1 )); fi
    done < <(find "$r/test-results" -name '*.png' -print0 | sort -z | head -z -n 60)
  fi
  if [[ -d "$r/playwright-report" ]]; then
    tar -czf "$r/playwright-report.tar.gz" -C "$r" playwright-report
    jira_attach "$key" "$r/playwright-report.tar.gz" "playwright-report-${sha:0:8}.tar.gz" || true
  fi
  if [[ -n "$reason" && -n "$rlog" && -s "$rlog" ]]; then
    jira_attach "$key" "$rlog" "$(basename "$rlog" | sed 's/\.[a-z]*$//')-${sha:0:8}.log" || true
  fi

  if [[ -z "$reason" ]]; then text="$title_ok"; else text="$title_fail"; fi
  text+="

分支：feature/$key${sha:+（commit ${sha:0:8}）}
Jenkins：${BUILD_URL:-（本機執行）}

自動化測試：通過 $passed、失敗 $failed、不穩定 $flaky、略過 $skipped
截圖：已附加 $shots 張"
  if [[ -n "$reason" ]]; then
    text+="

失敗原因：$reason"
    if [[ -n "$failed_list" ]]; then
      text+="

未通過的測試：
$(sed 's/^/- /' <<<"$failed_list")"
    fi
    if [[ -n "$rlog" && -s "$rlog" ]]; then
      text+="

記錄（最後 30 行，完整內容見附件）：
{noformat}
$(tail -n 30 "$rlog")
{noformat}"
    fi
  fi
  if [[ "$skipped" -gt 0 ]]; then
    text+="

注意：有 $skipped 個測試被略過，審查時請確認原因。"
  fi
  if [[ -n "$extra" ]]; then
    text+="

$extra"
  fi
  jira_comment "$key" "$text"
}
