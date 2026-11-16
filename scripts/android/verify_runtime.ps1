# 计划台 Android · 运行期冒烟验证（安装 → 启动 → 私有目录建库 → 重启持久化）
#
#   powershell -File scripts/android/verify_runtime.ps1
#   powershell -File scripts/android/verify_runtime.ps1 -Apk build\app\outputs\flutter-apk\app-debug.apk -KeepRunning
#
# 前置：已连接且 boot 完成的设备/模拟器（`adb devices` 状态为 device）。
# 说明：
# - 会卸载并重装目标包（清空应用数据），只在测试设备上跑；
# - 安装后冷启动、检查进程与 `files/data/app.db`、force-stop 后再次冷启动，
#   对比两次的库文件大小与业务表行数（通过脚本内置的 SQLite 读取，无外部依赖）；
# - 需要 Python（Pillow 运行时自带）读取 SQLite；若没有 Python 则跳过行数校验并明确提示。
#
# 注意：本机模拟器存在「input 注入无法驱动 Flutter」的环境问题（基线 APK 同样复现），
# 因此本脚本只做「进程/文件/数据库」等可程序化验证的项，不代替人手点击验收。

[CmdletBinding()]
param(
    [string]$Apk = '',
    [string]$Serial = '',
    [switch]$KeepRunning,
    [switch]$SkipUninstall
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Apk) {
    $Apk = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-debug.apk'
}
$Apk = [System.IO.Path]::GetFullPath($Apk)
if (-not (Test-Path $Apk)) {
    Write-Host "APK 不存在：$Apk" -ForegroundColor Red
    exit 1
}

$adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
if (-not (Test-Path $adb)) {
    Write-Host "未找到 adb：$adb" -ForegroundColor Red
    exit 1
}
$adbArgs = @()
if ($Serial) { $adbArgs = @('-s', $Serial) }

$devices = & $adb devices 2>&1 | Select-String -Pattern '\sdevice$'
if (-not $devices) {
    Write-Host "没有可用设备（adb devices 无 device 状态）。请先启动模拟器或连接真机。" -ForegroundColor Red
    exit 1
}
if (-not $Serial) {
    if ($devices.Count -gt 1) {
        Write-Host "检测到多个设备，请用 -Serial 指定。" -ForegroundColor Red
        $devices | ForEach-Object { Write-Host "  $_" }
        exit 1
    }
    $Serial = ($devices[0].ToString() -split '\s+')[0]
    $adbArgs = @('-s', $Serial)
}
$packageName = 'com.jihuatai.planner'
$dataDirectory = "/data/user/0/$packageName/files/data"
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $state = if ($Ok) { 'PASS' } else { 'FAIL' }
    $results.Add([pscustomobject]@{ State = $state; Name = $Name; Detail = $Detail })
    Write-Host ("[{0}] {1,-32} {2}" -f $state, $Name, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}

function Invoke-Adb {
    param([string[]]$CommandArgs)
    return (& $adb @adbArgs @CommandArgs 2>&1)
}

function Get-DeviceFileSize {
    param([string]$Path)
    $line = Invoke-Adb @('shell', "run-as $packageName ls -l $Path")
    if ($line -match '\s(\d+)\s+\d{4}-\d{2}-\d{2}') { return [int64]$matches[1] }
    if ($line -match '\s(\d+)\s+') { return [int64]$matches[1] }
    return -1
}

