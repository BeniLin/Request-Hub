# 需求工作區初始設定（Windows）
# 請在工作區根目錄雙擊 setup.cmd 執行，不需要直接執行這個檔案。

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Write-Step($msg) { Write-Host "`n== $msg ==" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  [!]  $msg" -ForegroundColor Yellow }
function Write-Bad($msg)  { Write-Host "  [X]  $msg" -ForegroundColor Red }

function Update-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Install-WithWinget($id, $displayName) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Bad "找不到 winget，請手動安裝 $displayName 後重新執行 setup。"
        exit 1
    }
    Write-Host "  正在安裝 $displayName ..."
    winget install --id $id -e --accept-source-agreements --accept-package-agreements
    Update-PathFromRegistry
}

$hasProblem = $false

# 1. Git（Claude Code 在 Windows 上需要 Git for Windows 提供的 Git Bash）
Write-Step '檢查 Git'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Install-WithWinget 'Git.Git' 'Git for Windows'
}
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Ok (git --version)
} else {
    Write-Bad '安裝後仍找不到 git，請關閉視窗重新開啟後再執行一次 setup。'
    exit 1
}

# 2. GitHub CLI
Write-Step '檢查 GitHub CLI（gh）'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Install-WithWinget 'GitHub.cli' 'GitHub CLI'
}
if (Get-Command gh -ErrorAction SilentlyContinue) {
    Write-Ok ((gh --version | Select-Object -First 1))
} else {
    Write-Bad '安裝後仍找不到 gh，請關閉視窗重新開啟後再執行一次 setup。'
    exit 1
}

# 3. GitHub 登入
Write-Step '檢查 GitHub 登入狀態'
$ErrorActionPreference = 'Continue'
gh auth status --hostname github.com *> $null
$loggedIn = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = 'Stop'
if ($loggedIn) {
    Write-Ok '已登入 GitHub'
} else {
    Write-Host '  即將開啟瀏覽器登入 GitHub，請依畫面指示操作。'
    gh auth login --hostname github.com --git-protocol https --web
    if ($LASTEXITCODE -ne 0) {
        Write-Bad 'GitHub 登入失敗，請重新執行 setup。'
        exit 1
    }
    Write-Ok '登入完成'
}

# 4. 檢查各專案的存取權限
Write-Step '檢查各專案規格的讀取權限'
$projects = Import-Csv -Path (Join-Path $Root 'projects\registry.csv') -Encoding UTF8
foreach ($p in $projects) {
    $endpoint = "repos/$($p.repo)/contents/$($p.specs_dir)/INDEX.md?ref=$($p.branch)"
    $ErrorActionPreference = 'Continue'
    gh api $endpoint --silent *> $null
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -eq 0) {
        Write-Ok "$($p.key)（$($p.repo)）"
    } else {
        Write-Bad "$($p.key)（$($p.repo)）：讀不到 $($p.specs_dir)/INDEX.md。可能是沒有 repo 權限、repo 名稱錯誤，或該專案尚未建立索引檔。"
        $hasProblem = $true
    }
}

# 5. 更新工作區
Write-Step '更新需求工作區'
$ErrorActionPreference = 'Continue'
git -C $Root pull --ff-only --quiet *> $null
$pulled = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = 'Stop'
if ($pulled) { Write-Ok '已是最新版' } else { Write-Warn '自動更新失敗，請稍後手動執行 git pull。' }

# 完成
Write-Step '完成'
if ($hasProblem) {
    Write-Warn '部分專案讀取失敗，請將上方紅色訊息提供給工作區管理員。其他專案仍可正常使用。'
}
Write-Host @"

接下來：
  1. 開啟 Claude Desktop，切換到 Code 分頁
  2. 選擇這個資料夾：$Root
  3. 第一次開啟時，選擇信任這個資料夾
  4. 輸入 /mcp，選擇 jira，用瀏覽器登入你的 Atlassian 帳號
  5. 直接描述你的需求，例如「我想討論一個 SHOP 的新需求」

"@
