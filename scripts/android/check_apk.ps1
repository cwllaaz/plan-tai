# 计划台 Android APK 内容检查
#
#   powershell -File scripts/android/check_apk.ps1                       # 默认检查 debug 包
#   powershell -File scripts/android/check_apk.ps1 -Mode release -RequireReleaseSignature
#
# 检查项（任一 FAIL 退出码 1）：
#   - 包名 / versionCode / versionName / minSdk / targetSdk
#   - 应用名（中文不用乱码判定，按 aapt UTF-8 输出比对）
#   - 所需权限（INTERNET / ACCESS_NETWORK_STATE）与「没有多余存储权限」
#   - 启动 Activity、应用图标资源
#   - 备份策略（allowBackup=true + fullBackupContent + dataExtractionRules）
#   - 明文流量策略（usesCleartextTraffic=false；debug 包允许 localhost 配置）
#   - 原生库（libsqlite3.so / libflutter.so）与 ABI
#   - 16KB 页对齐（arm64 .so 的 LOAD 段 Align = 0x4000，Android 15 设备要求）
#   - 自定义原生通道类是否编进 APK（SecureStorePlugin / StoragePlugin）
#   - 签名者（debug 签名可装可测，但不可发布）
#
# 依赖：Android SDK build-tools 里的 aapt / apksigner，NDK 里的 llvm-readelf（可缺省）。

[CmdletBinding()]
param(
    [string]$Apk = '',
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'debug',
    [string]$ExpectApplicationId = 'com.jihuatai.planner',
    [string]$ExpectAppLabel = '计划台',
    [switch]$RequireReleaseSignature
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Apk) {
    $fileName = if ($Mode -eq 'release') { 'app-release.apk' } else { 'app-debug.apk' }
    $Apk = Join-Path $repoRoot "build\app\outputs\flutter-apk\$fileName"
}
$Apk = [System.IO.Path]::GetFullPath($Apk)

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '', [switch]$Skip)
    if ($Skip) {
        $script:Results.Add([pscustomobject]@{ State = 'SKIP'; Name = $Name; Detail = $Detail })
        Write-Host ("[SKIP] {0,-34} {1}" -f $Name, $Detail) -ForegroundColor DarkGray
        return
    }
    $state = if ($Ok) { 'PASS' } else { 'FAIL' }
    $script:Results.Add([pscustomobject]@{ State = $state; Name = $Name; Detail = $Detail })
    $color = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1,-34} {2}" -f $state, $Name, $Detail) -ForegroundColor $color
}

Write-Host "`n===== APK 内容检查：$Apk =====" -ForegroundColor Cyan
Add-Check 'APK 文件存在' (Test-Path $Apk) $(if (Test-Path $Apk) { "{0:N1} MB" -f ((Get-Item $Apk).Length / 1MB) } else { '文件不存在' })
if (-not (Test-Path $Apk)) { exit 1 }

$aapt = Get-AaptPath
if (-not $aapt) {
    Add-Check 'aapt 可用' $false '未在 Android SDK build-tools 找到 aapt.exe'
    exit 1
}
Add-Check 'aapt 可用' $true $aapt

$badging = (& $aapt dump badging $Apk 2>&1 | Out-String)
$manifestTree = (& $aapt dump xmltree $Apk AndroidManifest.xml 2>&1 | Out-String)

# ---------------- 包名 / 版本 / SDK ----------------
$packageMatch = [regex]::Match($badging, "package: name='(?<name>[^']*)' versionCode='(?<code>[^']*)' versionName='(?<version>[^']*)'")
Add-Check '包名（冻结，不可改）' ($packageMatch.Success -and $packageMatch.Groups['name'].Value -eq $ExpectApplicationId) $(if ($packageMatch.Success) { $packageMatch.Groups['name'].Value } else { '解析失败' })
if ($packageMatch.Success) {
    Add-Check 'versionCode' ([int]$packageMatch.Groups['code'].Value -ge 1) "versionCode=$($packageMatch.Groups['code'].Value)"
    Add-Check 'versionName' ([string]::IsNullOrWhiteSpace($packageMatch.Groups['version'].Value) -eq $false) "versionName=$($packageMatch.Groups['version'].Value)"
}
$sdkMatch = [regex]::Match($badging, "sdkVersion:'(?<sdk>\d+)'")
Add-Check 'minSdk（冻结 24）' ($sdkMatch.Success -and [int]$sdkMatch.Groups['sdk'].Value -ge 24) $(if ($sdkMatch.Success) { "minSdk=$($sdkMatch.Groups['sdk'].Value)" } else { '解析失败' })
$targetMatch = [regex]::Match($badging, "targetSdkVersion:'(?<sdk>\d+)'")
Add-Check 'targetSdk' ($targetMatch.Success) $(if ($targetMatch.Success) { "targetSdk=$($targetMatch.Groups['sdk'].Value)" } else { '解析失败' })

