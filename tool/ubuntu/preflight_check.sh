#!/usr/bin/env bash
# 计划台 Ubuntu 移植 · Linux 构建环境体检（只读，不做任何安装/修改）
#
# 用法（在目标 Ubuntu 主机、工程根目录执行）：
#   bash tool/ubuntu/preflight_check.sh
#
# 退出码：
#   0 = 关键依赖齐全，可以尝试 flutter build linux
#   1 = 存在缺失项（脚本会列出缺什么、对应 apt 包名）
#
# 说明：本脚本是阶段 0 产出的“可在 Ubuntu 上复跑的审计工具”。
# 本机（Windows 11）上没有 Ubuntu 主机，因此该脚本只做过 bash 语法检查，
# 未在真实 Ubuntu 上执行过；阶段 1 第一件事就是在 Ubuntu 上跑它。

set -u

PASS=0
FAIL=0
WARN=0

ok()   { printf '  [ OK ] %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '  [WARN] %s\n' "$*"; WARN=$((WARN + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }
pkg_exists() { have pkg-config && pkg-config --exists "$1" >/dev/null 2>&1; }

section() { printf '\n== %s ==\n' "$*"; }

echo "计划台 Linux 构建环境体检（只读）"
echo "时间：$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

section "1. 系统与架构"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  printf '  发行版：%s %s（%s）\n' "${NAME:-unknown}" "${VERSION_ID:-unknown}" "${PRETTY_NAME:-}"
else
  warn "读不到 /etc/os-release，无法确认发行版"
fi
printf '  内核：%s\n' "$(uname -sr)"
printf '  架构：%s\n' "$(uname -m)"
case "$(uname -m)" in
  x86_64 | aarch64) ok "CPU 架构 $(uname -m) 在 Flutter Linux 官方支持范围内" ;;
  *) warn "CPU 架构 $(uname -m) 可能不在 Flutter 官方 Linux 支持范围内" ;;
esac

section "2. Flutter / Dart"
if have flutter; then
  FLUTTER_BIN=$(command -v flutter)
  ok "flutter 在 PATH：$FLUTTER_BIN"
  flutter --version 2>/dev/null | sed 's/^/  /'
  if flutter config --list 2>/dev/null | grep -qi 'enable-linux-desktop'; then
    ok "enable-linux-desktop 配置项存在"
  else
    warn "未看到 enable-linux-desktop 配置项（较新 SDK 默认开启，请核对 flutter config --list）"
  fi
else
  bad "flutter 不在 PATH（阶段 1 需要 Linux 版 Flutter SDK，例如 /opt/flutter）"
fi

section "3. Flutter 要求的 Linux 工具链"
# 依据：flutter_tools/lib/src/linux/linux_doctor.dart:127-139
#   clang++ >= 3.4、cmake >= 3.10、ninja >= 1.8、pkg-config >= 0.29，
#   以及 pkg-config 能查到 gtk+-3.0 / glib-2.0 / gio-2.0。
for bin in clang clang++ cmake ninja pkg-config; do
  if have "$bin"; then
    ok "$bin：$("$bin" --version 2>/dev/null | head -n 1)"
  else
    case "$bin" in
      clang | clang++) bad "缺少 $bin（apt: clang）" ;;
      cmake)           bad "缺少 cmake（apt: cmake）" ;;
      ninja)           bad "缺少 ninja（apt: ninja-build）" ;;
      pkg-config)      bad "缺少 pkg-config（apt: pkg-config）" ;;
    esac
  fi
done

for lib in gtk+-3.0 glib-2.0 gio-2.0; do
  if pkg_exists "$lib"; then
    ok "pkg-config 找到 $lib：$(pkg-config --modversion "$lib")"
  else
    bad "pkg-config 找不到 $lib（apt: libgtk-3-dev）"
  fi
done

section "4. 插件原生构建依赖（本工程实测）"
# window_manager 0.7.0 -> nativeapi -> cnativeapi 的 hook/build.dart 在 Linux 上
# 用 pkg-config 取 gtk+-3.0 x11 xi 的编译/链接参数
# （<PUB_CACHE>\...\cnativeapi-0.6.1\hook\build.dart:77-89,143）。
for lib in x11 xi; do
  if pkg_exists "$lib"; then
    ok "pkg-config 找到 $lib：$(pkg-config --modversion "$lib")"
  else
    bad "pkg-config 找不到 $lib（apt: libx11-dev libxi-dev）"
  fi
done
if have clang++; then
  ok "cnativeapi 用 clang++ 从源码编译，已具备编译器"
else
  bad "cnativeapi 需要 clang++ 从源码编译 C++17 库"
fi

section "5. SQLite 运行库"
# pubspec.yaml 的 hooks.user_defines.sqlite3 在 Linux 上仍是 source: sqlite3，
# 即构建期从 GitHub Releases 下载预编译 .so 并做 sha256 校验；
# 只有把默认 source 改成 system 时才依赖系统 libsqlite3.so。
SQLITE_SO=$( (ldconfig -p 2>/dev/null || true) | grep -m1 'libsqlite3\.so' || true)
if [ -n "$SQLITE_SO" ]; then
  ok "系统存在 libsqlite3：$SQLITE_SO"
  if have sqlite3; then
    ok "sqlite3 CLI 版本：$(sqlite3 --version | cut -d' ' -f1)"
  else
    warn "没有 sqlite3 CLI（非必需，排查数据问题时建议装 sqlite3）"
  fi
