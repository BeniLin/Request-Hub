# 大型 repo 盤點指南

原則：**先看結構，再看內容；先統計，再深入。** 任何時候都不要用遞迴方式把整個 repo 讀進來。

## 1. 取得檔案清單

一律用 git 追蹤的檔案，自動排除被忽略的建置產物：

```
git ls-files | wc -l
git ls-files | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -20
```

依資料夾統計，找出主要程式碼所在：

```
git ls-files | cut -d/ -f1-2 | sort | uniq -c | sort -rn | head -30
```

即使在 git 中，也要排除以下內容不列入分析：

- 第三方套件：`vendor/`、`node_modules/`、`packages/` 中的外部套件、`third_party/`
- 建置產物：`dist/`、`build/`、`out/`、`bin/`、`obj/`、`*.min.js`、`*.map`
- 自動產生的程式碼：檔案開頭有 `auto-generated`、`DO NOT EDIT` 字樣的
- 靜態資源：圖片、字型、影音

## 2. 依技術棧找入口

先從設定檔判斷技術棧（`package.json`、`pom.xml`、`build.gradle`、`*.csproj`、`requirements.txt`、`pyproject.toml`、`composer.json`、`go.mod`），再找對應的入口：

| 技術 | 頁面／API 入口 |
|---|---|
| Express / Koa / Fastify | `app.get(`、`router.post(` 等路由定義 |
| Next.js | `app/` 或 `pages/` 資料夾結構本身就是路由 |
| NestJS | `@Controller`、`@Get`、`@Post` |
| Spring | `@RestController`、`@RequestMapping`、`@GetMapping` |
| ASP.NET | `Controllers/` 資料夾、`[HttpGet]`、`[Route]`、Minimal API 的 `app.MapGet` |
| Django | `urls.py` |
| Flask / FastAPI | `@app.route`、`@router.get` |
| Laravel | `routes/web.php`、`routes/api.php` |
| 前端 SPA | router 設定檔（`routes.ts`、`router/index.js`） |

其他入口：

- 排程與背景工作：`cron`、`@Scheduled`、`schedule`、`queue`、`worker`、`job`
- n8n：匯出的 workflow JSON（含 `"nodes"` 與 `"connections"` 的 JSON 檔）
- 資料庫：migration 資料夾、ORM model、`schema.sql`、`*.prisma`

用搜尋統計入口數量，而不是逐檔開啟：

```
git grep -l "@RestController" | wc -l
git grep -c "router\.\(get\|post\|put\|delete\)" -- '*.js' '*.ts'
```

文字比對算出的數量是粗估：用程式註冊的路由、寫法不同的裝飾器會漏掉，註解與字串會多算。向使用者報告時要說明是粗估。精確的清單在階段 3 完整讀過檔案後才有。

同時記錄實測條件，供使用者決定驗證深度：

- 啟動方式：`docker-compose.yml`、`Makefile`、`package.json` 的 scripts、README 的啟動說明
- 自動化測試：測試資料夾、測試框架、執行指令
- 外部服務：設定檔與環境變數範例檔中出現的外部系統（只記名稱）

## 3. 切分功能領域

依**業務功能**切，不要依技術分層切。

- 錯誤的切法：「Controllers」「Services」「前端」「資料庫」
- 正確的切法：「會員」「訂單」「報價」「通知」

線索：

- 路由前綴（`/api/member/*`、`/api/order/*`）
- 資料夾名稱（`modules/member`、`features/order`）
- 資料表群組（`member_*`、`order_*`）
- 前端選單結構

一個領域的合理大小：一個人能在一兩天內講清楚它在做什麼。太大就拆，太小（只有一兩個 API）就併入相關領域。

## 4. 統計修改頻率

近一年各資料夾被修改的次數，用來排優先順序：

```
git log --since="1 year ago" --name-only --pretty=format: | grep -v '^$' | cut -d/ -f1-3 | sort | uniq -c | sort -rn | head -30
```

修改頻繁的領域最常有新需求，最值得先建立規格。

## 5. 找出既有文件

```
git ls-files '*.md' '*.txt' '*.adoc' '*.rst' | grep -vi -e changelog -e license -e node_modules -e vendor
git ls-files | grep -i -e openapi -e swagger -e '\.yaml$' -e '\.yml$'
```

讀每份文件的開頭判斷內容，分成：

- 業務規則或功能說明：可以直接列入索引（若在允許的資料夾內）
- 安裝、部署、開發環境說明：不列入規格索引
- 過時或與程式碼明顯不符：記錄下來，讓使用者決定

## 6. 讀程式碼找規則（階段 3 使用）

階段 3 的完整做法（清點前端操作、後端入口、資料寫入，以及情境檢查表）見 `behavior-inventory.md`。以下是追蹤時要特別留意的規則類型：

- 條件判斷中的業務常數（金額門檻、天數、等級、狀態值）
- 計算邏輯（價格、費用、分數、時間）
- 狀態欄位與狀態轉換
- 權限與角色檢查
- 輸入驗證規則與錯誤訊息
- 對外部系統的呼叫，以及呼叫失敗時的處理
- 既有測試的測試名稱與斷言，它們直接描述了預期行為

不需要記錄：框架樣板程式碼、日誌、純技術性的重試與快取機制（除非會影響使用者看到的結果）。