# ---------------- 应用名 / 图标 / 启动 Activity ----------------
$labelMatch = [regex]::Match($badging, "application-label:'(?<label>[^']*)'")
Add-Check '应用名' ($labelMatch.Success -and $labelMatch.Groups['label'].Value -eq $ExpectAppLabel) $(if ($labelMatch.Success) { $labelMatch.Groups['label'].Value } else { '解析失败' })
$iconMatch = [regex]::Match($badging, "application-icon-\d+:'(?<icon>[^']*)'")
Add-Check '应用图标资源' $iconMatch.Success $(if ($iconMatch.Success) { $iconMatch.Groups['icon'].Value } else { '未找到图标' })
$activityMatch = [regex]::Match($badging, "launchable-activity: name='(?<activity>[^']*)'")
Add-Check '启动 Activity' ($activityMatch.Success -and $activityMatch.Groups['activity'].Value -eq "$ExpectApplicationId.MainActivity") $(if ($activityMatch.Success) { $activityMatch.Groups['activity'].Value } else { '解析失败' })

# ---------------- 权限 ----------------
$permissions = [regex]::Matches($badging, "uses-permission: name='(?<perm>[^']*)'") | ForEach-Object { $_.Groups['perm'].Value }
Add-Check 'INTERNET 权限' ($permissions -contains 'android.permission.INTERNET') '云端同步必需'
Add-Check 'ACCESS_NETWORK_STATE 权限' ($permissions -contains 'android.permission.ACCESS_NETWORK_STATE') '区分离线与服务端错误'
$storagePermissions = $permissions | Where-Object { $_ -match 'READ_EXTERNAL_STORAGE|WRITE_EXTERNAL_STORAGE|MANAGE_EXTERNAL_STORAGE|READ_MEDIA_' }
Add-Check '不申请存储权限（SAF 免权限）' (-not $storagePermissions) $(if ($storagePermissions) { $storagePermissions -join ', ' } else { '无存储类权限' })