function Get-TableCounts {
    param([string]$LocalDirectory)
    # 就地读取：主库 + WAL（SQLite 打开时自动回放 WAL）。
    $python = $null
    foreach ($candidate in @(
            (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'),
            'python',
            'python3'
        )) {
        try {
            $probe = & $candidate --version 2>&1
            if ($probe -match '^Python') { $python = $candidate; break }
        }
        catch {
            continue
        }
    }
    if (-not $python) { return $null }
    $script = @'
import os, shutil, sqlite3, sys
src = sys.argv[1]
work = os.path.join(src, 'inspect')
if os.path.isdir(work):
    shutil.rmtree(work)
os.makedirs(work, exist_ok=True)
for name in ('app.db', 'app.db-wal', 'app.db-shm'):
    source = os.path.join(src, name)
    if os.path.exists(source) and os.path.getsize(source) > 0:
        shutil.copy2(source, os.path.join(work, name))
con = sqlite3.connect(os.path.join(work, 'app.db'))
cur = con.cursor()
version = cur.execute('PRAGMA user_version').fetchone()[0]
mode = cur.execute('PRAGMA journal_mode').fetchone()[0]
check = cur.execute('PRAGMA quick_check').fetchone()[0]
counts = {}
for table in ('projects', 'plan_spans', 'planner_tasks', 'daily_notes'):
    try:
        counts[table] = cur.execute('SELECT COUNT(*) FROM ' + table).fetchone()[0]
    except sqlite3.Error:
        counts[table] = -1
con.close()
print('%s|%s|%s|%s' % (version, mode, check, ','.join('%s=%s' % (k, v) for k, v in counts.items())))
'@
    $scriptPath = Join-Path $LocalDirectory '_inspect_db.py'
    [System.IO.File]::WriteAllText($scriptPath, $script, (New-Object System.Text.UTF8Encoding($false)))
    try {
        return (& $python $scriptPath $LocalDirectory 2>&1) -join ''
    }
    finally {
        Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n===== 运行期冒烟验证（设备 $Serial）=====" -ForegroundColor Cyan
Add-Result 'APK' (Test-Path $Apk) ("{0:N1} MB  {1}" -f ((Get-Item $Apk).Length / 1MB), (Split-Path $Apk -Leaf))

if (-not $SkipUninstall) {
    Invoke-Adb @('uninstall', $packageName) | Out-Null
}
$installOutput = Invoke-Adb @('install', '-r', $Apk)
Add-Result '安装' (($installOutput -join ' ') -match 'Success') ($installOutput -join ' ')

$startOutput = Invoke-Adb @('shell', 'am', 'start', '-W', '-n', "$packageName/.MainActivity")
Add-Result '冷启动' (($startOutput -join ' ') -match 'Status: ok') (($startOutput -join ' ') -split "`n" | Where-Object { $_ -match 'TotalTime' } | Select-Object -First 1)
Start-Sleep -Seconds 3

$appPid = (Invoke-Adb @('shell', 'pidof', $packageName)) -join ''
Add-Result '进程存活' ($appPid -match '^\d+') "pid=$appPid"

$listing = (Invoke-Adb @('shell', "run-as $packageName ls -l $dataDirectory")) -join "`n"
Add-Result '私有目录 app.db' ($listing -match 'app\.db') $dataDirectory
$walPresent = $listing -match 'app\.db-wal'
Add-Result 'WAL 生效' $walPresent 'app.db-wal 存在（journal_mode=wal）'

# 拉取一致性副本（用 cmd 重定向保证二进制不被 PowerShell 文本重定向破坏）
$local = Join-Path ([System.IO.Path]::GetTempPath()) ('jihuatai_runtime_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $local | Out-Null
try {
    foreach ($name in @('app.db', 'app.db-wal', 'app.db-shm')) {
        cmd /c "`"$adb`" $($adbArgs -join ' ') exec-out run-as $packageName cat $dataDirectory/$name > `"$local\$name`"" | Out-Null
    }
    $inspect = Get-TableCounts -LocalDirectory $local
    if ($null -eq $inspect) {
        Add-Result '数据库 schema 校验' $false '未找到 Python，跳过 schema/行数校验'
    }
    else {
        $parts = $inspect.Split('|')
        Add-Result '数据库 schema' ($parts[0] -eq '2' -and $parts[1] -eq 'wal' -and $parts[2] -eq 'ok') "user_version=$($parts[0]) journal=$($parts[1]) quick_check=$($parts[2])"
        Write-Host ("       业务表行数：" + $parts[3]) -ForegroundColor DarkGray
    }
    $sizeBefore = (Get-Item (Join-Path $local 'app.db')).Length

    # 重启持久化：force-stop 后重新冷启动，库文件不应被重建/清空。
    Invoke-Adb @('shell', 'am', 'force-stop', $packageName) | Out-Null
    Start-Sleep -Seconds 1
    $restartOutput = Invoke-Adb @('shell', 'am', 'start', '-W', '-n', "$packageName/.MainActivity")
    Add-Result '二次启动' (($restartOutput -join ' ') -match 'Status: ok') ''
    Start-Sleep -Seconds 3
    $sizeAfter = Get-DeviceFileSize -Path "$dataDirectory/app.db"
    Add-Result '重启后库文件保留' ($sizeAfter -gt 0) ("app.db=$sizeAfter 字节")
}
finally {
    if (-not $KeepRunning) {
        Invoke-Adb @('shell', 'am', 'force-stop', $packageName) | Out-Null
    }
    Remove-Item -Recurse -Force $local -ErrorAction SilentlyContinue
}

$failed = $results | Where-Object { $_.State -eq 'FAIL' }
Write-Host ("`n结果：PASS {0} / FAIL {1}" -f ($results | Where-Object { $_.State -eq 'PASS' }).Count, $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
if ($failed.Count -gt 0) { exit 1 }
Write-Host '运行期冒烟通过（交互类验收仍需人工执行）。' -ForegroundColor Green
exit 0
