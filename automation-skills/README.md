# 自動化 Skill

這個資料夾放的是**由 Claude Code Routine 自動執行**的 skill，不是給人在工作區對話時使用的。

刻意不放在 `.claude/skills/`，避免成員討論需求時被載入。Routine 透過提示詞明確指定檔案路徑來讀取。

| Skill | 流程步驟 | 狀態 |
|---|---|---|
| `jira-spec-writer` | 步驟 3：撰寫規格 | A 待撰寫規格 → B 待確認規格 |
| `jira-test-writer` | 步驟 5：撰寫測試 | T 待寫測試 → C 待實作（有問題時 → D 待人工處理） |
| `jira-implementer` | 步驟 6：實作 | C 待實作 → E 待驗證（有問題時 → D 待人工處理） |
| `jira-changelog-writer` | 步驟 10：撰寫 ChangeLog | G 待寫 ChangeLog → H 待上版核准 |

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

## Routine 設定：步驟 5 撰寫測試

另外建立一個 Routine，設定與步驟 3 相同，只有名稱與提示詞不同：

- **名稱**：`T→C 撰寫測試`
- **Repositories**：Request-Hub，以及所有要處理的專案 repo
- **分支推送**：開啟 Allow unrestricted branch pushes
- **Environment**：預設即可。需要能從 npm 安裝套件，用來做語法檢查
- **Connectors**：只加入 Jira
- **Trigger**：排程。建議與步驟 3 的時間錯開，避免同時消耗額度
- **提示詞**：

```
執行模式：雲端 Routine。

讀取 Request-Hub repo 中的 automation-skills/jira-test-writer/SKILL.md，
完全依照其中的規則執行一次。

- 如果讀不到這個檔案，立刻停止，回報錯誤，不要做任何其他動作
- 需要的 repo 已經 clone 在工作環境中，直接使用
- 結束時輸出 skill 規定的執行報告
```

第一次測試時，在提示詞加上「本次最多處理 1 張單」。

## Routine 設定：步驟 6 實作

- **名稱**：`C→E 實作`
- **Repositories**：Request-Hub，以及所有要處理的專案 repo
- **分支推送**：開啟 Allow unrestricted branch pushes
- **Environment**：需要能安裝專案的相依套件，用來執行單元測試。裝不起來時 skill 會照常送出，並在 Jira 註明「單元測試未執行」
- **Connectors**：只加入 Jira
- **Trigger**：排程。實作是用量最大的一步，建議排在你自己比較少使用 Claude 的時段
- **提示詞**：

```
執行模式：雲端 Routine。

讀取 Request-Hub repo 中的 automation-skills/jira-implementer/SKILL.md，
完全依照其中的規則執行一次。

- 如果讀不到這個檔案，立刻停止，回報錯誤，不要做任何其他動作
- 需要的 repo 已經 clone 在工作環境中，直接使用
- 結束時輸出 skill 規定的執行報告
```

這個 skill 預設一次只處理 1 張單。

這一步會開立 PR。Routine 的環境沒有開立 PR 的權限時，skill 會在 Jira 註明「未能開立 PR，請手動開立」，不影響後續的自動驗證。

## Routine 設定：步驟 10 撰寫 ChangeLog

- **名稱**：`G→H 撰寫 ChangeLog`
- **Repositories**、**分支推送**、**Connectors**：與其他 Routine 相同
- **Environment**：預設即可
- **Trigger**：排程，每天一到兩次就足夠
- **提示詞**：

```
執行模式：雲端 Routine。

讀取 Request-Hub repo 中的 automation-skills/jira-changelog-writer/SKILL.md，
完全依照其中的規則執行一次。

- 如果讀不到這個檔案，立刻停止，回報錯誤，不要做任何其他動作
- 需要的 repo 已經 clone 在工作環境中，直接使用
- 結束時輸出 skill 規定的執行報告
```

## commit 訊息的前綴

各步驟的 commit 訊息前綴是固定的，步驟 8 與步驟 12 會依此檢查受保護的資料夾有沒有被不該動的步驟修改：

| 前綴 | 步驟 | 可以修改 |
|---|---|---|
| `spec(<單號>):` | 3 撰寫規格 | `specs/` |
| `test(<單號>):` | 5 撰寫測試 | `tests/e2e/` |
| `feat(`、`fix(`、`docs(` | 6 實作 | 原始碼、單元測試、`docs/` |
| `chore(<單號>): changelog` | 10 撰寫 ChangeLog | `changes/<單號>.md` |

## 共通注意事項

- 每個 Routine 的提示詞都要包含「讀不到檔案就立刻停止」。否則讀取失敗時，Claude 可能會憑自己的理解去操作 Jira 與 repo
- 步驟 3 的提示詞也請補上這一句
