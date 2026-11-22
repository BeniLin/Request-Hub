# Jenkins 執行的步驟

需要部署系統、跑測試、合併分支的步驟由 Jenkins 執行，不經過 AI。

| 步驟 | 內容 | 位置 | 觸發 |
|---|---|---|---|
| 8 | 驗證：E 待驗證 → F 待審查，失敗 → C 待實作 | `verify/` | 定時 |
| 12 | 發版：I 待發版 → J 已發版，失敗 → C 待實作 | `release/` | 手動 |

## 設計原則

**這裡的 Job 不負責部署，也不知道系統怎麼部署。** 部署到哪台機器、用哪個資料庫、放哪些檔案，全部由各專案自己的部署 Job 決定。這裡只做三件事：

1. 呼叫專案的部署 Job，告訴它要部署哪個分支，等它完成
2. 對著一個網址執行測試（系統可以在任何機器上，Jenkins 連得到網址即可）
3. 操作 Jira 與 Git：撈單、留言、上傳截圖、轉換狀態、合併分支、標記版號

Jenkins 主動去 Jira 撈單，不需要對外開放。

```
jenkins/
├── lib/
│   ├── jira.sh        操作 Jira 的函式
│   └── common.sh      兩個步驟共用的函式（git、執行測試、回報結果）
├── verify/            步驟 8
│   ├── Jenkinsfile
│   └── run.sh
└── release/           步驟 12
    ├── Jenkinsfile
    └── run.sh
```

---

## 一、每個專案要先準備的東西

### 1. 一個可以指定分支的部署 Job

這是整套做法唯一對專案的要求。這個 Job 由專案自己設計，需要符合：

- 有一個字串參數接收分支名稱（預設名稱 `BRANCH`，可以用其他名稱）
- 執行後把該分支部署到一個**驗證用的環境**
- 系統可以使用了，Job 才算成功；部署失敗時 Job 要失敗

驗證用的環境要用哪一套，由專案決定：

| 做法 | 說明 |
|---|---|
| 專用的驗證環境 | 與其他環境互不干擾，建議的做法 |
| 借用現有的測試環境 | 不用多準備環境，但驗證期間跑的是某張單的分支。可以設定 `RESTORE_BRANCH`，驗證結束後自動部署回原本的分支 |

兩點提醒：

- 驗證環境執行的是**還沒有人審查過的程式**（Code Review 在步驟 9）。它使用的設定檔不應該包含正式環境的金鑰
- 這裡不會清空或重設驗證環境的資料。要不要在每次部署時重設資料，由專案的部署 Job 決定

### 2. 驗證環境的網址與測試帳號

- 網址：填在 Job 參數 `E2E_BASE_URL`
- 測試需要的其他資訊（帳號、密碼、其他網址）：寫成一個檔案存進 Jenkins 憑證（Secret file），每行一個 `名稱=值`。變數名稱由專案自訂，例如：

```
E2E_ADMIN_URL=https://verify-admin.example.com
E2E_ADMIN_USER=tester
E2E_ADMIN_PASSWORD=********
```

### 3. 在 Request-Hub 的 `projects/<KEY>.md` 寫明測試的規則

步驟 5 撰寫測試腳本時會讀取這一段，Jenkins 則依這些名稱提供實際的值。兩邊的變數名稱必須一致：

```markdown
## 測試

自動化測試一律從環境變數取得網址與帳號，不可寫死：

| 環境變數 | 內容 |
|---|---|
| `E2E_BASE_URL` | 系統的網址 |
| `<其他變數>` | <用途> |

執行環境的前提：

- 驗證環境的資料**不會**在每次執行前清空。測試需要的資料要自己建立，名稱加上不會重複的字串（例如時間），而且不可以假設環境中沒有其他資料
- 測試從 `tests/e2e/` 以 `npx playwright test <單號>/` 執行
- 設定檔必須讓每個測試結束時都保留截圖
```

---

## 二、Jenkins 的共通設定

### 需要的指令

Jenkins 執行的機器需要 `git`、`docker`、`curl`、`jq`、`tar`。

Docker 只用來在 Jenkins 上執行 Playwright（測試程式），不會用來啟動受測的系統。

### 憑證

