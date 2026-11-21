#!/usr/bin/env bash
# Jira Cloud REST API 的共用函式。由其他腳本 source 使用。
# 需要的環境變數：JIRA_BASE_URL、JIRA_USER（帳號 email）、JIRA_TOKEN（API token）
# 需要的指令：curl、jq

# 呼叫 Jira API。用法：jira_api <METHOD> <PATH> [JSON]
# HTTP 400 以上視為失敗（回傳 1，錯誤內容印到 stderr）
jira_api() {
  local method="$1" path="$2" data="${3:-}" out code
  out="$(mktemp)"
  if [[ -n "$data" ]]; then
    code="$(curl -sS -o "$out" -w '%{http_code}' -u "$JIRA_USER:$JIRA_TOKEN" -X "$method" \
      -H 'Accept: application/json' -H 'Content-Type: application/json' \
      --data "$data" "$JIRA_BASE_URL$path")" || { rm -f "$out"; return 1; }
  else
    code="$(curl -sS -o "$out" -w '%{http_code}' -u "$JIRA_USER:$JIRA_TOKEN" -X "$method" \
      -H 'Accept: application/json' "$JIRA_BASE_URL$path")" || { rm -f "$out"; return 1; }
  fi
  if (( code >= 400 )); then
    echo "Jira API 失敗：$method $path → HTTP $code" >&2
    cat "$out" >&2; echo >&2
    rm -f "$out"
    return 1
  fi
  cat "$out"
  rm -f "$out"
}

# 依欄位名稱找出「這張單上可以編輯的」欄位 ID（例如「處理中」→ customfield_10049）。
# Jira 允許不同的欄位使用相同的名稱，所以要以單子本身可編輯的欄位為準，不能只用名稱查全站的欄位清單。
# 用法：jira_field_id <欄位名稱> <單號>
jira_field_id() {
  local ids count
  ids="$(jira_api GET "/rest/api/3/issue/$2/editmeta" \
    | jq -r --arg n "$1" '.fields | to_entries[] | select(.value.name == $n) | .key')"
  count="$(grep -c . <<<"$ids" || true)"
  if [[ "$count" -eq 0 ]]; then
    echo "$2 上找不到可以編輯的「$1」欄位。請確認這個欄位已經加到該議題類型的編輯畫面。" >&2
    return 1
  fi
  if [[ "$count" -gt 1 ]]; then
    echo "$2 上有 $count 個名稱都是「$1」的欄位（$(tr '\n' ' ' <<<"$ids")），無法判斷要用哪一個。請在 Jira 把多餘的欄位改名或從畫面移除。" >&2
    return 1
  fi
  printf '%s\n' "$ids"
}

# 用 JQL 搜尋，每行輸出一個單號。用法：jira_search <JQL> [最多幾筆]
jira_search() {
  local body
  body="$(jq -n --arg jql "$1" --argjson max "${2:-10}" '{jql: $jql, maxResults: $max, fields: ["summary"]}')"
  jira_api POST /rest/api/3/search/jql "$body" | jq -r '.issues[]?.key'
}

# 取得單子目前的狀態名稱
jira_status() {
  jira_api GET "/rest/api/3/issue/$1?fields=status" | jq -r '.fields.status.name'
}

# 取得單子標題
jira_summary() {
  jira_api GET "/rest/api/3/issue/$1?fields=summary" | jq -r '.fields.summary'
}

# 設定欄位。用法：jira_set_field <單號> <欄位ID> <JSON 值>   （JSON 值例如 null、3、"文字"）
jira_set_field() {
  local body
  body="$(jq -n --arg f "$2" --argjson v "$3" '{fields: {($f): $v}}')"
  jira_api PUT "/rest/api/3/issue/$1" "$body" >/dev/null
}

# 鎖單：把日期時間欄位寫成現在
jira_lock() {
  local now
  now="$(date +%Y-%m-%dT%H:%M:%S.000%z)"
  jira_set_field "$1" "$2" "\"$now\""
}

# 解鎖：清空欄位
jira_unlock() {
  jira_set_field "$1" "$2" null
}

# 數字欄位 +1（空值視為 0）
jira_increment() {
  local cur
  cur="$(jira_api GET "/rest/api/3/issue/$1?fields=$2" | jq -r --arg f "$2" '.fields[$f] // 0 | floor')"
  jira_set_field "$1" "$2" "$(( cur + 1 ))"
}

# 新增留言（純文字）
jira_comment() {
  local body
  body="$(jq -n --arg b "$2" '{body: $b}')"
  jira_api POST "/rest/api/2/issue/$1/comment" "$body" >/dev/null
}

# 上傳附件。用法：jira_attach <單號> <檔案路徑> [附件檔名]
jira_attach() {
  local name="${3:-$(basename "$2")}" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -u "$JIRA_USER:$JIRA_TOKEN" -X POST \
    -H 'X-Atlassian-Token: no-check' -F "file=@$2;filename=$name" \
    "$JIRA_BASE_URL/rest/api/3/issue/$1/attachments")" || return 1
  (( code < 400 )) || { echo "附件上傳失敗：$name → HTTP $code" >&2; return 1; }
}

# 轉換到指定的目標狀態（以目標狀態名稱判斷，不依賴轉換名稱）
jira_transition_to() {
  local id body
  id="$(jira_api GET "/rest/api/3/issue/$1/transitions" \
    | jq -r --arg t "$2" '[.transitions[] | select(.to.name == $t) | .id][0] // empty')"
  [[ -n "$id" ]] || { echo "$1 目前沒有可以轉換到「$2」的路徑" >&2; return 1; }
  body="$(jq -n --arg id "$id" '{transition: {id: $id}}')"
  jira_api POST "/rest/api/3/issue/$1/transitions" "$body" >/dev/null
}

# 列出阻擋這張單的其他單（is blocked by），每行輸出「單號<TAB>狀態」
jira_blockers() {
  jira_api GET "/rest/api/3/issue/$1?fields=issuelinks" \
    | jq -r '.fields.issuelinks[]? | select(.inwardIssue != null and (.type.inward | ascii_downcase) == "is blocked by") | "\(.inwardIssue.key)\t\(.inwardIssue.fields.status.name)"'
}
