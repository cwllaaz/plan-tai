# 计划台 Android · 真实云端跨端/离线/冲突 E2E（真实 PocketBase + 模拟器 APK 内驱动）
#
# 拓扑：
#   真实 PocketBase 0.23.12（127.0.0.1:8090，独立测试数据目录）
#     ├─ Windows 对端：flutter test 使用真实仓储 + 真实同步引擎 + 真实 HTTP
#     └─ Android 模拟器：真实 App（integration_test 驱动）+ Keystore 令牌 + 真实 SQLite
#   adb reverse tcp:8090 让设备用 http://127.0.0.1:8090（loopback 才允许明文 HTTP）
#
# 关键约束：`flutter test integration_test -d <device>` 结束会卸载应用，应用私有数据
# （SQLite + Keystore 令牌）随之清空。所以整个用户旅程必须在**一次应用运行**内完成。
# 宿主与设备测试通过应用私有目录里的信号文件协调：
#   设备 -> 宿主：files/e2e_test_signal     （adb run-as cat 读）
#   宿主 -> 设备：files/e2e_host_signal     （adb run-as echo 写；测试轮询读）
#
# 覆盖：Windows 创建上传 → Android 登录下载 → Android 修改上传 → Windows 拉取删除/改色/
# 改阶段/改备注 → Android 拉取 → 两端改同一记录冲突不静默丢失 → 保留本机收敛 →
# 服务器停机离线修改进 outbox → 恢复后补传 → Windows 最终一致 + 重复同步幂等。
#
# 用法（ASCII worktree，模拟器已启动）：
#   powershell -ExecutionPolicy Bypass -File scripts/android/e2e_real_server_device.ps1
#   可选：-KeepServerData（复用测试服务端数据）、-KeepServer（结束时保留服务端）
#
# 注：Windows PowerShell 5.1 读取 .ps1 默认 ANSI，本文件必须以 UTF-8 BOM 保存（本仓库已带 BOM）。