# ---------------- 备份 / 明文 / 调试开关 ----------------
Add-Check 'Manifest: allowBackup=false（不进入系统云备份）' ($manifestTree -match 'android:allowBackup=\
Add-Check 'Manifest: fullBackupContent' ($manifestTree -match 'fullBackupContent') 'Android 6-11 备份规则'
Add-Check 'Manifest: dataExtractionRules' ($manifestTree -match 'dataExtractionRules') 'Android 12+ 备份/换机规则'
Add-Check 'Manifest: usesCleartextTraffic=false' ($manifestTree -match 'usesCleartextTraffic') '正式包禁止明文流量'
$hasNetworkConfig = $manifestTree -match 'networkSecurityConfig'
if ($Mode -eq 'debug') {
    Add-Check 'Manifest: debug 明文白名单' $hasNetworkConfig '仅 debug：允许 localhost/127.0.0.1/10.0.2.2'
} else {
    Add-Check 'Manifest: release 无明文白名单' (-not $hasNetworkConfig) $(if ($hasNetworkConfig) { 'release 包不应包含 networkSecurityConfig' } else { '未包含' })
}
$hasDebuggable = $manifestTree -match 'debuggable'
if ($Mode -eq 'debug') {
    Add-Check 'Manifest: debuggable' $hasDebuggable 'debug 包可调试'
} else {
    Add-Check 'Manifest: release 不可调试' (-not $hasDebuggable) $(if ($hasDebuggable) { 'release 包仍带 debuggable' } else { '未包含' })
}
Add-Check 'Manifest: enableOnBackInvokedCallback' ($manifestTree -match 'enableOnBackInvokedCallback') 'Android 13+ 预测性返回'

# ---------------- 原生库 / 插件类 ----------------
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($Apk)
try {
    $entries = $zip.Entries
    $nativeNames = $entries | Where-Object { $_.FullName -like 'lib/*/*.so' } | ForEach-Object { $_.FullName }
    $abis = $nativeNames | ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique
    Add-Check '原生库 ABI' ($abis.Count -gt 0) ($abis -join ', ')
    Add-Check 'SQLite 随包库 libsqlite3.so' ([bool]($nativeNames | Where-Object { $_ -like '*/libsqlite3.so' })) '避免旧系统 SQLite 缺 VACUUM INTO'
    Add-Check 'Flutter 引擎 libflutter.so' ([bool]($nativeNames | Where-Object { $_ -like '*/libflutter.so' })) ''

    $dexText = ''
    foreach ($entry in ($entries | Where-Object { $_.FullName -match '^classes\d*\.dex$' })) {
        $stream = $entry.Open()
        try {
            $memory = New-Object System.IO.MemoryStream
            $stream.CopyTo($memory)
            $dexText += [System.Text.Encoding]::ASCII.GetString($memory.ToArray())
            $memory.Dispose()
        }
        finally {
            $stream.Dispose()
        }
    }
    Add-Check '安全存储原生类' ($dexText -match 'SecureStorePlugin') 'com.jihuatai.planner/secure_store'
    Add-Check '文件选择原生类' ($dexText -match 'StoragePlugin') 'com.jihuatai.planner/storage'
    Add-Check '内存压力原生类' ($dexText -match 'MainActivity') ''
}
finally {
    $zip.Dispose()
}

# ---------------- 16KB 页对齐（Android 15+） ----------------
$readelfCandidates = Get-ChildItem (Join-Path $env:ANDROID_HOME 'ndk') -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending
$readelf = $null
foreach ($candidate in $readelfCandidates) {
    $path = Join-Path $candidate.FullName 'toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe'
    if (Test-Path $path) { $readelf = $path; break }
}
if (-not $readelf) {
    Add-Check '16KB 页对齐（arm64 .so）' $false 'NDK llvm-readelf 不可用，无法检查' -Skip
}
else {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("jihuatai_apkcheck_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Apk)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -match '^lib/arm64-v8a/libsqlite3\.so$' } | Select-Object -First 1
            if (-not $entry) {
                Add-Check '16KB 页对齐（arm64 .so）' $false 'APK 中没有 arm64-v8a/libsqlite3.so' -Skip
            }
            else {
                $target = Join-Path $tempDir 'libsqlite3.so'
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                $elfHeader = & $readelf -l $target 2>&1 | Out-String
                $loadLines = ($elfHeader -split "`n") | Where-Object { $_ -match '^\s*LOAD' }
                $aligned = $true
                foreach ($line in $loadLines) {
                    if ($line -match '0x([0-9a-fA-F]+)$') {
                        if ([Convert]::ToInt64($matches[1], 16) -lt 0x4000) { $aligned = $false }
                    }
                }
                Add-Check '16KB 页对齐（arm64 .so LOAD Align≥0x4000）' ($loadLines.Count -gt 0 -and $aligned) ("LOAD 段数=$($loadLines.Count)")
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    finally {
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
}

# ---------------- 签名 ----------------
$apksigner = Get-ApkSignerPath
if (-not $apksigner) {
    Add-Check '签名者' $false 'apksigner 不可用' -Skip
}
else {
    $signatureOutput = & $apksigner verify --print-certs $Apk 2>&1 | Out-String
    $dnMatch = [regex]::Match($signatureOutput, 'certificate DN:\s*(?<dn>.+)')
    $shaMatch = [regex]::Match($signatureOutput, 'SHA-256 digest:\s*(?<sha>[0-9a-fA-F]+)')
    $isDebugSigner = $signatureOutput -match 'CN=Android Debug'
    $dn = if ($dnMatch.Success) { $dnMatch.Groups['dn'].Value.Trim() } else { '未知' }
    $sha = if ($shaMatch.Success) { $shaMatch.Groups['sha'].Value } else { '未知' }
    if ($Mode -eq 'debug' -or -not $RequireReleaseSignature) {
        Add-Check '签名者' $true ("{0}（SHA-256 {1}）" -f $dn, $sha.Substring(0, [Math]::Min(16, $sha.Length)))
    }
    else {
        Add-Check 'release 使用正式签名' (-not $isDebugSigner) ("当前签名者：$dn")
    }
}

# ---------------- 汇总 ----------------
$failed = $script:Results | Where-Object { $_.State -eq 'FAIL' }
$passed = ($script:Results | Where-Object { $_.State -eq 'PASS' }).Count
$skipped = ($script:Results | Where-Object { $_.State -eq 'SKIP' }).Count
Write-Host ("`n结果：PASS {0} / FAIL {1} / SKIP {2}" -f $passed, $failed.Count, $skipped) -ForegroundColor $(if ($failed.Count -gt 0) { 'Red' } else { 'Green' })
if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Host ("  FAIL: {0} {1}" -f $_.Name, $_.Detail) -ForegroundColor Red }
    exit 1
}
Write-Host 'APK 检查全部通过。' -ForegroundColor Green
exit 0
