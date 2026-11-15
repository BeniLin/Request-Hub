#!/usr/bin/env bash
# 步驟 12：發版（I 待發版 → J 已發版，或退回 C 待實作）
# 由 jenkins/release/Jenkinsfile 分階段呼叫，分成兩個動作：
#   合併：list-merge → merge-prepare → （部署）→ test → merge-finish
#   發版：release-prepare → （部署）→ release-finish
# 需要的指令：git、docker、curl、jq、tar、base64
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/jenkins/lib/jira.sh"
source "$ROOT/jenkins/lib/common.sh"

STATUS_FROM="I 待發版"
STATUS_FAIL="C 待實作"
RELEASE_BRANCH="${RELEASE_BRANCH:-main}"

g() { git -C "$REPO_DIR" "$@"; }
branch_exists() { g rev-parse --verify -q "origin/feature/$1" >/dev/null; }
is_merged() { g merge-base --is-ancestor "origin/feature/$1" "origin/$BASE_BRANCH"; }

# ---------- 合併 ----------

# 列出這次要合併的單號。跳過：找不到分支、已經合併、還被其他單阻擋的。
cmd_list_merge() {
  local jql list key blockers bkey bstatus blocked count=0
  jql="project = \"$PROJECT_KEY\" AND status = \"$STATUS_FROM\" AND issuetype not in subTaskIssueTypes() AND (\"$LOCK_FIELD_NAME\" is EMPTY OR \"$LOCK_FIELD_NAME\" < -$LOCK_TIMEOUT) ORDER BY priority DESC, created ASC"
  list="$(jira_search "$jql" 50)"
  [[ -n "$list" ]] || return 0
  clone_repo >&2
  load_field_ids
  while read -r key; do
    [[ -n "$key" ]] || continue
    if ! branch_exists "$key"; then log "$key：找不到分支 feature/$key，跳過"; continue; fi
    if is_merged "$key"; then log "$key：已經合併進 $BASE_BRANCH，等待發版"; continue; fi
    blockers="$(jira_blockers "$key")"
    blocked=""
    while IFS=$'\t' read -r bkey bstatus; do
      [[ -n "$bkey" ]] || continue
      [[ "$bstatus" == "$STATUS_RELEASED" ]] && continue
      if branch_exists "$bkey" && is_merged "$bkey"; then continue; fi
      blocked+="$bkey（$bstatus） "
    done <<<"$blockers"
    if [[ -n "$blocked" ]]; then log "$key：被 $blocked阻擋，跳過"; continue; fi
    printf '%s\n' "$key"
    count=$(( count + 1 ))
    (( count >= ${MAX_TICKETS:-5} )) && break
  done <<<"$list"
  return 0
}

merge_base_into_feature() {
  fetch_refs
  g checkout --quiet --force --detach "origin/feature/$1"
  g clean -fdxq
  if ! g merge --no-ff --no-edit -m "merge: 同步 $BASE_BRANCH 到 feature/$1" "origin/$BASE_BRANCH"; then
    echo "與 $BASE_BRANCH 衝突的檔案："
    g diff --name-only --diff-filter=U
    g merge --abort
    return 1
  fi
}

# 鎖單、把最新的基準分支併進功能分支並推上去。結束代碼：0 可以部署；10 這張單失敗（原因已記錄）
cmd_merge_prepare() {
  local key="$1" r
  valid_key "$key"
  r="$(report_dir "$key")"
  rm -f "$r/reason" "$r/reason-log" "$r/sha"
  load_field_ids
  log "==== $key：準備合併 ===="
  jira_lock "$key" "$LOCK_ID"

  run_step "$r/sync.log" merge_base_into_feature "$key"
  if (( STEP_RC != 0 )); then
    set_reason "$key" "與 $BASE_BRANCH 合併時發生衝突，需要重新實作以解決衝突" "$r/sync.log"; exit 10
  fi
  g rev-parse HEAD > "$r/sha"

  run_step "$r/protected.log" check_protected
  if (( STEP_RC != 0 )); then
    set_reason "$key" "實作階段修改了受保護的檔案（specs/ 或 tests/e2e/）" "$r/protected.log"; exit 10
  fi
  if [[ ! -d "$REPO_DIR/tests/e2e/$key" ]]; then
    set_reason "$key" "分支上找不到 tests/e2e/$key"; exit 10
  fi
  # 把同步後的分支推上去，部署 Job 才拿得到
  git_auth -C "$REPO_DIR" push --quiet origin "HEAD:refs/heads/feature/$key"
}

merge_feature_into_base() {
  fetch_refs
  g checkout --quiet --force -B "$BASE_BRANCH" "origin/$BASE_BRANCH"
  g merge --no-ff -m "merge($1): $2" "origin/feature/$1"
  git_auth -C "$REPO_DIR" push --quiet origin "$BASE_BRANCH"
}

