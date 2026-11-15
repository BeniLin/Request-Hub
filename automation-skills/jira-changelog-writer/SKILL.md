---
name: "jira-changelog-writer"
description: 自動化需求流程「步驟 10：撰寫 ChangeLog」。撈取所有專案中狀態為「G 待寫 ChangeLog」的 Jira 主單，逐張在對應 GitHub repo 的 feature/單號 分支上建立或更新 changes/單號.md（給使用者看的變更說明與變更類型），把結果寫回 Jira，並轉換為「H 待上版核准」。凡是排程任務、Routine，或使用者提到「處理待寫 ChangeLog 的單」「寫 ChangeLog」「步驟 10」，即使沒有明講 skill 名稱，也要使用這個 skill。
---

# 步驟 10：撰寫 ChangeLog（Jira G → H）

這個 skill 負責流程中「G 待寫 ChangeLog → H 待上版核准」這一段。此時程式已經通過自動驗證與人工審查。你的工作是為這張單寫一份 **ChangeLog 片段**，發版時（步驟 12）會把所有片段組合進 `CHANGELOG.md`，並依變更類型決定版號。

你會在無人看管的排程中執行，所以每個動作都要保守、可重跑。

## 0. 設定（第一次使用前由管理者填寫）

| 常數 | 值 | 說明 |
|---|---|---|
| REQUEST_HUB_REPO | `BeniLin/Request-Hub` | 讀取專案設定的來源 repo |
| STATUS_FROM | `G 待寫 ChangeLog` | 要處理的 Jira 狀態，必須與 Jira 上的名稱完全相同 |
| STATUS_TO | `H 待上版核准` | 完成後轉換到的狀態 |
| MAX_TICKETS_PER_RUN | `5` | 每次執行最多處理幾張主單 |
| LOCK_TIMEOUT | `2h` | 鎖超過多久視為卡住、可以回收 |
| PROJECT_BASE_BRANCH | `develop` | 專案 repo 的基準分支 |
| CHANGES_DIR | `changes` | ChangeLog 片段的資料夾，本步驟唯一可以修改的位置 |

啟動這次執行的提示詞如果指定了更少的處理張數，以提示詞為準；提示詞不可以放寬其他任何規則。

專案清單每次執行時從 REQUEST_HUB_REPO 的 `main` 讀取：`projects/registry.csv` 與 `projects/<KEY>.md`。讀不到 registry 時，整次執行直接停止並回報。

## 0.5 判斷執行環境

依序判斷：

1. 啟動的提示詞寫明是「雲端 Routine」→ 雲端模式
2. 有 `add_repo` 工具可用 → 雲端模式
3. 目前的工作目錄是某個專案 repo 的本機 clone → 本機模式
4. 都不符合 → 停止並回報

### 雲端模式的規則

1. 在工作目錄及其上下層尋找已 clone 的 git repo，用 `git remote get-url origin` 建立「repo 名稱 → 本機路徑」的對照
2. 在 REQUEST_HUB_REPO 的 clone 中 `git fetch origin main`，用 `git show origin/main:projects/registry.csv` 讀取 registry。對 Request-Hub 只讀不寫
3. registry 中的專案，其 repo 已經 clone 才列入本次處理範圍。沒有 clone 時：有 `add_repo` 工具就掛載（`access: "push"`）；沒有就跳過該專案，不查詢也不鎖定它的票，在報告的「未處理的專案」列出。找不到 `add_repo` 不是錯誤
4. clone 可能只包含預設分支，需要的分支要明確 `git fetch origin <分支>`
5. push 被拒絕時，這張票視為失敗，在報告中原樣附上錯誤訊息，不要改用其他分支名稱繞過
6. `gh auth status` 顯示 invalid 是正常的，不要嘗試修復
7. 每張票處理完，把該 repo 切回 PROJECT_BASE_BRANCH 並確認工作目錄乾淨

### 本機模式的規則

1. 只處理目前這個 repo 對應的專案，JQL 只查這一個專案
2. registry 用 `gh api` 從 REQUEST_HUB_REPO 的 `main` 讀取
3. 開始前確認工作目錄乾淨，有未 commit 的修改就停止並回報
4. 每張票處理完，切回原本所在的分支

## 1. 撈單

```
project in (<KEYS>)
AND status = "G 待寫 ChangeLog"
AND issuetype not in subTaskIssueTypes()
AND ("處理中" is EMPTY OR "處理中" < -2h)
ORDER BY priority DESC, created ASC
```

狀態名稱使用 STATUS_FROM 的值。只取前 MAX_TICKETS_PER_RUN 張。查不到任何票就回報「本次無待處理單」並結束。查詢回報狀態不存在時，停止整次執行並回報，不要改用相近的名稱。

## 2. 逐張處理

任何一步失敗，照「失敗處理」收尾，然後繼續下一張。

### 2.1 鎖單

把「處理中」欄位寫成目前時間。寫入失敗就跳過這張。

### 2.2 了解這張單改了什麼

