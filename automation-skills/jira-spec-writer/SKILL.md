---
name: "jira-spec-writer"
description: 自動化需求流程「步驟 3：撰寫規格」。撈取所有專案中狀態為「A 待撰寫規格」的 Jira 主單，逐張在對應的 GitHub repo 建立或沿用 feature/單號 分支，撰寫或更新 specs/ 規格文件、Test Case 與預期畫面、更新 specs/INDEX.md，commit 後把連結寫回 Jira，並轉換為「B 待確認規格」。凡是排程任務、Routine，或使用者提到「處理待撰寫規格的單」「撰寫規格」「步驟 3」「跑規格」，即使沒有明講 skill 名稱，也要使用這個 skill。
---

# 步驟 3：撰寫規格（Jira A → B）

這個 skill 負責流程中「A 待撰寫規格 → B 待確認規格」這一段。你會在無人看管的排程中執行，沒有人可以回答問題或按確認，所以每個動作都要保守、可重跑：寧可跳過一張票並回報，也不要猜。

## 0. 設定（第一次使用前由管理者填寫）

以下常數是整個 skill 唯一需要人工填寫的地方：

| 常數 | 值 | 說明 |
|---|---|---|
| REQUEST_HUB_REPO | `BeniLin/Request-Hub` | 讀取專案設定的來源 repo |
| STATUS_FROM | `A 待撰寫規格` | 要處理的 Jira 狀態，必須與 Jira 上的名稱完全相同 |
| STATUS_TO | `B 待確認規格` | 完成後轉換到的狀態，必須與 Jira 上的名稱完全相同 |
| MAX_TICKETS_PER_RUN | `3` | 每次執行最多處理幾張主單 |
| LOCK_TIMEOUT | `2h` | 鎖超過多久視為卡住、可以回收 |
| PROJECT_BASE_BRANCH | `develop` | 專案 repo 的基準分支：讀取現有規格、建立 feature 分支都以它為準 |

啟動這次執行的提示詞如果指定了更少的處理張數，以提示詞為準；提示詞不可以放寬其他任何規則。

專案清單**不要寫死在這裡**。每次執行時從 REQUEST_HUB_REPO 的 `main` 讀（Request-Hub 是唯一讀 `main` 的 repo；所有專案 repo 一律使用 PROJECT_BASE_BRANCH）：

- `projects/registry.csv`：所有專案的 Jira Key 與 GitHub repo
- `projects/<KEY>.md`：該專案的補充說明（規格慣例、特殊規則）

這樣新增專案時只要在 Request-Hub 跑 add-project.cmd，這個 skill 不用改。讀不到 registry 時，整次執行直接停止並回報，不要用記憶或猜測的 repo 名稱。

## 0.5 判斷執行環境（每次執行最先做）

這個 skill 可以在兩種環境執行。依序判斷：

1. 啟動的提示詞寫明是「雲端 Routine」→ **雲端模式**
2. 有 `add_repo` 工具可用 → **雲端模式**
3. 以上皆非，且目前的工作目錄是某個專案 repo 的本機 clone → **本機模式**
4. 都不符合 → 停止並回報無法判斷執行環境

### 雲端模式的規則（Routine、雲端工作階段）

Routine 啟動時，設定中選取的 repo 已經 clone 在工作環境裡。

1. **找出已經 clone 的 repo**：在工作目錄及其上下層尋找 git repo，對每一個執行 `git remote get-url origin` 取得 repo 名稱，建立「repo 名稱 → 本機路徑」的對照
2. **讀取 registry**：在 REQUEST_HUB_REPO 的 clone 中執行 `git fetch origin main`，再用 `git show origin/main:projects/registry.csv` 讀取，確保讀到的是最新版。`projects/<KEY>.md` 也用同樣方式讀。對 Request-Hub 只讀不寫
3. **決定本次可處理的專案**：registry 中的專案，其 repo 有在第 1 步的對照中，才列入本次處理範圍
   - repo 沒有 clone、但有 `add_repo` 工具：呼叫 `add_repo` 掛載（`access: "push"`），成功後列入
   - repo 沒有 clone、也沒有 `add_repo` 工具：**跳過這個專案**，不要查詢或鎖定它的票，在報告的「未處理的專案」中列出
   - 找不到 `add_repo` 工具不是錯誤，不要因此停止整次執行
