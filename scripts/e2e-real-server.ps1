# 计划台 V2.0 · 真实 PocketBase 双客户端 E2E 一键脚本
#
# 作用：
#   1. 如缺 PocketBase 可执行文件则下载 0.23.12（Windows amd64）；
#   2. 默认清空 server/pb_data（-KeepData 可保留），启动本地服务器；
#   3. 准备管理员与两个普通测试账号；
#   4. 以真实 HTTP + 两个隔离客户端库运行 test/integration/real_server_sync_test.dart；
#   5. 结束时停止服务器。
#
# 只监听 127.0.0.1，不触碰生产服务器与真实用户数据目录。
# Script is ASCII-only on purpose (Windows PowerShell 5.1 reads .ps1 as ANSI).

param(
    [switch]$KeepData,
    [int]$Port = 8090,
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$serverRoot = Join-Path $RepoRoot 'server'
$binDir = Join-Path $serverRoot 'bin'
$exe = Join-Path $binDir 'pocketbase.exe'
$dataDir = Join-Path $serverRoot 'pb_data'
$hooksDir = Join-Path $serverRoot 'pb_hooks'
$migrationsDir = Join-Path $serverRoot 'pb_migrations'

$adminEmail = 'admin@jihuatai.local'
# 本机测试服务器超级用户密码：优先取环境变量，仓库里不保存真实密码。
$adminPass = if ($env:JIHUATAI_DEV_ADMIN_PASS) { $env:JIHUATAI_DEV_ADMIN_PASS } else { 'DevOnly-ChangeMe-1' }
$user1 = 'sync-test@jihuatai.local'
$user2 = 'sync-other@jihuatai.local'
$userPass = 'TestPass12345'
$base = "http://127.0.0.1:$Port"

function Write-Step([string]$text) {
    Write-Host "==> $text" -ForegroundColor Cyan
}

# ---------------------------------------------------------------- PocketBase
if (-not (Test-Path -LiteralPath $exe)) {
    Write-Step 'Downloading PocketBase 0.23.12'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $zip = Join-Path $binDir 'pocketbase.zip'
    $url = 'https://github.com/pocketbase/pocketbase/releases/download/v0.23.12/pocketbase_0.23.12_windows_amd64.zip'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $binDir -Force
    Remove-Item -LiteralPath $zip -Force
}

Write-Step 'Stopping any running local PocketBase'
Get-Process pocketbase -ErrorAction SilentlyContinue | Stop-Process -Force
for ($i = 0; $i -lt 20; $i++) {
    if (-not (Get-Process pocketbase -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 300
}
Start-Sleep -Milliseconds 500

if (-not $KeepData -and (Test-Path -LiteralPath $dataDir)) {
    Write-Step 'Resetting server/pb_data'
    Remove-Item -LiteralPath $dataDir -Recurse -Force
}

Write-Step 'Ensuring superuser'
& $exe superuser upsert $adminEmail $adminPass --dir="$dataDir" | Out-Null

$env:PA_RATE_LIMIT_AUTH = '500'
$env:PA_RATE_LIMIT_SYNC = '2000'

Write-Step "Starting PocketBase at $base"
$outLog = Join-Path $serverRoot 'pb_e2e_stdout.log'
$errLog = Join-Path $serverRoot 'pb_e2e_stderr.log'
Remove-Item -LiteralPath $outLog, $errLog -Force -ErrorAction SilentlyContinue
$server = Start-Process -FilePath $exe -ArgumentList @(
    'serve', '--dev', "--http=127.0.0.1:$Port",
    "--dir=$dataDir",
    "--hooksDir=$hooksDir",
    "--migrationsDir=$migrationsDir"
) -PassThru -WindowStyle Hidden -WorkingDirectory $serverRoot `
  -RedirectStandardOutput $outLog -RedirectStandardError $errLog

function Wait-Health([int]$timeoutSeconds = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($server.HasExited) {
            Write-Host 'PocketBase exited early. stderr:' -ForegroundColor Red
            if (Test-Path -LiteralPath $errLog) { Get-Content -LiteralPath $errLog -Tail 30 }
            return $false
        }
        try {
            $response = Invoke-RestMethod -Uri "$base/api/planner/health" -TimeoutSec 3
            if ($response.status -eq 'ok') { return $true }
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    return $false
}

try {
    if (-not (Wait-Health)) {
        throw "PocketBase health check failed at $base"
    }
    Write-Step 'Health OK'

    # ------------------------------------------------------------ accounts
    $admin = Invoke-RestMethod -Uri "$base/api/collections/_superusers/auth-with-password" `
        -Method Post -ContentType 'application/json' `
        -Body (@{ identity = $adminEmail; password = $adminPass } | ConvertTo-Json)

    function Ensure-User([string]$email, [string]$name, [string]$username) {
        try {
            $json = @{
                email = $email; password = $userPass; passwordConfirm = $userPass
                name = $name; username = $username; verified = $true
            } | ConvertTo-Json
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $record = Invoke-RestMethod -Uri "$base/api/collections/users/records" `
                -Method Post -Headers @{ Authorization = $admin.token } `
                -ContentType 'application/json; charset=utf-8' -Body $bytes
            Write-Host "    created $email ($($record.id))"
        } catch {
            Write-Host "    $email already exists or create failed: $($_.Exception.Message)"
        }
    }

    Write-Step 'Ensuring test accounts'
    Ensure-User $user1 'E2E User One' 'sync-test'
    Ensure-User $user2 'E2E User Two' 'sync-other'

    # ---------------------------------------------------------------- test
    Write-Step 'Running flutter test (real server)'
    $env:JIHUATAI_E2E = '1'
    $env:JIHUATAI_E2E_SERVER = $base
    $env:JIHUATAI_E2E_USER = $user1
    $env:JIHUATAI_E2E_PASS = $userPass
    $env:JIHUATAI_E2E_USER2 = $user2
    $env:JIHUATAI_E2E_PASS2 = $userPass
    $flutter = if ($env:FLUTTER_SDK -and (Test-Path (Join-Path $env:FLUTTER_SDK 'bin\flutter.bat'))) {
        Join-Path $env:FLUTTER_SDK 'bin\flutter.bat'
    } else {
        'flutter'
    }

    Push-Location $RepoRoot
    try {
        & $flutter test --no-pub --reporter expanded `
            test/integration/real_server_sync_test.dart
        $testExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    Write-Step "flutter test exit code: $testExit"
} finally {
    if ($server -and -not $server.HasExited) {
        Write-Step 'Stopping PocketBase'
        Stop-Process -Id $server.Id -Force
    }
}