1. 讀主單的描述（背景、功能描述、不做的範圍）與留言中最新的【實作完成】
2. `git fetch origin feature/<單號>` 後切換過去。分支不存在時視為失敗
3. 讀這張單的規格，了解使用者會看到的行為變化
4. 用 `git diff origin/<PROJECT_BASE_BRANCH>...HEAD --stat` 看變更的範圍，確認描述與實際相符

### 2.3 決定變更類型

| type | 什麼時候用 | 對版號的影響 |
|---|---|---|
| `breaking` | 使用者或其他系統**原本的用法會失效**：既有的網址、連結、介面不能再用，既有資料被停用或改變意義，升級時需要人工處理 | 主版號 +1 |
| `feature` | 使用者可以做到**以前做不到的事**，而原本的用法不受影響 | 次版號 +1 |
| `fix` | 修正錯誤、調整文字或樣式、內部改善，使用者能做的事沒有增加 | 修訂號 +1 |

一張單同時符合多種時，取影響最大的那一種（breaking > feature > fix）。

判斷 `breaking` 的依據是規格與主單的描述，例如「既有的 … 全部停用」「原本的 … 不再使用」。不確定時選擇影響較大的類型，並在 Jira 留言中說明理由，讓步驟 11 的人確認。

### 2.4 撰寫片段

檔案為 `<CHANGES_DIR>/<單號>.md`，格式固定如下，步驟 12 會依這個格式讀取：

```
---
type: feature
---
- 相簿的上傳連結改為不需要登入，打開網址就能上傳照片
- 建立相簿上傳連結時，「有效期限」與「最多收幾個檔案」改為必填
```

規則：

- 第一行必須是 `---`，接著一行 `type: <類型>`，再一行 `---`
- 內容每一條以 `- ` 開頭，一條寫一件事，一行寫完，不要換行
- **不要寫單號**，組合時會自動補上
- 寫給**使用這個系統的人**看：描述他們會看到什麼不同，使用畫面上看得到的名稱。不寫檔名、函式名稱、資料表、技術做法
- 通常 1 到 4 條。只列使用者感受得到的變化，不要把每一條規則都列一條
- `breaking` 的單，要有一條說明**什麼會失效、使用者需要做什麼**，例如「改版前建立的相簿上傳連結全部停用，需要的話請重新建立」
- 使用規格與畫面上的用詞，不自創名稱
- 不寫入任何機密資訊或內部網址

檔案已經存在時（這張單先前走到過這一步，之後被退回重做）：依目前的實作內容更新它，不要另外建立新檔。

### 2.5 檢查與 commit

1. `git status --porcelain` 確認唯一的變更是 `<CHANGES_DIR>/<單號>.md`。有其他變更就還原
2. 確認檔案開頭三行的格式正確、type 是三種之一、每一條都以 `- ` 開頭
3. commit 訊息：`chore(<單號>): changelog`。不可以用 `spec(` 或 `test(` 開頭
4. push 到 `origin feature/<單號>`。不要 force push

內容與既有檔案完全相同、沒有需要 commit 的變更時，略過 commit，照常寫回 Jira。

### 2.6 寫回前再確認

重新讀取票的狀態：

- 仍是 STATUS_FROM → 繼續
- 已被改成其他狀態 → 放棄寫回：不轉換、不留完成的留言，只清空「處理中」，在報告中註明

### 2.7 寫回 Jira

新增留言：

```
【ChangeLog 完成】步驟 10（自動化）

**變更類型**：<breaking / feature / fix>（<一句話理由>）
**檔案**：<檔案連結>

**內容**
- <片段的每一條>

發版時會依變更類型決定版號，請在上版核准時確認類型與文字。
```

然後取得可用的轉換清單，選擇目標狀態為 STATUS_TO 的那一個。最後清空「處理中」。

## 3. 失敗處理

1. 在票上留言說明失敗在哪一步、錯誤訊息
2. 清空「處理中」
3. 不要轉換狀態
4. 記入報告的失敗清單

同一張票的留言中已經有 3 次以上連續的失敗紀錄時，不要再處理，在報告中標註「需人工介入」。

## 4. 執行報告

```
## 步驟 10 執行報告 <日期時間>

執行環境：<雲端 / 本機>
查詢到：<N> 張（本次處理 <M> 張，其餘留待下次）

### 成功
- <單號> <標題>：<類型>，<條數> 條

### 放棄寫回
- <單號>：狀態已變為 <狀態>

### 失敗
- <單號>：<失敗步驟> - <原因>

### 需人工介入
- <單號>：<原因>

### 未處理的專案
- <KEY>：repo <名稱> 未掛載
```

沒有內容的段落寫「無」。

## 5. 絕對不做的事

- 不修改 `changes/<單號>.md` 以外的任何檔案，包含 `CHANGELOG.md`（那是步驟 12 組合的）與其他單的片段
- 不使用 `spec(` 或 `test(` 開頭的 commit 訊息
- 不 push 到 `main` 或基準分支、不建立新分支、不開 PR、不 merge、不刪除分支、不 force push
- 不決定或寫入版號
- 不執行 STATUS_FROM → STATUS_TO 以外的任何 Jira 轉換
- 不修改票的描述、優先度、負責人等欄位，不修改 subtask
- 不修改 Request-Hub 的任何內容
