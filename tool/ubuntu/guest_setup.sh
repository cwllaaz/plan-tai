#!/usr/bin/env bash
# 计划台 Ubuntu 目标机环境准备（幂等，可重复执行）
#
# 用途：在一台干净的 Ubuntu 22.04/24.04 上准备「计划台」Linux 构建 + 运行 + 验收
# 所需的全部依赖，并安装 Flutter SDK（版本与 Windows 稳定版一致）。
#
# 用法（需要有 sudo 权限）：
#   sudo bash tool/ubuntu/guest_setup.sh
#
# 可覆盖的环境变量：
#   APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu
#   FLUTTER_VERSION=3.50.0
#   FLUTTER_DIR=/opt/flutter
#   FLUTTER_MIRROR=https://storage.flutter-io.cn
#   PUB_MIRROR=https://pub.flutter-io.cn
#
# 注意：
# - 只安装“实际缺失”的包（apt-get install 自带已安装跳过），不升级系统；
# - 不改 Windows 侧任何东西；不访问生产服务器；不触碰真实用户数据。
set -euo pipefail

APT_MIRROR="${APT_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu}"
FLUTTER_VERSION="${FLUTTER_VERSION:-3.50.0}"
FLUTTER_DIR="${FLUTTER_DIR:-/opt/flutter}"
FLUTTER_MIRROR="${FLUTTER_MIRROR:-https://storage.flutter-io.cn}"
PUB_MIRROR="${PUB_MIRROR:-https://pub.flutter-io.cn}"

log() { printf '\n==> %s\n' "$*"; }
need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
  fi
}

need_root

log "1/6 关闭自动更新定时器（避免构建期间抢占 CPU/网络）"
systemctl disable --now unattended-upgrades 2>/dev/null || true
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

log "2/6 配置 apt 镜像：$APT_MIRROR"
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sed -i -E "s#https?://[A-Za-z0-9._-]+/ubuntu#${APT_MIRROR}#g" /etc/apt/sources.list.d/ubuntu.sources
fi
if [ -f /etc/apt/sources.list ]; then
  sed -i -E "s#https?://[A-Za-z0-9._-]+/ubuntu#${APT_MIRROR}#g" /etc/apt/sources.list
fi

log "3/6 安装构建/运行/验收依赖（只装缺的）"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev libx11-dev libxi-dev libstdc++-12-dev liblzma-dev \
  libsqlite3-0 libsqlite3-dev sqlite3 \
  xvfb imagemagick xdotool \
  fonts-noto-cjk \
  libsecret-1-0 libsecret-tools gnome-keyring dbus-x11 \
  curl ca-certificates xz-utils git unzip file \
  libgbm1 libgl1-mesa-dri

log "4/6 安装 Flutter $FLUTTER_VERSION 到 $FLUTTER_DIR"
if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  TARBALL="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  curl -fL --retry 3 --retry-delay 3 -o "/tmp/$TARBALL" \
    "$FLUTTER_MIRROR/flutter_infra_release/releases/stable/linux/$TARBALL"
  tar -xf "/tmp/$TARBALL" -C "$(dirname "$FLUTTER_DIR")"
  rm -f "/tmp/$TARBALL"
fi
cat > /etc/profile.d/jihuatai-flutter.sh <<EOF
export PATH="$FLUTTER_DIR/bin:\$PATH"
export PUB_HOSTED_URL="$PUB_MIRROR"
export FLUTTER_STORAGE_BASE_URL="$FLUTTER_MIRROR"
export PUB_CACHE="\$HOME/.pub-cache"
EOF
chmod 0644 /etc/profile.d/jihuatai-flutter.sh

export PATH="$FLUTTER_DIR/bin:$PATH"
export PUB_HOSTED_URL="$PUB_MIRROR"
export FLUTTER_STORAGE_BASE_URL="$FLUTTER_MIRROR"

log "5/6 预下载 Linux 引擎产物（precache）"
flutter config --no-analytics >/dev/null 2>&1 || true
flutter --version
flutter precache --linux

log "6/6 环境就绪"
echo "Flutter : $("$FLUTTER_DIR/bin/flutter" --version | head -n 1)"
echo "clang   : $(clang --version | head -n 1)"
echo "cmake   : $(cmake --version | head -n 1)"
echo "ninja   : $(ninja --version)"
echo "gtk     : $(pkg-config --modversion gtk+-3.0)"
echo "x11/xi  : $(pkg-config --modversion x11) / $(pkg-config --modversion xi)"
echo "sqlite  : $(sqlite3 --version | cut -d' ' -f1) / lib: $(pkg-config --modversion sqlite3 2>/dev/null || echo n/a)"
echo
echo "提示：新开 shell 或执行 'source /etc/profile.d/jihuatai-flutter.sh' 后再用 flutter。"