# 測試通過就合併進基準分支（單子維持在 I，等待發版）；失敗則退回 C
cmd_merge_finish() {
  local key="$1" r cur reason summary
  valid_key "$key"
  r="$(report_dir "$key")"
  load_field_ids
  reason="$(get_reason "$key")"
  cur="$(jira_status "$key")"
  if [[ "$cur" != "$STATUS_FROM" ]]; then
    log "$key 的狀態已變為「$cur」，放棄合併"
    jira_unlock "$key" "$LOCK_ID"
    return 0
  fi
  if [[ -n "$reason" ]]; then
    publish_result "$key" "" "【合併失敗】步驟 12（Jenkins）"
    jira_increment "$key" "$RETRY_ID"
    jira_transition_to "$key" "$STATUS_FAIL"
    jira_unlock "$key" "$LOCK_ID"
    log "$key：$reason → $STATUS_FAIL"
    return 0
  fi
  summary="$(jira_summary "$key")"
  merge_feature_into_base "$key" "$summary" > "$r/merge.log" 2>&1
  publish_result "$key" "【已合併】步驟 12（Jenkins）" "" \
    "已同步最新的 $BASE_BRANCH 並重新通過測試，已合併進 $BASE_BRANCH。單子維持在「$STATUS_FROM」，執行「發版」後才會轉為已發版。"
  jira_unlock "$key" "$LOCK_ID"
  log "$key：已合併進 $BASE_BRANCH"
}

# ---------- 發版 ----------

# 讀取 ChangeLog 片段 changes/<單號>.md。格式：
#   ---
#   type: feature        （feature、fix 或 breaking）
#   ---
#   - 給使用者看的變更說明
fragment_type() {
  local t
  t="$(sed -n '1,6s/^type:[[:space:]]*//p' "$1" | head -n 1 | tr -d '\r[:space:]')"
  case "$t" in breaking|feature|fix) printf '%s' "$t" ;; *) printf 'fix' ;; esac
}
fragment_body() {
  awk 'NR==1 && /^---/ {fm=1; next} fm==1 { if (/^---/) fm=0; next } {print}' "$1" | sed 's/\r$//' | sed '/^[[:space:]]*$/d'
}

next_version() {
  local last major minor patch
  last="$(g tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n 1)"
  last="${last#v}"
  IFS=. read -r major minor patch <<<"${last:-0.0.0}"
  case "$1" in
    breaking) major=$(( major + 1 )); minor=0; patch=0 ;;
    feature)  minor=$(( minor + 1 )); patch=0 ;;
    *)        patch=$(( patch + 1 )) ;;
  esac
  printf 'v%s.%s.%s' "$major" "$minor" "$patch"
}

