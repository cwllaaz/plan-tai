# 计划台 Ubuntu 移植阶段 2：Windows ↔ Ubuntu 真实跨 OS 双向同步一键脚本
#
# 前提：
#   1) 本机（Windows）已按 scripts/e2e-real-server.ps1 的方式装好 PocketBase 0.23.12
#      并可用 `server/bin/pocketbase.exe`；或允许本脚本用 -ResetData 重建本地测试数据目录；
#   2) 有一台可 SSH 的 Ubuntu 目标机（阶段 1/2 用 QEMU 虚拟机，默认 127.0.0.1:2222），
#      且 guest 上已有本仓库（默认 /home/ubuntu/jihuatai）与 Flutter 3.50；
#   3) guest 上已存在运行动作脚本 run_cross_step.sh。
#
# 脚本做的事：
#   1) 检查/启动本地 PocketBase 测试服务器（只监听 127.0.0.1，不碰生产服务器）；
#   2) 为本轮测试创建一个全新的测试账号（避免历史数据影响断言）；
#   3) Windows 执行 windows-seed 步骤（本地建数据 → 首次绑定上传）；
#   4) 把状态文件复制到 guest，guest 执行 ubuntu-modify（下载并修改，再上传）；
#   5) Windows 执行 windows-verify（跨 OS 冲突/删除/校验）；
#   6) guest 执行 ubuntu-final（下载 Windows 修改、幂等、账号隔离）；
#   7) 汇总各步骤测试结果。
#
# 注意：默认不重置 PocketBase 数据目录；如需干净环境请先手动重置 server/pb_data。
param(
    [string]$RepoRoot = '',
    [int]$Port = 8090,
    [string]$SshHost = '127.0.0.1',
    [int]$SshPort = 2222,
    [string]$SshKey = 'D:\UbuntuVm\id_ed25519',
    [string]$GuestUser = 'ubuntu',
    [string]$GuestRepo = '/home/ubuntu/jihuatai',
    [string]$Email = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$serverRoot = Join-Path $RepoRoot 'server'
$exe = Join-Path $serverRoot 'bin\pocketbase.exe'
$base = "http://127.0.0.1:$Port"
$sshOptions = @('-i', $SshKey, '-p', "$SshPort", '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR')
$stateLocal = Join-Path $RepoRoot 'build\e2e-cross\state.json'

function Step([string]$text) { Write-Host "`n==> $text" -ForegroundColor Cyan }

function Wait-Health([int]$timeoutSeconds = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-RestMethod -Uri "$base/api/planner/health" -TimeoutSec 3
            if ($r.status -eq 'ok') { return $true }
        } catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

function Invoke-Admin([string]$path, [hashtable]$body, [string]$token = '') {
    $headers = @{}
    if ($token) { $headers['Authorization'] = $token }
    $json = $body | ConvertTo-Json
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Uri "$base$path" -Method Post -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body $bytes
}

function New-TestAccount([string]$email, [string]$password) {
    $admin = Invoke-Admin '/api/collections/_superusers/auth-with-password' @{
        identity = 'admin@jihuatai.local'
        password = if ($env:JIHUATAI_DEV_ADMIN_PASS) { $env:JIHUATAI_DEV_ADMIN_PASS } else { 'DevOnly-ChangeMe-1' }
    }
    try {
        $rec = Invoke-Admin '/api/collections/users/records' @{
            email = $email; password = $password; passwordConfirm = $password
            name = 'Cross OS E2E'; username = ($email.Split('@')[0]); verified = $true
        } $admin.token
        Write-Host "    新建测试账号 $email ($($rec.id))"
    } catch {
        Write-Host "    账号已存在或创建失败：$($_.Exception.Message)"
    }
}

function Invoke-WindowsStep([string]$step) {
    $env:JIHUATAI_E2E = '1'
    $env:JIHUATAI_E2E_SERVER = $base
    $env:JIHUATAI_E2E_USER = $Email
    $env:JIHUATAI_E2E_PASS = 'TestPass12345'
    $env:JIHUATAI_E2E_USER2 = 'sync-other@jihuatai.local'
    $env:JIHUATAI_E2E_PASS2 = 'TestPass12345'
    $env:JIHUATAI_E2E_STEP = $step
    Push-Location $RepoRoot
    try {
        & flutter test --no-pub --reporter expanded test/integration/cross_os_sync_test.dart
        if ($LASTEXITCODE -ne 0) { throw "Windows step $step 失败（exit=$LASTEXITCODE）" }
    } finally { Pop-Location }
}

function Invoke-GuestStep([string]$step, [string]$stateIn, [string]$stateOut) {
    $remoteIn = "/home/ubuntu/$([IO.Path]::GetFileName($stateIn))"
    $remoteOut = "/home/ubuntu/$([IO.Path]::GetFileName($stateOut))"
    & scp.exe @sshOptions $stateIn "${GuestUser}@${SshHost}:$remoteIn"
    if ($LASTEXITCODE -ne 0) { throw "复制状态文件到 guest 失败" }
    & ssh.exe @sshOptions "${GuestUser}@${SshHost}" `
        "bash /home/ubuntu/run_cross_step.sh $step $remoteIn $remoteOut"
    if ($LASTEXITCODE -ne 0) { throw "guest step $step 失败（exit=$LASTEXITCODE）" }
    & scp.exe @sshOptions "${GuestUser}@${SshHost}:$remoteOut" $stateOut
    if ($LASTEXITCODE -ne 0) { throw "从 guest 取回状态文件失败" }
}

Step '检查本地 PocketBase 测试服务器'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "缺少 $exe。请先运行 scripts/e2e-real-server.ps1 或手工放置 PocketBase 0.23.12。"
}
if (-not (Wait-Health 5)) {
    Write-Host '    服务器未运行，尝试启动（使用 server/pb_data 现有数据目录）'
    $env:PA_RATE_LIMIT_AUTH = '500'
    $env:PA_RATE_LIMIT_SYNC = '2000'
    Start-Process -FilePath $exe -ArgumentList @(
        'serve', '--dev', "--http=127.0.0.1:$Port",
        "--dir=$serverRoot\pb_data",
        "--hooksDir=$serverRoot\pb_hooks",
        "--migrationsDir=$serverRoot\pb_migrations"
    ) -WindowStyle Hidden -WorkingDirectory $serverRoot | Out-Null
    if (-not (Wait-Health)) { throw "PocketBase 启动失败/健康检查超时：$base" }
}
Write-Host "    OK：$base"

Step '准备全新测试账号'
if ([string]::IsNullOrWhiteSpace($Email)) {
    $Email = "cross-os-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())@jihuatai.local"
}
New-TestAccount $Email 'TestPass12345'

Step 'Guest 反向隧道（guest 127.0.0.1:8090 → 本机 PocketBase）'
& ssh.exe @sshOptions "${GuestUser}@${SshHost}" 'bash -c "curl -fsS --max-time 3 http://127.0.0.1:8090/api/planner/health >/dev/null 2>&1"'
if ($LASTEXITCODE -ne 0) {
    Start-Process -FilePath ssh.exe -ArgumentList (@('-i', $SshKey, '-p', "$SshPort",
        '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
        '-o', 'ExitOnForwardFailure=yes', '-R', "8090:127.0.0.1:$Port", '-N',
        "${GuestUser}@${SshHost}")) -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 2
}
Step '上传跨 OS 测试文件到 guest'
& scp.exe @sshOptions (Join-Path $RepoRoot 'test\integration\cross_os_sync_test.dart') `
    "${GuestUser}@${SshHost}:$GuestRepo/test/integration/cross_os_sync_test.dart"

$stateSeed = Join-Path $RepoRoot 'build\e2e-cross\state-windows-seed.json'
$stateUbuntu = Join-Path $RepoRoot 'build\e2e-cross\state-ubuntu-modify.json'
$stateVerify = Join-Path $RepoRoot 'build\e2e-cross\state-windows-verify.json'

Step 'Windows: windows-seed（建数据 + 首次绑定上传）'
Invoke-WindowsStep 'windows-seed'
Copy-Item $stateLocal $stateSeed -Force

Step 'Ubuntu: ubuntu-modify（下载校验 + 修改 + 离线队列上传）'
Invoke-GuestStep 'ubuntu-modify' $stateSeed $stateUbuntu
Copy-Item $stateUbuntu $stateLocal -Force

Step 'Windows: windows-verify（跨 OS 冲突解决 + 删除 + 校验 Ubuntu 修改）'
Invoke-WindowsStep 'windows-verify'
Copy-Item $stateLocal $stateVerify -Force

Step 'Ubuntu: ubuntu-final（下载 Windows 修改 + 幂等 + 账号隔离）'
Invoke-GuestStep 'ubuntu-final' $stateVerify (Join-Path $RepoRoot 'build\e2e-cross\state-final.json')

Write-Host "`n全部跨 OS 步骤通过。测试账号：$Email" -ForegroundColor Green