param(
    [string]$RepoRoot = '',
    [int]$Port = 8090,
    [string]$Device = 'emulator-5554',
    [string]$PbExe = (Join-Path $env:TEMP 'jihuatai-e2e\pocketbase.exe'),
    [string]$DataDir = (Join-Path $env:TEMP 'jihuatai-e2e\pb_data_device'),
    [string]$EvidenceDir = (Join-Path $env:TEMP 'jihuatai-e2e\evidence'),
    [switch]$KeepServerData,
    [switch]$KeepServer
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
Set-Location $RepoRoot

if ($RepoRoot -match '[^\x00-\x7F]') {
    throw "Android 构建必须在纯 ASCII 路径下进行：$RepoRoot"
}
if (-not (Test-Path -LiteralPath $PbExe)) {
    throw "缺少 PocketBase 可执行文件：$PbExe（可先运行 scripts/e2e-real-server.ps1 下载）"
}

# 环境（只作用于当前进程）
$flutterSdk = if ($env:FLUTTER_SDK) { $env:FLUTTER_SDK } else { Split-Path -Parent (Split-Path -Parent (Get-Command flutter).Source) }`r`n$env:Path = "$flutterSdk\bin;$flutterSdk\bin\cache\dart-sdk\bin;" + $env:Path
if (-not $env:PUB_CACHE -and (Test-Path (Join-Path $env:USERPROFILE '.pub-cache'))) { $env:PUB_CACHE = Join-Path $env:USERPROFILE '.pub-cache' }
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.googleapis.com'
$env:ANDROID_HOME = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
$env:JAVA_HOME = if ($env:JAVA_HOME) { $env:JAVA_HOME } else { 'C:\Program Files\Java\jdk-21.0.11' }
$adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
$flutter = Join-Path $flutterSdk 'bin\flutter.bat'
$base = "http://127.0.0.1:$Port"

$adminEmail = 'admin@jihuatai.local'
# 本机测试服务器超级用户密码：优先取环境变量，仓库里不保存真实密码。
$adminPass = if ($env:JIHUATAI_DEV_ADMIN_PASS) { $env:JIHUATAI_DEV_ADMIN_PASS } else { 'DevOnly-ChangeMe-1' }
$userEmail = 'android-sync@jihuatai.local'
$userPass = 'TestPass12345'
$userName = 'android-sync'
$appId = 'com.jihuatai.planner'

$server = $null
$serverStarted = $false
$deviceProc = $null
$deviceLog = Join-Path $EvidenceDir 'device-cross-device.log'
$results = New-Object System.Collections.ArrayList

function Write-Step([string]$text) {
    Write-Host ""
    Write-Host "==> $text" -ForegroundColor Cyan
}

function Add-Result([string]$name, [bool]$ok, [string]$detail = '') {
    [void]$results.Add([pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail })
    $color = if ($ok) { 'Green' } else { 'Red' }
    $mark = if ($ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("  [{0}] {1} {2}" -f $mark, $name, $detail) -ForegroundColor $color
}

function Wait-Health([int]$timeoutSeconds = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($server -and $server.HasExited) { return $false }
        try {
            $response = Invoke-RestMethod -Uri "$base/api/planner/health" -TimeoutSec 3
            if ($response.status -eq 'ok') { return $true }
        } catch {
            Start-Sleep -Milliseconds 400
        }
    }
    return $false
}

function Start-Server([switch]$PreserveData) {
    if ($server -and -not $server.HasExited) { return }
    if (-not $PreserveData -and -not $KeepServerData -and (Test-Path -LiteralPath $DataDir)) {
        Remove-Item -LiteralPath $DataDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP 'jihuatai-e2e\logs') | Out-Null
    if (-not $serverStarted) {
        & $PbExe superuser upsert $adminEmail $adminPass --dir="$DataDir" | Out-Null
        $serverStarted = $true
    }
    $env:PA_RATE_LIMIT_AUTH = '500'
    $env:PA_RATE_LIMIT_SYNC = '2000'
    $stdout = Join-Path $env:TEMP 'jihuatai-e2e\logs\device-e2e-stdout.log'
    $stderr = Join-Path $env:TEMP 'jihuatai-e2e\logs\device-e2e-stderr.log'
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    $script:server = Start-Process -FilePath $PbExe -ArgumentList @(
        'serve', '--dev', "--http=127.0.0.1:$Port",
        "--dir=$DataDir",
        "--hooksDir=$RepoRoot\server\pb_hooks",
        "--migrationsDir=$RepoRoot\server\pb_migrations"
    ) -PassThru -WindowStyle Hidden -WorkingDirectory "$RepoRoot\server" `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (-not (Wait-Health)) {
        if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Tail 30 }
        throw "PocketBase 启动失败：$base"
    }
    Write-Host "  PocketBase PID=$($script:server.Id) data=$DataDir"
}

function Stop-Server {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }
    $script:server = $null
    # 等到端口真正关闭（设备端随后的同步请求必须失败，才能验证离线语义）。
    for ($i = 0; $i -lt 40; $i++) {
        $open = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
        if (-not $open) { return }
        Start-Sleep -Milliseconds 200
    }
    throw "PocketBase 未完全停止（端口 $Port 仍被占用）"
}

function Ensure-User {
    $admin = Invoke-RestMethod -Uri "$base/api/collections/_superusers/auth-with-password" `
        -Method Post -ContentType 'application/json' `
        -Body (@{ identity = $adminEmail; password = $adminPass } | ConvertTo-Json)
    try {
        $json = @{
            email = $userEmail; password = $userPass; passwordConfirm = $userPass
            name = 'Android E2E'; username = $userName; verified = $true
        } | ConvertTo-Json
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $record = Invoke-RestMethod -Uri "$base/api/collections/users/records" `
            -Method Post -Headers @{ Authorization = $admin.token } `
            -ContentType 'application/json; charset=utf-8' -Body $bytes
        Write-Host "  created test user $userEmail ($($record.id))"
    } catch {
        Write-Host "  test user exists or create failed: $($_.Exception.Message)"
    }
}

function Invoke-Peer([string]$phase, [string]$expectTitle = '') {
    $env:JIHUATAI_E2E_PEER = '1'
    $env:JIHUATAI_E2E_SERVER = $base
    $env:JIHUATAI_E2E_USER = $userEmail
    $env:JIHUATAI_E2E_PASS = $userPass
    $env:JIHUATAI_PEER_DIR = Join-Path $RepoRoot 'build\e2e-device\windows'
    $env:JIHUATAI_PEER_PHASE = $phase
    if ([string]::IsNullOrEmpty($expectTitle)) {
        Remove-Item Env:JIHUATAI_PEER_EXPECT_TITLE -ErrorAction SilentlyContinue
    } else {
        $env:JIHUATAI_PEER_EXPECT_TITLE = $expectTitle
    }
    Write-Host "  running Windows peer phase=$phase expect=$expectTitle"
    & $flutter test --no-pub --reporter expanded test/integration/e2e/windows_peer_test.dart
    if ($LASTEXITCODE -ne 0) { throw "Windows 对端阶段失败：$phase" }
    Add-Result "Windows 对端 · $phase" $true
}

function Read-TestSignal {
    # 应用可能还没安装/还没启动：run-as 失败属于正常等待态，不能中断脚本。
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $value = (& $adb -s $Device shell "run-as $appId cat files/e2e_test_signal" 2>$null) -join ''
        return ("$value").Trim()
    } catch {
        return ''
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Send-HostSignal([string]$marker) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & $adb -s $Device shell "run-as $appId sh -c 'echo $marker > files/e2e_host_signal'" 2>$null | Out-Null
    } finally {
        $ErrorActionPreference = $previous
    }
    Write-Host "  host -> device signal: $marker"
}

function Wait-TestSignal([string]$marker, [int]$timeoutSeconds = 300) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($deviceProc -and $deviceProc.HasExited) {
            $tail = if (Test-Path -LiteralPath $deviceLog) { (Get-Content $deviceLog -Tail 25) -join "`n" } else { '' }
            throw "设备测试进程提前退出（等待信号 $marker）。日志：`n$tail"
        }
        $value = Read-TestSignal
        if ($value -eq $marker) {
            Write-Host "  device -> host signal: $marker"
            return
        }
        Start-Sleep -Milliseconds 700
    }
    throw "等待设备信号超时：$marker（${timeoutSeconds}s）"
}