# 找出已合併、等待發版的單，組合 ChangeLog、決定版號、合併進發版分支並標記版號。
# 結束代碼：0 完成；10 沒有可以發版的單
cmd_release_prepare() {
  local jql list key f type body bump="fix" version section tickets=()
  jql="project = \"$PROJECT_KEY\" AND status = \"$STATUS_FROM\" AND issuetype not in subTaskIssueTypes() ORDER BY priority DESC, created ASC"
  list="$(jira_search "$jql" 100)"
  [[ -n "$list" ]] || { log "沒有「$STATUS_FROM」的單"; exit 10; }
  clone_repo
  load_field_ids
  while read -r key; do
    [[ -n "$key" ]] || continue
    if branch_exists "$key" && is_merged "$key"; then tickets+=("$key"); else log "$key：尚未合併進 $BASE_BRANCH，這次不發版（請先執行「合併」）"; fi
  done <<<"$list"
  (( ${#tickets[@]} > 0 )) || { log "沒有已合併、等待發版的單"; exit 10; }
  printf '%s\n' "${tickets[@]}" > "$WORK/release-tickets"

  # 上一次發版已經把內容合併進發版分支、只是後續沒完成（例如部署失敗）：不重複建立版號
  if g merge-base --is-ancestor "origin/$BASE_BRANCH" "origin/$RELEASE_BRANCH"; then
    version="$(g tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n 1)"
    printf '%s' "${version:-（無版號）}" > "$WORK/release-version"
    log "$RELEASE_BRANCH 已包含 $BASE_BRANCH 的全部內容，沿用版本 ${version:-（無版號）}"
    return 0
  fi

  g checkout --quiet --force -B "$BASE_BRANCH" "origin/$BASE_BRANCH"
  : > "$WORK/cl-breaking"; : > "$WORK/cl-feature"; : > "$WORK/cl-fix"
  for key in "${tickets[@]}"; do
    f="$REPO_DIR/changes/$key.md"
    if [[ -f "$f" ]]; then
      type="$(fragment_type "$f")"
      body="$(fragment_body "$f")"
      g rm --quiet "changes/$key.md"
    else
      log "$key：找不到 changes/$key.md，改用單子標題"
      type="fix"
      body="- $(jira_summary "$key")"
    fi
    # 每一條說明後面補上單號
    sed -E "/^- /{/（$key）[[:space:]]*$/!s/[[:space:]]*$/（$key）/}" <<<"$body" >> "$WORK/cl-$type"
    case "$type" in
      breaking) bump="breaking" ;;
      feature)  [[ "$bump" == "breaking" ]] || bump="feature" ;;
    esac
  done
  version="$(next_version "$bump")"
  printf '%s' "$version" > "$WORK/release-version"

  section="$WORK/cl-section"
  {
    echo "## $version（$(date +%Y-%m-%d)）"
    if [[ -s "$WORK/cl-breaking" ]]; then echo; echo "### 破壞性變更"; echo; cat "$WORK/cl-breaking"; fi
    if [[ -s "$WORK/cl-feature" ]];  then echo; echo "### 新功能";     echo; cat "$WORK/cl-feature";  fi
    if [[ -s "$WORK/cl-fix" ]];      then echo; echo "### 修正";       echo; cat "$WORK/cl-fix";      fi
    echo
  } > "$section"
  f="$REPO_DIR/CHANGELOG.md"
  if [[ -f "$f" ]] && head -n 1 "$f" | grep -q '^# '; then
    { head -n 1 "$f"; echo; cat "$section"; tail -n +2 "$f" | sed '1{/^[[:space:]]*$/d}'; } > "$WORK/cl-new"
  elif [[ -f "$f" ]]; then
    { cat "$section"; cat "$f"; } > "$WORK/cl-new"
  else
    { echo "# Changelog"; echo; cat "$section"; } > "$WORK/cl-new"
  fi
  cp "$WORK/cl-new" "$f"
  g add CHANGELOG.md
  g commit --quiet -m "release: $version"

  g checkout --quiet --force -B "$RELEASE_BRANCH" "origin/$RELEASE_BRANCH"
  g merge --quiet --no-ff -m "release: $version" "$BASE_BRANCH"
  g tag -a "$version" -m "release: $version"
  git_auth -C "$REPO_DIR" push --quiet --atomic origin "$BASE_BRANCH" "$RELEASE_BRANCH" "refs/tags/$version"
  log "已建立版本 $version（${tickets[*]}）"
}

# 把發版結果寫回 Jira。用法：release-finish <deployed|manual|failed> [部署記錄網址]
cmd_release_finish() {
  local state="$1" url="${2:-}" version key cur text
  load_field_ids
  version="$(cat "$WORK/release-version")"
  case "$state" in
    deployed) text="【已發版】版本 $version，已合併進 $RELEASE_BRANCH 並完成部署。" ;;
    manual)   text="【已發版】版本 $version 已建立（已合併進 $RELEASE_BRANCH 並標記版號）。這個流程沒有設定正式環境的部署 Job，請自行部署。" ;;
    failed)   text="【發版未完成】版本 $version 已建立，但部署失敗（記錄：$url）。單子維持在「$STATUS_FROM」，排除問題後重新執行「發版」即可，不會重複建立版號。" ;;
    *) log "未知的狀態：$state"; exit 2 ;;
  esac
  while read -r key; do
    [[ -n "$key" ]] || continue
    cur="$(jira_status "$key")"
    if [[ "$cur" != "$STATUS_FROM" ]]; then log "$key 的狀態已變為「$cur」，略過"; continue; fi
    jira_comment "$key" "$text
Jenkins：${BUILD_URL:-（本機執行）}"
    if [[ "$state" != "failed" ]]; then
      jira_transition_to "$key" "$STATUS_RELEASED"
      log "$key → $STATUS_RELEASED"
    fi
  done < "$WORK/release-tickets"
}

cmd_unlock() {
  valid_key "$1"
  load_field_ids
  jira_unlock "$1" "$LOCK_ID"
}

case "${1:-}" in
  list-merge)      cmd_list_merge ;;
  merge-prepare)   cmd_merge_prepare "$2" ;;
  test)            valid_key "$2"; log "$2：執行自動化測試"; test_ticket "$2" ;;
  deploy-failed)   valid_key "$2"; set_reason "$2" "部署失敗，部署記錄：${3:-（無）}" ;;
  merge-finish)    cmd_merge_finish "$2" ;;
  release-prepare) cmd_release_prepare ;;
  release-finish)  cmd_release_finish "$2" "${3:-}" ;;
  unlock)          cmd_unlock "$2" ;;
  *) log "用法：run.sh <list-merge|merge-prepare|test|deploy-failed|merge-finish|release-prepare|release-finish|unlock> ..."; exit 2 ;;
esac
