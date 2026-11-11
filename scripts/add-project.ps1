# 新增或更新專案設定
# 會寫入 projects/registry.csv 與 projects/<KEY>.md
# 請在工作區根目錄雙擊 add-project.cmd 執行，不需要直接執行這個檔案。

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root        = Split-Path -Parent $PSScriptRoot
$ProjectsDir = Join-Path $Root 'projects'
$Registry    = Join-Path $ProjectsDir 'registry.csv'
$Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)
$Header      = 'key,name,repo,branch,specs_dir,read_dirs'
$SampleRepo  = 'your-org/shop-web'
$NotSet      = '（尚未設定）'

# ---------- 輸入工具 ----------

function Write-Section($title) {
    Write-Host ''
    Write-Host "==== $title ====" -ForegroundColor Cyan
}

function Write-Hint($text) { Write-Host "  $text" -ForegroundColor DarkGray }
function Write-Warn($text) { Write-Host "  [!] $text" -ForegroundColor Yellow }
function Write-Good($text) { Write-Host "  [OK] $text" -ForegroundColor Green }

# 詢問一個值。可設定預設值、必填、驗證規則
function Ask {
    param(
        [string]$Prompt,
        [string]$Default = '',
        [switch]$Required,
        [switch]$NoComma,
        [string]$Pattern = '',
        [string]$PatternMessage = '格式不正確'
    )
    while ($true) {
        if ($Default) { $label = "$Prompt [$Default]" } else { $label = $Prompt }
        $value = Read-Host $label
        if ($null -eq $value) { $value = '' }
        $value = $value.Trim()
        if (-not $value) { $value = $Default }

        if ($Required -and -not $value) { Write-Warn '此欄位必填'; continue }
        if ($NoComma -and $value.Contains(',')) { Write-Warn '不可包含逗號 ,'; continue }
        if ($value -and $Pattern -and ($value -notmatch $Pattern)) { Write-Warn $PatternMessage; continue }
        return $value
    }
}

function Ask-YesNo([string]$Prompt, [bool]$Default = $true) {
    if ($Default) { $hint = 'Y/n' } else { $hint = 'y/N' }
    while ($true) {
        $value = Read-Host "$Prompt ($hint)"
        if ($null -eq $value) { $value = '' }
        $value = $value.Trim().ToLower()
        if (-not $value) { return $Default }
        if ($value -in @('y', 'yes')) { return $true }
        if ($value -in @('n', 'no')) { return $false }
    }
}

# 逐行輸入，直接按 Enter 結束
function Ask-Lines([string]$Prompt) {
    Write-Hint "$Prompt（一次輸入一行，直接按 Enter 結束）"
    $lines = @()
    while ($true) {
        $value = Read-Host '  >'
        if ($null -eq $value) { break }
        $value = $value.Trim()
        if (-not $value) { break }
        $lines += $value
    }
    return ,$lines
}

# ---------- 其他工具 ----------

function Test-Gh {
    return [bool](Get-Command gh -ErrorAction SilentlyContinue)
}

# 執行 gh，失敗時不中斷，回傳 @{ Ok; Output }
function Invoke-Gh([string[]]$GhArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & gh @GhArgs 2>$null
        $ok = ($LASTEXITCODE -eq 0)
    } catch {
        $out = $null
        $ok = $false
    } finally {
        $ErrorActionPreference = $prev
    }
    return @{ Ok = $ok; Output = $out }
}

function Normalize-Repo([string]$Value) {
    $v = $Value.Trim()
    $v = $v -replace '^https?://(www\.)?github\.com/', ''
    $v = $v -replace '^git@github\.com:', ''
    $v = $v -replace '\.git$', ''
    $v = $v.Trim('/')
    return $v
}

function Normalize-Dir([string]$Value) {
    return ($Value.Trim() -replace '\\', '/').Trim('/')
}

function Escape-Cell([string]$Value) {
    return $Value.Replace('|', '\|')
}

function Read-RegistryRows {
    if (-not (Test-Path $Registry)) { return ,@() }
    $all = [System.IO.File]::ReadAllLines($Registry, $Utf8NoBom)
    $rows = @()
    for ($i = 1; $i -lt $all.Length; $i++) {
        $line = $all[$i].Trim()
        if ($line) { $rows += $line }
    }
    return ,$rows
}

function Get-RowKey([string]$Row) { return ($Row -split ',')[0] }