| ID | 類型 | 內容 |
|---|---|---|
| `jira-api` | Username with password | Jira 帳號 email 與 API token（id.atlassian.com → 安全性 → API token） |
| `github-bot` | Username with password | GitHub 帳號與 token。步驟 8 需要讀取 Request-Hub 與專案 repo；步驟 12 還需要專案 repo 的寫入權限 |
| （自訂名稱） | Secret file | 上面第 2 點的測試帳號檔。每個專案一個，沒有額外資訊的專案可以不建 |

### Jira

- 帳號要能瀏覽專案、編輯單子、新增留言與附件、執行轉換
- 「處理中」（日期時間）與「退回次數」（數字）兩個欄位要加到主單的**編輯畫面**，否則無法寫入

---

## 三、步驟 8：驗證

### 每次執行做什麼

1. 到 Jira 撈「E 待驗證」且沒被鎖住的主單。沒有就直接結束（幾秒鐘）
2. 逐張處理：鎖單 → 取得 `feature/<單號>`
3. **保護檢查**：`specs/` 只能出現在 `spec(...)` 開頭的 commit、`tests/e2e/` 只能出現在 `test(...)` 開頭的 commit。實作階段動到這兩個資料夾就判定失敗
4. 呼叫專案的部署 Job，部署 `feature/<單號>`
5. 對 `E2E_BASE_URL` 執行 `tests/e2e/<單號>/` 的測試
6. 把截圖與測試報告上傳到 Jira 並留言。全部通過轉到 F；否則退回次數 +1、轉到 C

寫回前會再確認單子仍是 E，被人改過（例如作廢）就不寫回。流程本身出錯（例如 Jira 連不上）時不會改變單子的狀態，下次執行會重試。

### 建立 Job

每個專案建立一個 **Pipeline** Job：

- **Pipeline**：Pipeline script from SCM → Git → Request-Hub 的網址，憑證 `github-bot`，分支 `main`，Script Path 填 `jenkins/verify/Jenkinsfile`
- **Build periodically**：`H/15 * * * *`（每 15 分鐘）。測試期間先不要設，手動執行
- **This project is parameterized**，加入以下字串參數：

| 參數 | 必填 | 說明 |
|---|---|---|
| `JIRA_BASE_URL` | 是 | Jira 網址，例如 `https://<你的網域>.atlassian.net` |
| `PROJECT_KEY` | 是 | Jira 專案 Key |
| `PROJECT_REPO` | 是 | 專案的 GitHub repo，格式 `<組織>/<repo>` |
| `BASE_BRANCH` | 是 | 基準分支，例如 `develop` |
| `DEPLOY_JOB` | 是 | 專案的部署 Job 名稱（在資料夾裡的話填完整路徑） |
| `E2E_BASE_URL` | 是 | 部署完成後系統的網址 |
| `DEPLOY_BRANCH_PARAM` | 否 | 部署 Job 接收分支的參數名稱，預設 `BRANCH` |
| `E2E_ENV_CRED` | 否 | 測試帳號檔的憑證 ID |
| `RESTORE_BRANCH` | 否 | 驗證結束後要部署回去的分支。借用其他環境時使用 |
| `MAX_TICKETS` | 否 | 每次最多處理幾張，預設 `2` |
| `E2E_IMAGE` | 否 | 執行 Playwright 的 image，預設 `mcr.microsoft.com/playwright:v1.49.1-noble` |

### 測試方法

1. 沒有 E 的單時手動執行一次。預期：顯示「本次無待驗證的單」，幾秒內結束。這代表 Jira 連線、憑證、參數都正確
2. 有單子進到 E 之後執行。預期：部署 Job 被觸發一次；Jira 單出現留言與截圖附件，狀態變為 F 或 C；Jenkins 建置頁面保存了 `work/reports/<單號>/` 的完整記錄

---

## 四、步驟 12：發版

手動執行，每次用參數 `MODE` 選擇要做哪一個動作。

### 動作一：`merge`（合併）