else
  warn "系统未找到 libsqlite3.so（当前配置下构建期会下载自带 .so，运行库仍需 libsqlite3-0 才可走 system 方案）"
fi

section "6. 密钥环 / 令牌存储（云同步需要）"
# 现状：nativeapi 的 SecureStorage 在 Linux 是空实现
# （cnativeapi-0.6.1/cxx_impl/src/platform/linux/secure_storage_linux.cpp:5-105）。
# 契约要求：有 keyring 才存令牌，无 keyring 必须提示安装、不得退化为明文
# （docs/sync/SECURITY.md）。
if pkg_exists libsecret-1; then
  ok "libsecret-1 开发库存在：$(pkg-config --modversion libsecret-1)"
else
  warn "缺少 libsecret-1 开发库（阶段 1 实现 Linux 令牌存储时 apt: libsecret-1-dev）"
fi
if have secret-tool; then
  ok "secret-tool 存在（libsecret-tools）"
else
  warn "缺少 secret-tool（可选，用于人工排查 keyring，apt: libsecret-tools）"
fi
if have gnome-keyring-daemon || have kwalletd5 || have kwalletd6; then
  ok "检测到密钥环服务（gnome-keyring 或 KWallet）"
else
  warn "未检测到 gnome-keyring/KWallet 服务，令牌存储不可用"
fi
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  ok "存在 D-Bus 会话总线（Secret Service 依赖它）"
else
  warn "无 DBUS_SESSION_BUS_ADDRESS，Secret Service 不可用"
fi

section "7. 图形会话与显示协议"
printf '  XDG_SESSION_TYPE=%s\n' "${XDG_SESSION_TYPE:-<空>}"
printf '  XDG_CURRENT_DESKTOP=%s\n' "${XDG_CURRENT_DESKTOP:-<空>}"
printf '  DISPLAY=%s\n' "${DISPLAY:-<空>}"
printf '  WAYLAND_DISPLAY=%s\n' "${WAYLAND_DISPLAY:-<空>}"
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
  warn "当前是 Wayland 会话：window_manager 走 X11/Xi 后端，需要 XWayland 才能生效"
elif [ -n "${DISPLAY:-}" ]; then
  ok "当前是 X11（或 XWayland）会话"
else
  warn "没有图形会话：flutter build linux 可以跑，flutter run / 真机验证需要显示器或 xvfb"
fi
if have xvfb-run; then
  ok "xvfb-run 存在（可在无显示器环境跑 GUI 冒烟）"
else
  warn "缺少 xvfb-run（无显示器做 GUI 冒烟时需要，apt: xvfb）"
fi

section "8. 网络（构建期下载）"
check_url() {
  if have curl; then
    if curl -fsS --max-time 10 -o /dev/null "$1"; then ok "可访问 $1"; else bad "无法访问 $1"; fi
  else
    warn "缺少 curl，跳过 $1"
  fi
}
# 说明：sqlite3 包在 Linux 构建期会访问 GitHub Releases；
# Flutter 引擎/packages 走镜像（见 scripts/env.ps1 的对应 Linux 版）。
check_url "https://pub.flutter-io.cn"
check_url "https://storage.flutter-io.cn"
if have curl; then
  if curl -fsS --max-time 10 -o /dev/null "https://github.com"; then
    ok "可访问 https://github.com（native assets 下载需要）"
  else
    warn "无法访问 https://github.com：sqlite3 预编译 .so / native assets 可能下载失败，需配置镜像或改用 source: system"
  fi
fi

section "9. 磁盘空间"
DF_TARGET=$(df -Pk . 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "${DF_TARGET:-}" ]; then
  AVAIL_GB=$((DF_TARGET / 1024 / 1024))
  printf '  工程所在分区可用：%s GB\n' "$AVAIL_GB"
  if [ "$AVAIL_GB" -ge 8 ]; then ok "磁盘空间充足（Linux 构建 + Flutter SDK 建议 >= 8GB）"
  else bad "磁盘空间不足（建议 >= 8GB）"; fi
else
  warn "无法读取磁盘可用空间"
fi

section "10. 结果"
printf '  OK=%d  WARN=%d  FAIL=%d\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  cat <<'EOF'

  关键依赖缺失。最小安装命令（Ubuntu 22.04/24.04，只装缺的包）：
    sudo apt-get update
    sudo apt-get install -y clang cmake ninja-build pkg-config \
        libgtk-3-dev libx11-dev libxi-dev liblzma-dev libstdc++-12-dev
  仅当需要“系统 SQLite”方案时再加：libsqlite3-dev libsqlite3-0
  仅当开始实现 Linux 令牌存储时再加：libsecret-1-dev gnome-keyring
  无显示器做 GUI 冒烟时再加：xvfb
EOF
  exit 1
fi
ok "关键依赖齐全，可执行 flutter build linux --release"
exit 0
