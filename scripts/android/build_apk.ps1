# 计划台 Android 构建（debug / release）
#
#   powershell -File scripts/android/build_apk.ps1                       # debug arm64
#   powershell -File scripts/android/build_apk.ps1 -Mode release -Check   # release + APK 内容检查
#   powershell -File scripts/android/build_apk.ps1 -Abi all -SplitPerAbi  # 发布用分 ABI 包
#
# 说明：
# - 必须在 ASCII 路径下构建（AGP 拒绝中文路径），脚本会先检查并拒绝继续；
# - `-Mode release` 且没有 android/key.properties 时，Gradle 会回退 debug 签名并在
#   构建日志里打印 WARNING —— 这种包只能功能验证，不能发布/覆盖升级；
# - 构建成功后打印 APK 路径、大小、SHA-256。

[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'debug',
    [ValidateSet('arm64', 'arm', 'x64', 'all')]
    [string]$Abi = 'arm64',
    [switch]$SplitPerAbi,
    [switch]$Check,
    [switch]$RequireReleaseSignature,
    [switch]$NoPub
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repoRoot
try {
    if (-not (Assert-AsciiRepoPath -Path $repoRoot)) {
        Write-Host "`n中止：Android 构建必须在纯 ASCII 目录中进行。" -ForegroundColor Red
        exit 1
    }

    $arguments = @('build', 'apk', "--$Mode")
    switch ($Abi) {
        'arm64' { $arguments += @('--target-platform', 'android-arm64') }
        'arm' { $arguments += @('--target-platform', 'android-arm') }
        'x64' { $arguments += @('--target-platform', 'android-x64') }
    }
    if ($SplitPerAbi) { $arguments += '--split-per-abi' }
    if ($NoPub) { $arguments += '--no-pub' }

    $pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
    $lockPath = Join-Path $repoRoot 'pubspec.lock'
    $pubspecBackup = $null
    $lockBackup = $null

    # Flutter 3.50 会把 dev_dependency 插件（integration_test）也写进
    # GeneratedPluginRegistrant，导致 Android release 编译引用 release classpath 中
    # 不存在的测试插件而失败；若直接删除该生成文件，release 包又会漏注册正式插件
    # （path_provider），真机启动即失败。
    # 正确做法：release 构建期间临时从 pubspec 移除 integration_test 并重新 pub get，
    # 构建结束（无论成败）恢复 pubspec/pubspec.lock 并再 pub get，仓库源码保持不变。
    if ($Mode -eq 'release') {
        $pubspecBackup = [IO.File]::ReadAllText($pubspecPath)
        if (Test-Path -LiteralPath $lockPath) {
            $lockBackup = [IO.File]::ReadAllText($lockPath)
        }
        $stripped = [regex]::Replace(
            $pubspecBackup,
            "(?m)^  integration_test:\s*\r?\n    sdk: flutter\s*\r?\n",
            ''
        )
        if ($stripped -eq $pubspecBackup) {
            throw '未能从 pubspec.yaml 临时移除 integration_test（键名/缩进可能已变化），已中止 release 构建。'
        }
        [IO.File]::WriteAllText($pubspecPath, $stripped, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "`n（release 构建：临时移除 dev 插件 integration_test 并重新解析依赖）" -ForegroundColor DarkGray
        & flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 失败（release 依赖解析）' }
        # 需要让 build 使用上面刚解析的依赖，不能再传 --no-pub。
        $arguments = @($arguments | Where-Object { $_ -ne '--no-pub' })
    }

    try {
        Write-Host "`n>>> flutter $($arguments -join ' ')" -ForegroundColor Cyan
        $global:LASTEXITCODE = 0
        & flutter @arguments
        if ($LASTEXITCODE -ne 0) {
            Write-Host "`n构建失败（exit $LASTEXITCODE）。" -ForegroundColor Red
            exit $LASTEXITCODE
        }
    } finally {
        if ($Mode -eq 'release' -and $null -ne $pubspecBackup) {
            [IO.File]::WriteAllText($pubspecPath, $pubspecBackup, (New-Object System.Text.UTF8Encoding($false)))
            if ($null -ne $lockBackup) {
                [IO.File]::WriteAllText($lockPath, $lockBackup, (New-Object System.Text.UTF8Encoding($false)))
            }
            # 恢复开发/测试用的依赖与 GeneratedPluginRegistrant。
            & flutter pub get | Out-Null
            Write-Host "（已恢复 pubspec.yaml / pubspec.lock 与开发依赖）" -ForegroundColor DarkGray
        }
    }

    $apkDirectory = Join-Path $repoRoot 'build\app\outputs\flutter-apk'
    $apks = Get-ChildItem $apkDirectory -Filter '*.apk' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "-$Mode" } |
        Sort-Object Name

    if (-not $apks -or $apks.Count -eq 0) {
        Write-Host "`n未找到构建产物（期望 $apkDirectory 下的 *-$Mode*.apk）。" -ForegroundColor Red
        exit 1
    }

    Write-Host "`n===== 构建产物 =====" -ForegroundColor Green
    foreach ($apk in $apks) {
        $hash = (Get-FileHash $apk.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Host ("路径 : {0}" -f $apk.FullName)
        Write-Host ("大小 : {0:N1} MB" -f ($apk.Length / 1MB))
        Write-Host ("SHA256: {0}" -f $hash)
        Write-Host ''
    }

    if ($Check) {
        foreach ($apk in $apks) {
            $checkArgs = @{
                Apk    = $apk.FullName
                Mode   = $Mode
            }
            if ($RequireReleaseSignature) { $checkArgs.RequireReleaseSignature = $true }
            & (Join-Path $PSScriptRoot 'check_apk.ps1') @checkArgs
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
    }

    if ($Mode -eq 'release' -and -not (Test-Path (Join-Path $repoRoot 'android\key.properties'))) {
        Write-Host "提示：未配置 android/key.properties，本次 release 包使用 DEBUG 签名。" -ForegroundColor Yellow
        Write-Host "      可安装/可功能验证，但**不能发布、不能覆盖升级**正式签名的安装。" -ForegroundColor Yellow
        Write-Host "      正式签名见 scripts/android/gen_keystore.ps1。" -ForegroundColor Yellow
    }

    exit 0
}
finally {
    Pop-Location
}
