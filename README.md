# 需求工作區

用 Claude 討論需求、建立 Jira 單，以及協助人工審查的共用工作區。所有人使用同一套規則（Skill）與連線設定，讓產出的需求格式一致。

完整流程說明見 [`docs/workflow.md`](docs/workflow.md)。

---

## 使用者：第一次設定

**需要準備**

- 公司 Claude 組織帳號，並安裝 Claude Desktop
- 能存取各專案 repo 的 GitHub 帳號
- Jira Cloud 帳號

**步驟**

1. clone 這個 repo
2. Windows：雙擊根目錄的 `setup.cmd`；Mac / Linux：執行 `bash scripts/setup.sh`
   - 會自動安裝需要的工具，並開啟瀏覽器登入 GitHub
   - 最後會檢查每個專案是否讀得到，有紅色訊息請通知管理員
3. 開啟 Claude Desktop → **Code** 分頁 → 選擇這個資料夾 → 信任資料夾
4. 輸入 `/mcp`，選擇 `jira`，用瀏覽器登入 Atlassian 帳號

完成。整個過程不需要複製或貼上任何金鑰。

## 使用者：日常使用

直接用一般的話描述你要做的事：

| 你想做的事 | 可以這樣說 |
|---|---|
| 討論新需求 | 「我想討論一個 SHOP 的新需求」 |
| 處理 AI 卡住的單 | 「看一下待人工處理的單」 |
| 審查規格 | 「幫我審 SHOP-123 的規格」 |
| Code Review | 「幫我看待審查的單」 |
| 上版核准 | 「看一下準備上版的單」 |
| 查現有規則 | 「SHOP 現在的會員折扣規則是什麼？」 |

**注意**

- 每次開啟時會自動更新工作區規則。若出現「自動更新失敗」，請手動執行 `git pull`
- 建單、轉換狀態前，Claude 會先讓你預覽，系統也會再跳一次確認視窗，請看清楚再按
- 這個工作區不會修改任何專案的程式碼或文件

---

## 管理員：初次建置

### 1. GitHub

- 建立這個 repo，成員設定為 **Read** 權限（或允許發 PR、只有管理員能 merge）
- 確認 `.gitattributes` 有一起 commit，否則 Windows 上的 `.sh` 腳本會因換行格式錯誤而無法執行

### 2. 填入專案資訊

- `projects/registry.csv`：每個專案一行
  - `repo`：GitHub 上的 `org/repo`
  - `branch`：主分支名稱
  - `specs_dir`：規格資料夾
  - `read_dirs`：允許 Claude 讀取的資料夾，用分號分隔
- `projects/<KEY>.md`：複製 `projects/_TEMPLATE.md` 填寫，`SHOP.md` 是範例，請刪除或改寫

### 3. 各專案 repo

- 在每個專案建立 `specs/INDEX.md`，範本見 `docs/spec-index-template.md`
- 分支命名規則：`feature/<單號>`（審查 Skill 依此找分支）

### 4. Jira

- 五個專案共用同一個 Workflow Scheme，狀態名稱與 `docs/workflow.md` 一致
- **Workflow 的初始狀態必須是「待寫規格」**，因為建單後不會轉換狀態
- 建立自訂欄位「處理中」與「退回次數」，把欄位 ID 填進各專案的 `projects/<KEY>.md`
- 確認 Atlassian 組織已允許 Rovo MCP 連線

### 5. 確認 Jira MCP 的工具名稱

`.claude/settings.json` 中預先允許的 Jira 查詢工具名稱，是依 Atlassian MCP 常見的命名填入，**請實際確認**：

1. 自己先完成使用者設定
2. 在 Claude Code 輸入 `/mcp` → 選 `jira` → 查看工具清單
3. 把**唯讀**的工具（搜尋、讀取單子、查詢轉換）名稱填入 `permissions.allow`，格式為 `mcp__jira__<工具名稱>`
4. **不要**把建立、修改、轉換狀態類的工具加進 allow，讓它們每次都跳出確認，這是人工確認的最後一道防線

### 6. n8n 格式檢查（步驟 3 開頭）

建議 n8n 在步驟 3 撈到 A 的單子時，先檢查描述中以下段落存在且不為空，缺漏則寫備註並通知建單人：

- `## 背景與目的`
- `## 驗收條件`（至少一條 `AC-`）
- `## 不做的範圍`

模板見 `.claude/skills/jira-ticket/templates/story.md`。

---

## 管理員：日常維護

**新增專案**：在 `registry.csv` 加一行、新增 `projects/<KEY>.md`、在該專案 repo 建立 `specs/INDEX.md`。

**修改 Skill**：直接修改 `.claude/skills/` 下的檔案並 commit，成員下次開啟時會自動更新。

**調整 Skill 的建議做法**：上線初期定期檢視大家開出來的單子，留意 AI 常漏問的項目、格式不一致的地方，回頭修改 `requirement-elicitation/checklist.md` 或模板。

## 檔案結構

```
.
├── CLAUDE.md                  每次對話都會載入的規則
├── README.md
├── setup.cmd                  Windows 初始設定（雙擊執行）
├── .mcp.json                  Jira MCP 連線設定
├── .claude/
│   ├── settings.json          權限、自動更新
│   └── skills/
│       ├── requirement-elicitation/   需求訪談
│       ├── spec-lookup/               讀取專案規格
│       ├── requirement-split/         需求拆分
│       ├── jira-ticket/               建立 Jira 單
│       ├── ticket-followup/           處理 D 狀態與補充需求
│       └── review-assist/             協助 B、F、H 關卡審查
├── docs/
│   ├── workflow.md            完整流程說明
│   └── spec-index-template.md 各專案 INDEX.md 範本
├── projects/
│   ├── registry.csv           專案清單
│   ├── _TEMPLATE.md           專案資訊範本
│   └── SHOP.md                範例
└── scripts/
    ├── read-spec.sh           唯讀：讀取專案文件
    ├── read-pr.sh             唯讀：讀取 PR 資訊
    ├── setup.ps1              Windows 設定腳本
    └── setup.sh               Mac / Linux 設定腳本
```