function Start-DeviceTest {
    New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
    Remove-Item -LiteralPath $deviceLog -Force -ErrorAction SilentlyContinue
    $env:JIHUATAI_E2E_SERVER = $base
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & $adb -s $Device reverse "tcp:$Port" "tcp:$Port" | Out-Null
    & $adb -s $Device shell pm clear $appId 2>$null | Out-Null
    $ErrorActionPreference = $previous
    # 用 .cmd 包装，避免 Start-Process 参数拼接把引号/重定向弄坏。
    $wrapper = Join-Path $EvidenceDir 'run-device-test.cmd'
    $command = '"' + $flutter + '" test --no-pub --reporter expanded ' +
        "--dart-define=E2E_SERVER=$base " +
        "--dart-define=E2E_ACCOUNT=$userEmail " +
        "--dart-define=E2E_PASSWORD=$userPass " +
        'integration_test/device_cross_device_test.dart -d ' + $Device +
        ' > "' + $deviceLog + '" 2>&1'
    $lines = @(
        '@echo off',
        'chcp 65001 > nul',
        ('cd /d "' + $RepoRoot + '"'),
        $command
    )
    Set-Content -LiteralPath $wrapper -Value $lines -Encoding ASCII
    $script:deviceProc = Start-Process -FilePath $wrapper -PassThru -WindowStyle Hidden
    Write-Host "  device test PID=$($script:deviceProc.Id) log=$deviceLog"
}

function Capture-Evidence {
    New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
    $pointerRaw = (& $adb -s $Device shell "run-as $appId cat files/data/cloud_workspace.json" 2>$null) -join ''
    $dbRel = 'files/data/app.db'
    if ($pointerRaw -match '"databasePath"\s*:\s*"([^"]+)"') {
        $rel = $Matches[1] -replace '\\', '/'
        $dbRel = "files/data/$rel"
    }
    Write-Host "  app db (device): $dbRel"
    $dbFile = Join-Path $EvidenceDir 'android-app.db'
    cmd /c "`"$adb`" -s $Device exec-out run-as $appId cat $dbRel > `"$dbFile`"" | Out-Null
    cmd /c "`"$adb`" -s $Device exec-out screencap -p > `"$(Join-Path $EvidenceDir 'android-final.png')`"" | Out-Null
    $serverDb = Join-Path $DataDir 'data.db'
    if (Test-Path -LiteralPath $serverDb) {
        Copy-Item -LiteralPath $serverDb -Destination (Join-Path $EvidenceDir 'server-pb_data.db') -Force
    }
    Add-Result "证据采集" $true $EvidenceDir
}

