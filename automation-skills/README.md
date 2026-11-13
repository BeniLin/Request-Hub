# 自動化 Skill

這個資料夾放的是**由 Claude Code Routine 自動執行**的 skill，不是給人在工作區對話時使用的。

刻意不放在 `.claude/skills/`，避免成員討論需求時被載入。Routine 透過提示詞明確指定檔案路徑來讀取。

| Skill | 流程步驟 | 狀態 |
|---|---|---|
| `jira-spec-writer` | 步驟 3：撰寫規格 | A 待撰寫規格 → B 待確認規格 |

## 修改 skill

直接修改檔案並推上 `main`，下一次 Routine 執行就會讀到新版，不需要重新設定 Routine。

Jira 的狀態名稱有變動時，記得同步修改各 skill「設定」表格中的 STATUS_FROM 與 STATUS_TO。

## Routine 設定：步驟 3 撰寫規格

在 claude.ai/code/routines 建立，設定如下：

- **名稱**：`A→B 撰寫規格`
- **Repositories**：Request-Hub，以及所有要處理的專案 repo
- **分支推送**：若有「允許推送 claude/ 以外的分支」的選項，需開啟（skill 會推送 `feature/<單號>`）
- **Connectors**：只加入 Jira
- **Trigger**：排程（例如上班日每 2 小時）
- **提示詞**：

```
執行模式：雲端 Routine。

讀取 Request-Hub repo 中的 automation-skills/jira-spec-writer/SKILL.md，
完全依照其中的規則執行一次。

- 需要的 repo 已經 clone 在工作環境中，直接使用
- 結束時輸出 skill 規定的執行報告
```

第一次測試時，在提示詞加上「本次最多處理 1 張單」。

新增專案後，要回到 Routine 設定把新的專案 repo 加進 Repositories，否則該專案的單會被列在報告的「未處理的專案」。
