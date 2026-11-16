# 计划台开发环境（在终端里点源执行）
#   . .\scripts\env.ps1
#
# 约定：不写死任何本机路径，全部通过环境变量 / 自动探测得到。
#   FLUTTER_SDK   可选，Flutter SDK 根目录（默认从 PATH 里的 flutter 反推）
#   PUB_CACHE     可选，pub 缓存目录（默认用 Flutter 自身默认值）
#   PUB_HOSTED_URL / FLUTTER_STORAGE_BASE_URL  可选，网络受限时可指到镜像

$ErrorActionPreference = 'Stop'

function Resolve-FlutterSdk {
    if ($env:FLUTTER_SDK -and (Test-Path (Join-Path $env:FLUTTER_SDK 'bin\flutter.bat'))) {
        return $env:FLUTTER_SDK
    }
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) {
        # <sdk>\bin\flutter.bat -> <sdk>
        return (Split-Path -Parent (Split-Path -Parent $cmd.Source))
    }
    return $null
}

$flutterSdk = Resolve-FlutterSdk
if (-not $flutterSdk) {
    Write-Host '未找到 Flutter SDK：请设置环境变量 FLUTTER_SDK，或把 Flutter 加入 PATH。' -ForegroundColor Red
    return
}

$env:FLUTTER_SDK = $flutterSdk
$env:Path = "$flutterSdk\bin;" + $env:Path
if (-not $env:PUB_CACHE -and (Test-Path (Join-Path $env:USERPROFILE '.pub-cache'))) {
    $env:PUB_CACHE = Join-Path $env:USERPROFILE '.pub-cache'
}

Write-Host "Flutter 环境已就绪：$flutterSdk" -ForegroundColor Green
if ($env:PUB_CACHE) { Write-Host "PUB_CACHE=$env:PUB_CACHE" }
if ($env:PUB_HOSTED_URL) { Write-Host "PUB_HOSTED_URL=$env:PUB_HOSTED_URL" }
Write-Host '提示：构建目录请使用纯 ASCII 路径（Android 的 AGP 会拒绝非 ASCII 工程路径）。' -ForegroundColor DarkGray