$exitCode = 0
try {
    Write-Step "0. 设备与网络准备"
    & $adb -s $Device wait-for-device | Out-Null
    & $adb -s $Device reverse "tcp:$Port" "tcp:$Port" | Out-Null
    Write-Host "  adb reverse tcp:$Port -> tcp:$Port"

    Write-Step "1. 启动真实 PocketBase + 测试账号；Windows 对端创建并上传初始数据"
    if (-not $KeepServerData) {
        Remove-Item -LiteralPath (Join-Path $RepoRoot 'build\e2e-device') -Recurse -Force -ErrorAction SilentlyContinue
    }
    Start-Server
    Ensure-User
    Add-Result "PocketBase 健康检查" (Wait-Health) $base
    Invoke-Peer 'initial'

    Write-Step "2. 启动 Android 真机/模拟器测试（单次运行完整旅程）"
    Start-DeviceTest

    Write-Step "3. 等待 Android 登录并下载云端数据"
    Wait-TestSignal 'downloaded' 420
    Add-Result "Android 登录并下载云端数据" $true

    Write-Step "4. 等待 Android 修改并上传"
    Wait-TestSignal 'uploaded' 600
    Add-Result "Android 修改并上传" $true

    Write-Step "5. Windows 对端拉取 Android 修改，删除任务/改项目颜色/阶段/备注并上传"
    Invoke-Peer 'verify'
    Send-HostSignal 'peer-verify-done'

    Write-Step "6. Android 拉取 Windows 改动并关闭自动同步"
    Wait-TestSignal 'windows-verified' 420
    Add-Result "Android 拉取 Windows 删除/颜色/阶段/备注" $true

    Write-Step "7. Windows 对端先改同一记录（制造真实冲突）"
    Invoke-Peer 'conflict'
    Send-HostSignal 'conflict-ready'

    Write-Step "8. Android 同步：冲突不静默丢失 → 保留本机 → 收敛上传"
    Wait-TestSignal 'conflict-resolved' 600
    Add-Result "Android 冲突保留两端并收敛" $true

    Write-Step "9. Windows 对端核对冲突解决结果（保留本机版本）"
    Invoke-Peer 'final' 'Windows创建任务-本地冲突版'
    Send-HostSignal 'conflict-verified'

    Write-Step "10. 停止服务器：Android 离线修改 → outbox 暂存"
    Stop-Server
    Send-HostSignal 'offline-ready'
    Wait-TestSignal 'offline-saved' 420
    Add-Result "Android 服务器停机离线修改落库进 outbox" $true

    Write-Step "11. 恢复服务器：Android 网络恢复后补传"
    Start-Server -PreserveData
    Ensure-User
    Send-HostSignal 'online-ready'
    Wait-TestSignal 'offline-synced' 420
    Add-Result "Android 网络恢复后离线修改补传" $true

    Write-Step "12. 采集证据（应用仍安装时）"
    Capture-Evidence

    Write-Step "13. Windows 对端最终核对（标题/删除/颜色/阶段/备注/幂等）"
    Invoke-Peer 'final' 'Windows创建任务-离线改'
    Send-HostSignal 'all-done'

    Write-Step "14. 等待 Android 测试进程结束"
    if (-not $deviceProc.WaitForExit(180000)) {
        throw '设备测试进程未在 3 分钟内退出'
    }
    if ($deviceProc.ExitCode -ne 0) {
        $tail = if (Test-Path -LiteralPath $deviceLog) { (Get-Content $deviceLog -Tail 40) -join "`n" } else { '' }
        throw "设备测试失败（exit $($deviceProc.ExitCode)）。日志：`n$tail"
    }
    Add-Result "Android 设备端完整旅程" $true (Join-Path $EvidenceDir 'device-cross-device.log')

    Write-Step "结果汇总"
    $failed = @($results | Where-Object { -not $_.Ok })
    foreach ($r in $results) {
        $mark = if ($r.Ok) { 'PASS' } else { 'FAIL' }
        Write-Host ("  [{0}] {1} {2}" -f $mark, $r.Name, $r.Detail)
    }
    if ($failed.Count -gt 0) { $exitCode = 1 }
} catch {
    Write-Host ""
    Write-Host "E2E 失败：$($_.Exception.Message)" -ForegroundColor Red
    Add-Result "E2E 流程" $false $_.Exception.Message
    if (Test-Path -LiteralPath $deviceLog) {
        Write-Host "---- device test log tail ----" -ForegroundColor Yellow
        Get-Content $deviceLog -Tail 40
    }
    $exitCode = 1
} finally {
    if ($deviceProc -and -not $deviceProc.HasExited) {
        & $adb -s $Device shell am force-stop $appId 2>$null | Out-Null
        Stop-Process -Id $deviceProc.Id -Force -ErrorAction SilentlyContinue
    }
    if (-not $KeepServer) { Stop-Server }
    Remove-Item Env:JIHUATAI_E2E_PEER -ErrorAction SilentlyContinue
}

exit $exitCode
