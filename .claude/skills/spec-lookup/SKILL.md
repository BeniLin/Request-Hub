---
name: spec-lookup
description: 讀取各專案 GitHub repo 上的規格文件（固定讀 main 分支，不受使用者本機分支影響）。討論需求、確認現有規則、檢查衝突、審查規格，或使用者問「現在的規則是什麼」「某功能目前怎麼運作」時，都要使用這個 skill 讀取文件，不要憑印象回答。
---

# 讀取專案規格

所有專案文件都透過 `scripts/read-spec.sh` 從 GitHub 讀取。這個腳本只能讀、不能改，而且預設讀取 `projects/registry.csv` 設定的主分支，所以不管使用者電腦上的 repo 停在哪個分支都不受影響。

## 呼叫方式（必須完全照抄格式）

```
bash scripts/read-spec.sh <專案KEY> <檔案路徑>
bash scripts/read-spec.sh --list <專案KEY> <資料夾路徑>
```

範例：

```
bash scripts/read-spec.sh SHOP specs/INDEX.md
bash scripts/read-spec.sh --list SHOP specs/member
bash scripts/read-spec.sh SHOP specs/member/discount.md
```

規則：

- 一律以 `bash scripts/read-spec.sh` 開頭，**不要**改寫成 `./scripts/...` 或絕對路徑，也**不要**在後面接 `|`、`&&`、`>` 等其他指令。不照格式會被系統擋下並要求使用者確認
- 一次讀一個檔案
- 不要用 `git`、`gh`、`curl` 或讀取本機資料夾的方式取得專案文件

只有 `review-assist` 審查分支上的規格時，才會在最後加上分支名稱作為第三個參數，平常不要加。

## 讀取順序

1. **先讀 `INDEX.md`**：每個專案的規格資料夾都有一份索引，列出每份文件涵蓋的功能。路徑見 `projects/registry.csv` 的 `specs_dir` 欄位
2. 依索引挑出相關的文件再讀，不要把整個資料夾讀完
3. 索引不存在或內容明顯過時，才用 `--list` 列出資料夾內容，並提醒使用者該專案的 `INDEX.md` 需要更新

## 回報方式

引用規格時，一律註明來源檔案與章節，例如：「依 `specs/member/discount.md` 第 2 節，金卡會員目前是 95 折。」

讀取失敗時，直接告訴使用者錯誤訊息，不要改用猜測的內容繼續。常見原因：

- 檔案路徑錯誤：用 `--list` 確認正確路徑
- 沒有權限：請使用者確認自己的 GitHub 帳號能存取該 repo，或重新執行 setup
- 尚未登入：請使用者執行 `gh auth login`