# ---------- 開始 ----------

Write-Host ''
Write-Host '新增／更新專案設定' -ForegroundColor White
Write-Hint '方括號 [ ] 裡是預設值，直接按 Enter 就會使用。'
Write-Hint '所有內容在最後預覽確認前都不會寫入。'

$rows = Read-RegistryRows
$hasGh = Test-Gh
if (-not $hasGh) {
    Write-Warn '找不到 gh，將略過 repo 檢查。建議先執行 setup.cmd。'
}

# 範例專案
$removeSample = $false
$sampleRows = @($rows | Where-Object { ($_ -split ',')[2] -eq $SampleRepo })
if ($sampleRows.Count -gt 0) {
    Write-Host ''
    $removeSample = Ask-YesNo '偵測到範本內建的範例專案 SHOP（your-org/shop-web），要一併刪除嗎？' $true
}

# ---------- 1. 基本資訊 ----------

Write-Section '1/6 基本資訊'

$key = (Ask -Prompt '專案 Key（建議與 Jira 專案 Key 相同，例如 STOCK）' -Required `
        -Pattern '^[A-Za-z][A-Za-z0-9_]{1,9}$' `
        -PatternMessage '需為 2 到 10 個英數字，以英文字母開頭').ToUpper()

$existing = $rows | Where-Object { (Get-RowKey $_) -eq $key } | Select-Object -First 1
$old = @{}
if ($existing) {
    if ($removeSample -and $key -eq 'SHOP') {
        $existing = $null
    } else {
        Write-Warn "專案 $key 已存在。"
        if (-not (Ask-YesNo '要更新這個專案的設定嗎？（會覆蓋原本的 .md 檔）' $false)) {
            Write-Host '已取消。'
            exit 0
        }
        $p = $existing -split ','
        $old = @{ name = $p[1]; repo = $p[2]; branch = $p[3]; specs = $p[4]; read = $p[5] }
    }
}

$name = Ask -Prompt '專案名稱（例如 股票系統）' -Default $old.name -Required -NoComma

$repo = $null
while (-not $repo) {
    $repoInput = Ask -Prompt 'GitHub repo（org/repo，或直接貼上網址）' -Default $old.repo -Required
    $candidate = Normalize-Repo $repoInput
    if ($candidate -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        Write-Warn "無法辨識為 org/repo 格式：$candidate"
        continue
    }
    $repo = $candidate
}

$defaultBranch = 'main'
if ($old.branch) { $defaultBranch = $old.branch }
if ($hasGh) {
    $r = Invoke-Gh @('repo', 'view', $repo, '--json', 'defaultBranchRef', '--jq', '.defaultBranchRef.name')
    if ($r.Ok -and $r.Output) {
        $defaultBranch = ([string]$r.Output).Trim()
        Write-Good "可以存取 $repo，主分支為 $defaultBranch"
    } else {
        Write-Warn "無法存取 $repo（名稱錯誤，或你的 GitHub 帳號沒有權限）。仍可繼續設定。"
    }
}

$branch = Ask -Prompt '主分支' -Default $defaultBranch -Required -NoComma -Pattern '^[A-Za-z0-9._/-]+$'

$specsDefault = 'specs'
if ($old.specs) { $specsDefault = $old.specs }
$specsDir = Normalize-Dir (Ask -Prompt '規格資料夾' -Default $specsDefault -Required -NoComma)
$docsDir  = Normalize-Dir (Ask -Prompt '實作文件資料夾' -Default 'docs' -Required -NoComma)

$readDefault = (@($specsDir, $docsDir, 'changes') | Select-Object -Unique) -join ';'
if ($old.read) { $readDefault = $old.read }
Write-Hint 'Claude 只能讀取以下資料夾，用分號 ; 分隔。'
$readDirs = Ask -Prompt '允許讀取的資料夾' -Default $readDefault -Required -NoComma

$indexFound = $false
if ($hasGh) {
    $r = Invoke-Gh @('api', "repos/$repo/contents/$specsDir/INDEX.md?ref=$branch", '--silent')
    $indexFound = $r.Ok
    if ($indexFound) {
        Write-Good "找到 $specsDir/INDEX.md"
    } else {
        Write-Warn "$repo 的 $branch 分支上找不到 $specsDir/INDEX.md，完成後請記得建立（範本見 docs/spec-index-template.md）。"
    }
}

# ---------- 2. 專案說明 ----------