4. 第 1 節的 JQL 只查詢本次可處理的專案
5. **git 操作**：在專案 repo 的 clone 中進行。clone 可能只包含預設分支，所以要明確取得需要的分支：
   - `git fetch origin <PROJECT_BASE_BRANCH>`
   - 用 `git ls-remote --heads origin feature/<單號>` 判斷分支是否已存在，存在就 `git fetch origin feature/<單號>` 後切換過去
6. **push 被拒絕時**（例如環境限制只能推送特定前綴的分支）：這張票視為失敗，在報告中**原樣附上錯誤訊息**。不要改用其他分支名稱、不要改推到其他地方來繞過
7. 環境變數 `GH_TOKEN` 可能是代理用的佔位值，`gh auth status` 顯示 invalid 是正常的，不要嘗試修復
8. 每張票處理完，把該 repo 切回 PROJECT_BASE_BRANCH 並確認工作目錄乾淨，再處理下一張

### 本機模式的規則

1. **只處理目前這個 repo 對應的專案**。用 `git remote get-url origin` 取得 repo 名稱，再到 registry 找出對應的 Jira Key；第 1 節的 JQL 改成只查這一個專案。找不到對應的專案就停止並回報
2. registry 用 `gh api` 從 REQUEST_HUB_REPO 的 `main` 讀取（唯讀）
3. 開始前確認工作目錄是乾淨的（`git status --porcelain` 沒有輸出）。有未 commit 的修改就停止並回報，不要 stash、不要丟棄別人的修改
4. 所有 git 操作用本機指令：`git fetch origin` → 從 `origin/<PROJECT_BASE_BRANCH>` 建立或切換到 `feature/<單號>` → 修改 → commit → `git push -u origin feature/<單號>`
5. 每張票處理完，切回原本所在的分支，再處理下一張

## 1. 撈單

用 Jira 連接器以 JQL 查詢（`<KEYS>` 換成本次可處理專案的 Key）：

```
project in (<KEYS>)
AND status = "A 待撰寫規格"
AND issuetype not in subTaskIssueTypes()
AND ("處理中" is EMPTY OR "處理中" < -2h)
ORDER BY priority DESC, created ASC
```

狀態名稱使用 STATUS_FROM 的值。只取前 MAX_TICKETS_PER_RUN 張，其餘留給下一次執行。查不到任何票就回報「本次無待處理單」並結束。

查詢回報「狀態不存在」之類的錯誤時，代表 STATUS_FROM 與 Jira 上的名稱不一致：停止整次執行並回報，不要改用相近的名稱猜測。

Subtask 不單獨處理：規格以主單為單位，subtask 的內容一併讀進來當作主單需求的一部分。

## 2. 逐張處理

每張票依序做以下步驟。任何一步失敗，就照「失敗處理」那一節收尾，然後繼續下一張；一張失敗不應該影響其他張。

### 2.1 鎖單
把「處理中」欄位寫成目前時間。寫入失敗就跳過這張（多半是欄位沒加到編輯畫面）。

### 2.2 讀取需求
讀主單的描述、所有 subtask、附件說明與**所有留言**。

判斷這張是新單還是退回單。符合以下任一項就是退回單：

- 留言中有【審查退回】（B 關卡退回規格）
- 留言中有【需求變更】（從 D 或 F 送回來重寫規格）
- repo 中已存在 `feature/<單號>` 分支

退回單的重點是**依備註修改**，不是重寫。以最新的一則退回或變更備註為準，逐條處理；較早的備註若已在先前的 commit 中處理過，不要重複修改。

### 2.3 讀取現有規格
讀該專案 repo 的 PROJECT_BASE_BRANCH。不要讀 `main`，因為 `main` 只反映已上版的內容，尚未上版但已合併的規格都在基準分支：

1. 先讀 `specs/INDEX.md`，了解規格的分類與既有文件
2. 讀與這張票相關的既有規格文件
3. 以既有文件的格式、用詞、Test Case 寫法為準。專案的規格慣例以 repo 現況和 `projects/<KEY>.md` 為準，不要自創格式