1. 撈「I 待發版」的單，依優先度排序。跳過已經合併的，以及還被未發版、未合併的單阻擋的
2. 逐張處理：把最新的基準分支併進 `feature/<單號>` 並推上去
3. 呼叫部署 Job 部署這個分支，重新執行測試
4. 通過：合併進基準分支，留言【已合併】。單子**維持在 I**
5. 衝突、保護檢查不通過或測試失敗：留言、退回次數 +1、轉到 C，繼續下一張
6. 有設定 `BASE_DEPLOY_JOB` 的話，最後部署基準分支，方便確認整合後的結果

### 動作二：`release`（發版）

1. 找出已經合併進基準分支的 I 單
2. 讀取每張單的 `changes/<單號>.md`，組合進 `CHANGELOG.md`，並刪除這些片段檔
3. 依變更類型決定版號：有破壞性變更進主版號，有新功能進次版號，其餘進修訂號。以最新的 `vX.Y.Z` tag 為基準，沒有 tag 時從 `v0.0.0` 起算
4. 把基準分支合併進發版分支，標記版號，一起推上去
5. 有設定 `RELEASE_DEPLOY_JOB`：呼叫它部署發版分支，**部署成功單子才轉 J**。部署失敗時單子維持在 I，排除問題後重新執行 `release` 即可，不會重複建立版號
6. 沒有設定 `RELEASE_DEPLOY_JOB`：單子直接轉 J，留言提醒自行部署
7. 單子轉 J 時，在 Jira 專案建立同名的版本（標記為已發行），並填進每張單的「修正版本」欄位。單子的畫面上要有這個欄位。這一步失敗不影響發版，版號仍會寫在留言裡

兩個動作分開，是為了讓多張單合併之後，有機會先確認整合的結果，再決定要不要發版。

### ChangeLog 片段的格式

步驟 10 在分支上建立 `changes/<單號>.md`：

```markdown
---
type: feature
---
- 給使用者看的變更說明
```

`type` 是 `feature`（新功能）、`fix`（修正）或 `breaking`（破壞性變更）。每一條說明會自動補上單號。找不到片段檔的單會改用單子標題，並歸類為修正。

### 建立 Job

每個專案建立一個 **Pipeline** Job，設定方式與步驟 8 相同，Script Path 填 `jenkins/release/Jenkinsfile`，**不要設定排程**。

| 參數 | 必填 | 說明 |
|---|---|---|
| `MODE` | 是 | 選項參數（Choice），選項為 `merge` 與 `release` |
| `JIRA_BASE_URL`、`PROJECT_KEY`、`PROJECT_REPO`、`BASE_BRANCH` | 是 | 同步驟 8 |
| `RELEASE_BRANCH` | 是 | 發版分支，例如 `main` |
| `DEPLOY_JOB`、`E2E_BASE_URL` | 合併時必填 | 同步驟 8，用來重新測試 |
| `DEPLOY_BRANCH_PARAM`、`E2E_ENV_CRED`、`E2E_IMAGE` | 否 | 同步驟 8 |
| `BASE_DEPLOY_JOB` | 否 | 合併完成後，用來部署基準分支的 Job |
| `RELEASE_DEPLOY_JOB` | 否 | 發版時，用來部署發版分支的 Job。不填就由人自行部署 |
| `MAX_TICKETS` | 否 | 每次合併最多處理幾張，預設 `5` |

`BASE_DEPLOY_JOB` 與 `RELEASE_DEPLOY_JOB` 被呼叫時會收到分支名稱參數；Job 本身已經固定部署某個分支的話，會忽略這個參數，不影響使用。

### GitHub 的設定

- 基準分支與發版分支開啟 branch protection，只允許 `github-bot` 的帳號推送。這樣 AI 的步驟無法直接改動這兩個分支
- `github-bot` 需要能推送這兩個分支、`feature/*` 分支與 tag

### 測試方法

1. 沒有 I 的單時，分別用 `merge` 與 `release` 執行一次。預期：顯示「沒有需要合併的單」與「沒有可以發版的單」
2. 有單子進到 I 之後執行 `merge`。預期：基準分支多了一個 `merge(<單號>): ...` 的合併 commit，Jira 出現【已合併】留言，單子仍是 I
3. 執行 `release`。預期：`CHANGELOG.md` 多了新版本的段落、`changes/` 底下的片段檔被刪除、發版分支多了 `release: vX.Y.Z` 的合併 commit 與 tag、單子轉為 J