Write-Section '2/6 專案說明'

$intro = Ask-Lines '用兩三句話說明這個系統做什麼、給誰用'

Write-Host ''
Write-Hint '領域名詞：這個專案特有的用語，幫助 Claude 理解需求。直接按 Enter 結束。'
$terms = @()
while ($true) {
    $term = Ask -Prompt '名詞'
    if (-not $term) { break }
    $meaning = Ask -Prompt "  「$term」的意思" -Required
    $terms += ,@($term, $meaning)
}

# ---------- 3. Jira 設定 ----------

Write-Section '3/6 Jira 設定'

$storyType   = Ask -Prompt '主單議題類型' -Default 'Story' -Required
$subtaskType = Ask -Prompt 'Subtask 議題類型' -Default 'Subtask' -Required
$components  = Ask -Prompt '元件（Component），用逗號分隔；沒有就直接 Enter'
$labels      = Ask -Prompt '標籤，用逗號分隔' -Default 'ai-req'

Write-Host ''
Write-Hint '自訂欄位 ID 查詢方式：Jira 設定 → 議題 → 自訂欄位 → 點欄位的「…」→ 編輯，'
Write-Hint '網址中 id= 後面的數字就是 ID。輸入數字即可，不知道就直接 Enter 之後再補。'

function Ask-FieldId([string]$Label) {
    $v = Ask -Prompt $Label -Pattern '^(customfield_)?\d+$' -PatternMessage '請輸入數字，或 customfield_ 加數字'
    if (-not $v) { return $NotSet }
    if ($v -match '^\d+$') { $v = "customfield_$v" }
    return "``$v``"
}

$fieldLock  = Ask-FieldId '「處理中」欄位 ID'
$fieldRetry = Ask-FieldId '「退回次數」欄位 ID'

# ---------- 4. 審查人 ----------

Write-Section '4/6 審查人'
Write-Hint '不確定可以直接 Enter，之後再補。'

$reviewB = Ask -Prompt 'B 規格確認'
$reviewF = Ask -Prompt 'F 畫面與程式碼'
$reviewH = Ask -Prompt 'H 上版核准'

# ---------- 5. 相關專案 ----------

Write-Section '5/6 相關專案'

$otherKeys = @($rows | ForEach-Object { Get-RowKey $_ } | Where-Object { $_ -ne $key })
if ($removeSample) { $otherKeys = @($otherKeys | Where-Object { $_ -ne 'SHOP' }) }
if ($otherKeys.Count -gt 0) {
    Write-Hint ("目前已設定的專案：" + ($otherKeys -join '、'))
}
Write-Hint '跟其他專案有資料或介面往來的話填寫。直接按 Enter 結束。'
$related = @()
while ($true) {
    $rk = Ask -Prompt '相關專案 Key'
    if (-not $rk) { break }
    $rk = $rk.ToUpper()
    $rel = Ask -Prompt "  與 $rk 的關係（例如：本專案呼叫 $rk 的會員 API）" -Required
    $related += ,@($rk, $rel)
}

# ---------- 6. 注意事項 ----------

Write-Section '6/6 注意事項'
$notes = Ask-Lines '討論需求時需要特別注意的事（例如：金額一律四捨五入到整數）'

# ---------- 組合內容 ----------

function Show-Value([string]$Value) {
    if ($Value) { return $Value } else { return $NotSet }
}

