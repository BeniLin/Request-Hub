#!/usr/bin/env bash
# 步驟 8：驗證（E 待驗證 → F 待審查，或退回 C 待實作）
# 由 jenkins/verify/Jenkinsfile 分階段呼叫：list → prepare → （部署）→ test → report
# 需要的指令：git、docker、curl、jq、tar、base64
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/jenkins/lib/jira.sh"
source "$ROOT/jenkins/lib/common.sh"

STATUS_FROM="E 待驗證"
STATUS_PASS="F 待審查"
STATUS_FAIL="C 待實作"

# 列出要處理的單號（每行一個）。有單子時順便準備好 repo。
cmd_list() {
  local jql list
  jql="project = \"$PROJECT_KEY\" AND status = \"$STATUS_FROM\" AND issuetype not in subTaskIssueTypes() AND (\"$LOCK_FIELD_NAME\" is EMPTY OR \"$LOCK_FIELD_NAME\" < -$LOCK_TIMEOUT) ORDER BY priority DESC, created ASC"
  list="$(jira_search "$jql" "${MAX_TICKETS:-2}")"
  [[ -n "$list" ]] || return 0
  clone_repo >&2
  printf '%s\n' "$list"
}

# 鎖單並檢查分支。結束代碼：0 可以部署；10 這張單驗證失敗（原因已記錄）
cmd_prepare() {
  local key="$1" r
  valid_key "$key"
  r="$(report_dir "$key")"
  rm -f "$r/reason" "$r/reason-log" "$r/sha"
  load_field_ids "$key"
  log "==== $key：開始驗證 ===="
  jira_lock "$key" "$LOCK_ID"

  if ! git_auth -C "$REPO_DIR" ls-remote --exit-code --heads origin "feature/$key" >/dev/null 2>&1; then
    set_reason "$key" "找不到分支 feature/$key"; exit 10
  fi
  # 驗證的對象是「分支加上最新的基準分支」，也就是合併後實際會上線的內容
  run_step "$r/sync.log" sync_base_into_feature "$key"
  if (( STEP_RC != 0 )); then
    set_reason "$key" "與 $BASE_BRANCH 合併時發生衝突，需要先同步 $BASE_BRANCH 並解決衝突" "$r/sync.log"; exit 10
  fi
  git -C "$REPO_DIR" rev-parse HEAD > "$r/sha"

  run_step "$r/protected.log" check_protected
  if (( STEP_RC != 0 )); then
    set_reason "$key" "實作階段修改了受保護的檔案（specs/ 或 tests/e2e/）" "$r/protected.log"; exit 10
  fi
  if [[ ! -d "$REPO_DIR/tests/e2e/$key" ]]; then
    set_reason "$key" "分支上找不到 tests/e2e/$key"; exit 10
  fi
  push_feature_if_changed "$key"
}

cmd_test() {
  valid_key "$1"
  log "$1：執行自動化測試"
  test_ticket "$1"
}

cmd_deploy_failed() {
  valid_key "$1"
  record_deploy_failure "$1" "${2:-}" "${3:-}"
}

# 寫回 Jira：附件、留言、轉換狀態、解鎖
cmd_report() {
  local key="$1" cur reason
  valid_key "$key"
  load_field_ids "$key"
  reason="$(get_reason "$key")"
  cur="$(jira_status "$key")"
  if [[ "$cur" != "$STATUS_FROM" ]]; then
    log "$key 的狀態已變為「$cur」，放棄寫回"
    jira_unlock "$key" "$LOCK_ID"
    return 0
  fi
  publish_result "$key" "【驗證通過】步驟 8（Jenkins 自動驗證）" "【驗證失敗】步驟 8（Jenkins 自動驗證）" \
    "標示為「人工驗證」的 Test Case 沒有自動執行，審查時請依 tests/e2e/$key/README.md 的對照表操作確認。"
  if [[ -z "$reason" ]]; then
    jira_transition_to "$key" "$STATUS_PASS"
    log "$key：驗證通過 → $STATUS_PASS"
  else
    jira_increment "$key" "$RETRY_ID"
    jira_transition_to "$key" "$STATUS_FAIL"
    log "$key：$reason → $STATUS_FAIL"
  fi
  jira_unlock "$key" "$LOCK_ID"
}

cmd_unlock() {
  valid_key "$1"
  load_field_ids "$1"
  jira_unlock "$1" "$LOCK_ID"
}

case "${1:-}" in
  list)          cmd_list ;;
  prepare)       cmd_prepare "$2" ;;
  test)          cmd_test "$2" ;;
  deploy-failed) cmd_deploy_failed "$2" "${3:-}" "${4:-}" ;;
  report)        cmd_report "$2" ;;
  unlock)        cmd_unlock "$2" ;;
  *) log "用法：run.sh <list|prepare|test|deploy-failed|report|unlock> [單號]"; exit 2 ;;
esac