### 2.4 準備分支
- 分支不存在：從最新的 PROJECT_BASE_BRANCH 建立 `feature/<單號>`。專案 repo 沒有基準分支時，這張票視為失敗並回報，不要改用 `main`
- 分支已存在（退回單或上次中途失敗）：沿用，不要刪除重建，不要 force push

### 2.5 撰寫規格
在分支中，**只能**新增或修改 `specs/` 底下的檔案：

- 新增或更新相關的規格文件
- 撰寫 Test Case：
  - 每條有固定編號（例如 `TC-1`），退回修改時既有編號不可變動，新增的往後編
  - 採 Given / When / Then，每條對應得回主單的某條驗收條件
  - 下一個步驟（步驟 5）會把每條 Test Case 轉成自動化測試腳本，所以步驟、輸入資料、預期結果都要具體明確，不可以有「視情況」「適當地」這類需要人判斷的描述
  - 預期結果要可以被程式檢查：具體的文字、數字、狀態或畫面元素
- 撰寫預期畫面：用文字描述畫面元素、狀態與互動結果（必要時用簡單的文字線框），讓步驟 9 的人可以對照截圖。每個可操作或會被檢查的元素（按鈕、欄位、訊息區塊）給一個明確且不重複的名稱，Test Case 中一律用這個名稱指稱
- 更新 `specs/INDEX.md`，讓新文件可以被找到

需求本身有矛盾、資訊不足、或你需要做出會影響範圍的假設時，**不要自行補完**。把問題寫進規格文件的「待確認事項」段落並照常送 B，讓人在確認規格時回答。

不要修改 `specs/` 以外的任何檔案。不要動 `main` 與基準分支，不要開 PR，不要 merge。

commit 前執行 `git status --porcelain`，確認所有變更都在 `specs/` 底下。有其他路徑的變更就還原它們；無法確定如何還原時，這張票視為失敗。

### 2.6 Commit
commit 訊息格式：`spec(<單號>): <一句話摘要>`。退回單用 `spec(<單號>): 依退回意見修改 - <摘要>`。

commit 後 push 到 `origin feature/<單號>`。

### 2.7 寫回前再確認
重新讀一次這張票的狀態：
- 仍是 STATUS_FROM → 繼續
- 已被改成其他狀態（例如被作廢）→ **放棄寫回**：不轉換狀態、不留規格完成的留言，只清空「處理中」，在本次報告中註明。已 push 的分支保留，不刪除

### 2.8 寫回 Jira
在票上新增留言，內容包含：
- 分支連結
- 新增／修改的檔案清單（附 GitHub 連結）
- Test Case 數量
- 待確認事項（如果有）
- 退回單：逐條說明如何回應退回或變更備註

然後執行轉換：取得這張票可用的轉換清單，選擇**目標狀態為 STATUS_TO** 的那一個（以目標狀態判斷，不要依賴轉換名稱）。找不到這樣的轉換時視為失敗並回報。最後清空「處理中」。

## 3. 失敗處理

任何一步失敗時：
1. 在票上留言說明失敗在哪一步、錯誤訊息
2. 清空「處理中」，讓下一次執行可以重試
3. 不要轉換狀態
4. 記入本次報告的失敗清單

如果同一張票的留言中已經有 3 次以上連續的失敗紀錄，不要再處理，在報告中標註「需人工介入」。

## 4. 執行報告

每次執行結束，輸出以下格式的報告：

```
## 步驟 3 執行報告 <日期時間>

執行環境：<雲端 / 本機>
查詢到：<N> 張（本次處理 <M> 張，其餘留待下次）

### 成功
- <單號> <標題>：<新單/退回單>，<分支連結>，Test Case <n> 條

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

這些規則存在的原因是：步驟 3 是唯一允許修改 specs/ 的步驟，後續流程的 Test Case 與測試保護都建立在這個前提上。

- 不修改 `specs/` 以外的檔案（包含 `tests/e2e/`，那是步驟 5 的範圍）
- 不 push 到 `main` 或基準分支、不開 PR、不 merge
- 不執行 STATUS_FROM → STATUS_TO 以外的任何 Jira 轉換
- 不修改票的描述、優先度、負責人等欄位（只寫「處理中」與留言）
- 不刪除分支、不 force push
- 不修改 Request-Hub 的任何內容
