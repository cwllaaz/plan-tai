# 计划台 Android 构建环境（dot-source 使用）
#
#   . scripts/android/env.ps1
#
# 约定：
# - 不写死任何本机路径；Flutter / JDK / Android SDK 通过环境变量或自动探测得到。
# - 只作用于当前进程，不修改用户 / 机器级环境变量。
# - Android 构建**必须**在纯 ASCII 路径下进行：AGP 会拒绝非 ASCII 工程路径。
# - 需要镜像源时自行设置：$env:PUB_HOSTED_URL / $env:FLUTTER_STORAGE_BASE_URL。

$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path (Join-Path $script:RepoRoot 'pubspec.yaml'))) {
    $script:RepoRoot = (Get-Location).Path
}

# Flutter
if (-not $env:FLUTTER_SDK) {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) { $env:FLUTTER_SDK = Split-Path -Parent (Split-Path -Parent $cmd.Source) }
}
if (-not $env:FLUTTER_SDK -or -not (Test-Path (Join-Path $env:FLUTTER_SDK 'bin\flutter.bat'))) {
    throw '未找到 Flutter SDK：请设置环境变量 FLUTTER_SDK，或把 Flutter 加入 PATH。'
}
$env:Path = "$env:FLUTTER_SDK\bin;$env:FLUTTER_SDK\bin\cache\dart-sdk\bin;" + $env:Path

# pub 缓存：有则沿用，否则交给 Flutter 默认值（%LOCALAPPDATA%\Pub\Cache）
if (-not $env:PUB_CACHE -and (Test-Path (Join-Path $env:USERPROFILE '.pub-cache'))) {
    $env:PUB_CACHE = Join-Path $env:USERPROFILE '.pub-cache'
}

# Android SDK
if (-not $env:ANDROID_HOME) {
    $candidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    if (Test-Path $candidate) { $env:ANDROID_HOME = $candidate }
}
if (-not $env:ANDROID_HOME -or -not (Test-Path $env:ANDROID_HOME)) {
    throw '未找到 Android SDK：请设置环境变量 ANDROID_HOME。'
}
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME

# JDK 21：显式设置优先；否则尝试 Android Studio 自带的 JBR；再否则用 PATH 上的 java。
if (-not $env:JAVA_HOME -or -not (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
    $studioCandidates = @(
        (Join-Path $env:ProgramFiles 'Android\Android Studio\jbr'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Android Studio\jbr'),
        'C:\Program Files\Android\Android Studio\jbr'
    )
    $env:JAVA_HOME = $null
    foreach ($jbr in $studioCandidates) {
        if (Test-Path (Join-Path $jbr 'bin\java.exe')) { $env:JAVA_HOME = $jbr; break }
    }
    if (-not $env:JAVA_HOME) {
        Write-Warning '未找到 JDK：请设置 JAVA_HOME 指向 JDK 21。'
    }
}

function Get-BuildToolPath {
    param([string]$FileName, [string]$SdkRoot = $env:ANDROID_HOME)
    $buildTools = Join-Path $SdkRoot 'build-tools'
    if (-not (Test-Path $buildTools)) { return $null }
    $candidates = Get-ChildItem $buildTools -Directory |
        Sort-Object { try { [version]$_.Name } catch { [version]'0.0.0' } } -Descending
    foreach ($candidate in $candidates) {
        $path = Join-Path $candidate.FullName $FileName
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Get-AaptPath { param([string]$SdkRoot = $env:ANDROID_HOME) Get-BuildToolPath 'aapt.exe' $SdkRoot }
function Get-ApkSignerPath { param([string]$SdkRoot = $env:ANDROID_HOME) Get-BuildToolPath 'apksigner.bat' $SdkRoot }

function Assert-AsciiRepoPath {
    param([string]$Path = (Get-Location).Path)
    if ([regex]::IsMatch($Path, '[^\x00-\x7F]')) {
        Write-Warning ("当前路径包含非 ASCII 字符：{0}`nAGP 会拒绝该路径，请把仓库克隆到纯 ASCII 路径后再构建。" -f $Path)
        return $false
    }
    return $true
}

Write-Host 'Android 构建环境：' -ForegroundColor Cyan
Write-Host "  flutter  : $env:FLUTTER_SDK\bin\flutter.bat"
Write-Host "  JAVA_HOME: $env:JAVA_HOME"
Write-Host "  SDK      : $env:ANDROID_HOME"
Write-Host "  PUB_CACHE: $env:PUB_CACHE"
if (-not (Assert-AsciiRepoPath)) {
    Write-Host '  （继续操作前请先切换到 ASCII 路径）' -ForegroundColor Yellow
}