function Join-Code([string]$Csv) {
    $items = @($Csv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($items.Count -eq 0) { return '無' }
    return ($items | ForEach-Object { "``$_``" }) -join '、'
}

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# ${key}：$name")
$md.Add('')
$md.Add('## 基本資訊')
$md.Add('')
$md.Add("- **Jira 專案 Key**：$key")
$md.Add("- **GitHub repo**：$repo")
$md.Add("- **主分支**：$branch")
$md.Add("- **規格資料夾**：``$specsDir/``（索引：``$specsDir/INDEX.md``）")
$md.Add("- **實作文件資料夾**：``$docsDir/``")
$md.Add('')
$md.Add('## 專案簡介')
$md.Add('')
if ($intro.Count -gt 0) { foreach ($l in $intro) { $md.Add($l) } } else { $md.Add($NotSet) }
$md.Add('')
$md.Add('## 領域名詞')
$md.Add('')
if ($terms.Count -gt 0) {
    $md.Add('| 名詞 | 意思 |')
    $md.Add('|---|---|')
    foreach ($t in $terms) { $md.Add("| $(Escape-Cell $t[0]) | $(Escape-Cell $t[1]) |") }
} else {
    $md.Add($NotSet)
}
$md.Add('')
$md.Add('## Jira 設定')
$md.Add('')
$md.Add('建單時使用以下設定值，不要自行猜測。')
$md.Add('')
$md.Add("- **主單議題類型**：$storyType")
$md.Add("- **Subtask 議題類型**：$subtaskType")
if ($components) { $compText = ((@($components -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) -join '、') } else { $compText = '無' }
$md.Add("- **元件（Component）**：$compText")
$md.Add("- **標籤**：$(Join-Code $labels)")
$md.Add("- **自訂欄位「處理中」**：$fieldLock")
$md.Add("- **自訂欄位「退回次數」**：$fieldRetry")
$md.Add('')
$md.Add('## 審查人')
$md.Add('')
$md.Add('| 關卡 | 審查人 |')
$md.Add('|---|---|')
$md.Add("| B 規格確認 | $(Escape-Cell (Show-Value $reviewB)) |")
$md.Add("| F 畫面與程式碼 | $(Escape-Cell (Show-Value $reviewF)) |")
$md.Add("| H 上版核准 | $(Escape-Cell (Show-Value $reviewH)) |")
$md.Add('')
$md.Add('## 相關專案')
$md.Add('')
if ($related.Count -gt 0) { foreach ($r in $related) { $md.Add("- $($r[0])：$($r[1])") } } else { $md.Add('無') }
$md.Add('')
$md.Add('## 注意事項')
$md.Add('')
if ($notes.Count -gt 0) { foreach ($n in $notes) { $md.Add("- $n") } } else { $md.Add('無') }

$mdText = ($md -join "`n") + "`n"
$newRow = "$key,$name,$repo,$branch,$specsDir,$readDirs"
$mdPath = Join-Path $ProjectsDir "$key.md"

# ---------- 預覽與寫入 ----------

Write-Section '預覽'
Write-Host "registry.csv 將寫入：" -ForegroundColor White
Write-Host "  $newRow"
if ($removeSample) { Write-Host '  並刪除範例專案 SHOP（含 projects/SHOP.md）' }
Write-Host ''
Write-Host "projects/$key.md 內容：" -ForegroundColor White
Write-Host '----------------------------------------'
Write-Host $mdText
Write-Host '----------------------------------------'

if (-not (Ask-YesNo '確認寫入嗎？' $true)) {
    Write-Host '已取消，沒有寫入任何檔案。'
    exit 0
}

$keep = @($rows | Where-Object {
    $k = Get-RowKey $_
    $isSample = ($_ -split ',')[2] -eq $SampleRepo
    ($k -ne $key) -and -not ($removeSample -and $isSample)
})
$allRows = @($Header) + $keep + @($newRow)
[System.IO.File]::WriteAllText($Registry, (($allRows -join "`n") + "`n"), $Utf8NoBom)
[System.IO.File]::WriteAllText($mdPath, $mdText, $Utf8NoBom)

if ($removeSample) {
    $samplePath = Join-Path $ProjectsDir 'SHOP.md'
    if ((Test-Path $samplePath) -and $key -ne 'SHOP') { Remove-Item $samplePath }
}

Write-Section '完成'
Write-Good "已更新 projects/registry.csv"
Write-Good "已寫入 projects/$key.md"

$todo = @()
if (-not $indexFound) { $todo += "在 $repo 建立 $specsDir/INDEX.md（範本見 docs/spec-index-template.md）" }
if ($fieldLock -eq $NotSet -or $fieldRetry -eq $NotSet) { $todo += "補上 projects/$key.md 的 Jira 自訂欄位 ID" }
if (-not $reviewB -or -not $reviewF -or -not $reviewH) { $todo += "補上 projects/$key.md 的審查人" }
if ($todo.Count -gt 0) {
    Write-Host ''
    Write-Host '之後還需要：' -ForegroundColor Yellow
    foreach ($t in $todo) { Write-Host "  - $t" }
}

Write-Host ''
Write-Host '確認內容無誤後，commit 並推上去，其他人才會拿到新設定：' -ForegroundColor White
Write-Host '  git add projects'
Write-Host "  git commit -m `"新增專案 $key`""
Write-Host '  git push'
Write-Host ''
