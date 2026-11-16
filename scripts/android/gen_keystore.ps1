# 生成正式 release 签名（keystore + key.properties）
#
#   powershell -File scripts/android/gen_keystore.ps1
#   powershell -File scripts/android/gen_keystore.ps1 -OutDir D:\keys\jihuatai -Alias jihuatai
#
# 产物（全部在仓库外）：
#   <OutDir>\<Alias>-release.jks     私钥文件（PKCS12）
#   <OutDir>\key.properties          密码与路径（绝对路径）
# 并复制一份 key.properties 到 android/key.properties（已被 .gitignore 忽略）。
#
# 安全约定：
# - keystore 与密码**绝不入库**；本脚本会拒绝把产物写进仓库目录。
# - 密码随机生成（字母数字，避免 properties 转义问题）；请把 OutDir 整体离线备份两份。
# - 丢失 keystore = 永远无法覆盖升级已发布的应用（只能换包名重新发一个新应用）。

[CmdletBinding()]
param(
    # 必填：建议放在仓库之外的独立目录，并离线备份两份。
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [string]$Alias = 'jihuatai',
    [string]$Dname = 'CN=JihuaTai, OU=Android Release, O=JihuaTai, L=Shanghai, ST=Shanghai, C=CN',
    [int]$ValidityDays = 36500,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
$repoFull = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\') + '\'
if ($OutDir.StartsWith($repoFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "拒绝在仓库内生成签名密钥：$OutDir" -ForegroundColor Red
    Write-Host "签名文件一旦提交到 Git 就等于泄露，任何拿到仓库的人都能给应用签名。" -ForegroundColor Red
    exit 1
}

function New-RandomPassword {
    param([int]$Length = 24)
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = New-Object byte[] $Length
    # RandomNumberGenerator.Fill 只有 .NET Core 有；这里用 Windows PowerShell 5.1
    # 与 PowerShell 7 都支持的 Create().GetBytes()。
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }
    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $bytes) {
        [void]$builder.Append($chars[$byte % $chars.Length])
    }
    return $builder.ToString()
}

$keytool = Join-Path $env:JAVA_HOME 'bin\keytool.exe'
if (-not (Test-Path $keytool)) {
    Write-Host "找不到 keytool：$keytool" -ForegroundColor Red
    Write-Host "请确认 JAVA_HOME（当前为 $env:JAVA_HOME）。" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}
$keystorePath = Join-Path $OutDir "$Alias-release.jks"
if ((Test-Path $keystorePath) -and -not $Force) {
    Write-Host "已存在 keystore：$keystorePath" -ForegroundColor Red
    Write-Host "出于安全考虑不会覆盖。确需重新生成请显式传 -Force（旧包将无法覆盖升级）。" -ForegroundColor Red
    exit 1
}

$password = New-RandomPassword
Write-Host "`n>>> 生成 keystore：$keystorePath" -ForegroundColor Cyan
& $keytool -genkeypair -v `
    -keystore $keystorePath `
    -alias $Alias `
    -keyalg RSA `
    -keysize 4096 `
    -validity $ValidityDays `
    -storetype PKCS12 `
    -storepass $password `
    -keypass $password `
    -dname $Dname
if ($LASTEXITCODE -ne 0) {
    Write-Host "keytool 生成失败（exit $LASTEXITCODE）。" -ForegroundColor Red
    exit $LASTEXITCODE
}

# Java properties 里反斜杠是转义符：统一用正斜杠写路径。
# 注释只用 ASCII：Properties.load(InputStream) 按 ISO-8859-1 解码，中文注释会变乱码。
$propertiesStoreFile = $keystorePath -replace '\\', '/'
$properties = @(
    '# JihuaTai Android release signing (auto generated)'
    "# generated at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    '# NEVER commit this file to git.'
    "storePassword=$password"
    "keyPassword=$password"
    "keyAlias=$Alias"
    "storeFile=$propertiesStoreFile"
) -join "`r`n"

# 必须无 BOM：Gradle 用 Properties.load(InputStream) 按 ISO-8859-1 读取，
# BOM 会被当成第一个 key 的一部分，导致 storePassword 读不到。
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$propertiesPath = Join-Path $OutDir 'key.properties'
[System.IO.File]::WriteAllText($propertiesPath, $properties, $utf8NoBom)
Write-Host "`n已写入：$propertiesPath" -ForegroundColor Green

$repoProperties = Join-Path $repoRoot 'android\key.properties'
[System.IO.File]::WriteAllText($repoProperties, $properties, $utf8NoBom)
Write-Host "已复制到：$repoProperties" -ForegroundColor Green

$ignored = (& git -C $repoRoot check-ignore 'android/key.properties' 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $ignored) {
    Write-Host "警告：android/key.properties 未被 .gitignore 忽略，请立即检查仓库配置！" -ForegroundColor Red
}

Write-Host "`n===== 证书指纹（请记录并离线保存）=====" -ForegroundColor Cyan
& $keytool -list -v -keystore $keystorePath -alias $Alias -storepass $password |
    Select-String -Pattern 'SHA1:|SHA256:|有效期|Valid'

Write-Host @"

================ 必须做的事 ================
1. 把整个目录离线备份两份（U 盘 + 加密压缩包）：
     $OutDir
2. 记录上面的 SHA256 指纹；它是「同一个应用身份」的唯一凭证。
3. 丢失 keystore 或密码 = 以后**无法覆盖升级**已发布的应用，
   只能换 applicationId 重新发布一个新应用（老用户数据不会自动迁移）。
4. android/key.properties 与 *.jks 已被 .gitignore 忽略：
   请用 `git status` 确认它们没有出现在待提交列表里。
5. 下一版发布前，把 pubspec.yaml 的 version 构建号递增，例如 2.0.0+5 -> 2.0.0+6（versionCode 必须单调递增）。
============================================
"@ -ForegroundColor Yellow

exit 0
