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

# 「處理中」「退回次數」的欄位 ID。以傳入的單號查詢（同一個專案的單子欄位相同），查一次後快取。
# 用法：load_field_ids <單號>
load_field_ids() {
  local cache="$WORK/field-ids" lock retry
  if [[ ! -s "$cache" ]]; then
    mkdir -p "$WORK"
    lock="$(jira_field_id "$LOCK_FIELD_NAME" "$1")"
    retry="$(jira_field_id "$RETRY_FIELD_NAME" "$1")"
    printf '%s\n%s\n' "$lock" "$retry" > "$cache"
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

# 取得 feature/<單號>，並把最新的基準分支併進來（在本機，不推送）。
# 驗證與合併都以「分支加上最新的基準分支」為對象：分支落後基準分支時，資料庫結構、設定檔可能對不上而無法部署。
# 有衝突時印出衝突的檔案並回傳 1。
sync_base_into_feature() {
  fetch_refs
  git -C "$REPO_DIR" checkout --quiet --force --detach "origin/feature/$1"
  git -C "$REPO_DIR" clean -fdxq
  if ! git -C "$REPO_DIR" merge --no-ff --no-edit -m "merge: 同步 $BASE_BRANCH 到 feature/$1" "origin/$BASE_BRANCH"; then
    echo "與 $BASE_BRANCH 衝突的檔案："
    git -C "$REPO_DIR" diff --name-only --diff-filter=U
    git -C "$REPO_DIR" merge --abort
    return 1
  fi
}

# 同步後如果多了合併的 commit，把它推回 feature 分支，部署 Job 才拿得到
push_feature_if_changed() {
  if [[ "$(git -C "$REPO_DIR" rev-parse HEAD)" != "$(git -C "$REPO_DIR" rev-parse "origin/feature/$1")" ]]; then
    git_auth -C "$REPO_DIR" push --quiet origin "HEAD:refs/heads/feature/$1"
  fi
}

# 記錄部署失敗，並把部署 Job 的記錄（最後 200 行）存下來，讓 Jira 留言帶得出失敗原因。
# 用法：record_deploy_failure <單號> <部署記錄網址> <部署的建置編號>
record_deploy_failure() {
  local key="$1" url="${2:-}" num="${3:-}" r src=""
  r="$(report_dir "$key")"
  if [[ -n "$num" && -n "${JENKINS_HOME:-}" && -n "${DEPLOY_JOB:-}" ]]; then
    src="$JENKINS_HOME/jobs/${DEPLOY_JOB//\//\/jobs\/}/builds/$num/log"
  fi
  if [[ -n "$src" && -r "$src" ]]; then
    # 去掉 Jenkins 寫在記錄裡的隱藏標記
    sed -e 's/\x1b\[8m[^\x1b]*\x1b\[0m//g' "$src" | tail -n 200 > "$r/deploy.log"
    set_reason "$key" "分支無法部署到驗證環境（部署記錄：${url:-無}）" "$r/deploy.log"
  else
    set_reason "$key" "分支無法部署到驗證環境（部署記錄：${url:-無}）"
  fi
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

# 把截圖與測試報告上傳到雲端硬碟，成功時印出資料夾的網址。
# 需要：Job 參數 ARTIFACT_REMOTE（rclone 的目的地，例如 gdrive:AutoDeveloper/ZHC）、
#       憑證檔 RCLONE_CONFIG_FILE（rclone 的設定檔）、Jenkins 上安裝了 rclone。
# 沒有設定時回傳 1（不算錯誤）。上傳後的資料夾：<目的地>/<單號>/<時間>-<commit>/
upload_artifacts() {
  local key="$1" r="$2" sha="${3:-}" conf stage name parent f id
  [[ -n "${ARTIFACT_REMOTE:-}" && -n "${RCLONE_CONFIG_FILE:-}" && -f "${RCLONE_CONFIG_FILE:-}" ]] || return 1
  command -v rclone >/dev/null 2>&1 || { log "已設定 ARTIFACT_REMOTE，但 Jenkins 上找不到 rclone"; return 1; }
  [[ -d "$r/test-results" || -d "$r/playwright-report" ]] || return 1

  # rclone 會把更新後的權杖寫回設定檔，所以用一份可以寫入的副本
  conf="$WORK/rclone.conf"
  cp "$RCLONE_CONFIG_FILE" "$conf" && chmod 600 "$conf"
  stage="$r/upload"
  rm -rf "$stage" && mkdir -p "$stage/screenshots"
  if [[ -d "$r/test-results" ]]; then
    while IFS= read -r -d '' f; do
      cp "$f" "$stage/screenshots/$(basename "$(dirname "$f")")-$(basename "$f")"
    done < <(find "$r/test-results" -name '*.png' -print0)
  fi
  if [[ -d "$r/playwright-report" ]]; then
    tar -czf "$stage/playwright-report.tar.gz" -C "$r" playwright-report
  fi
  [[ -f "$r/e2e.log" ]] && cp "$r/e2e.log" "$stage/e2e.log"

  name="$(date +%Y%m%d-%H%M%S)-${sha:0:8}"
  parent="${ARTIFACT_REMOTE%/}/$key"
  if ! rclone --config "$conf" copy "$stage" "$parent/$name" >&2; then
    rm -f "$conf"; rm -rf "$stage"
    log "上傳到 $parent/$name 失敗"
    return 1
  fi
  id="$(rclone --config "$conf" lsjson "$parent" --dirs-only 2>/dev/null | jq -r --arg n "$name" '.[] | select(.Name == $n) | .ID' 2>/dev/null || true)"
  rm -f "$conf"; rm -rf "$stage"
  if [[ -n "$id" ]]; then
    printf 'https://drive.google.com/drive/folders/%s\n' "$id"
  else
    printf '%s\n' "$parent/$name"
  fi
}

# 把測試結果寫到 Jira：上傳截圖與報告，新增留言。
# 用法：publish_result <單號> <通過時的標題> <失敗時的標題> [留言最後要加的一段話] [通過時給人看的摘要]
# 留言的第一行是標記，接著是給人看的摘要，分隔線之後才是細節。
publish_result() {
  local key="$1" title_ok="$2" title_fail="$3" extra="${4:-}" summary_ok="${5:-}"
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
  # 把錯誤訊息歸類：相同的訊息合併計數，讓留言看得出「為什麼」失敗，而不只是「哪些」失敗
  local error_summary="" total=0
  if [[ -f "$r/results.json" ]]; then
    error_summary="$(jq -r '
      [.. | objects | select(has("status") and has("errors") and (.status == "failed" or .status == "timedOut"))
        | (.errors[0].message // .error.message // "（沒有錯誤訊息）")
        | gsub("\u001b\\[[0-9;]*m"; "") | split("\n")
        | map(select(test("\\S"))) | .[0:3] | join(" / ") | .[0:300]]
      | group_by(.) | map({n: length, m: .[0]}) | sort_by(-.n) | .[0:6]
      | .[] | "- \(.n) 個測試：\(.m)"' "$r/results.json" 2>/dev/null || true)"
    total=$(( passed + failed + flaky ))
  fi

  # 截圖與測試報告：有設定雲端硬碟時上傳到那裡，Jira 只放連結；沒有設定或上傳失敗時，
  # 只在通過時把截圖附到 Jira（給人審查畫面用）。測試報告一律不附到 Jira，它保存在 Jenkins 的建置產出物。
  local storage_line="" drive_url=""
  if [[ -d "$r/test-results" ]]; then
    shots="$(find "$r/test-results" -name '*.png' | wc -l)"
  fi
  if drive_url="$(upload_artifacts "$key" "$r" "$sha")" && [[ -n "$drive_url" ]]; then
    storage_line="截圖與測試報告：$drive_url（截圖 $shots 張）"
  else
    local attached=0
    if [[ -z "$reason" && -d "$r/test-results" ]]; then
      while IFS= read -r -d '' f; do
        name="$(basename "$(dirname "$f")")-$(basename "$f")"
        if jira_attach "$key" "$f" "$name"; then attached=$(( attached + 1 )); fi
      done < <(find "$r/test-results" -name '*.png' -print0 | sort -z | head -z -n 60)
      storage_line="截圖：已附加 $attached 張。完整的測試報告在 Jenkins 的建置產出物"
    else
      storage_line="截圖與測試報告：保存在 Jenkins 的建置產出物（共 $shots 張截圖）"
    fi
    if [[ -n "${ARTIFACT_REMOTE:-}" ]]; then
      storage_line+="（上傳到雲端硬碟失敗，請看 Jenkins 的記錄）"
    fi
  fi

  # 給人看的摘要
  local summary
  if [[ -z "$reason" ]]; then
    summary="${summary_ok:-$passed 條自動測試全部通過。}"
  elif (( total == 0 )); then
    summary="還沒開始跑測試就停下來了：$reason。單子已退回「待實作」，會由實作步驟接手，目前不需要你處理。"
  elif (( total >= 5 && failed * 5 >= total * 4 )); then
    summary="$total 條自動測試有 $failed 條沒通過。幾乎全部失敗，比較像是測試環境、測試帳號或測試腳本的共同問題，不是每個功能都壞了。單子已退回「待實作」；實作步驟如果判斷不是程式的問題，會轉到「待人工處理」請你決定。"
  else
    summary="$total 條自動測試有 $failed 條沒通過。單子已退回「待實作」，會由實作步驟修正後再送回來驗證，目前不需要你處理。"
  fi

  if [[ -z "$reason" ]]; then text="$title_ok"; else text="$title_fail"; fi
  text+="

摘要：$summary

----

分支：feature/$key${sha:+（commit ${sha:0:8}）}
Jenkins：${BUILD_URL:-（本機執行）}

自動化測試：通過 $passed、失敗 $failed、不穩定 $flaky、略過 $skipped
$storage_line"
  if [[ -n "$reason" ]]; then
    text+="

失敗原因：$reason"
    if [[ -n "$error_summary" ]]; then
      text+="

錯誤訊息（相同的合併計算）：
$error_summary"
    fi
    if (( total >= 5 && failed * 5 >= total * 4 )); then
      text+="

注意：絕大多數的測試都失敗了。這通常代表共同的原因（測試帳號無法登入、網址或連接埠不對、測試環境缺少前置資料），不是每個功能各自有問題。請先看上面出現最多次的錯誤訊息和截圖。"
    fi
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
