#!/usr/bin/env bash
# 计划台 Ubuntu .deb 打包脚本（最小、可维护，不引入额外打包框架）
#
# 前置：在 Ubuntu 上执行过
#   flutter build linux --release
# 产物：dist/jihuatai_<version>_amd64.deb
#
# 用法：
#   bash packaging/linux/build_deb.sh
#
# 可选环境变量：
#   VERSION      覆盖 deb 版本（默认取 pubspec.yaml 的 version，如 2.0.0+5）
#   BUNDLE_DIR   覆盖 release bundle 目录（默认 build/linux/x64/release/bundle）
#   DIST_DIR     输出目录（默认 dist/）
#
# 安装布局（遵循 Linux 规范）：
#   /opt/jihuatai/                       完整 Flutter Release bundle（不是单文件！）
#   /usr/bin/jihuatai                    -> /opt/jihuatai/jihuatai
#   /usr/share/applications/com.jihuatai.jihuatai.desktop
#   /usr/share/icons/hicolor/<size>/apps/jihuatai.png
# 用户数据不在包内：默认放在 ~/.local/share/计划台/data/（卸载不会删除）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PKG_NAME="jihuatai"
APP_ID="com.jihuatai.jihuatai"
ARCH="amd64"

if [ -z "${VERSION:-}" ]; then
  VERSION="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n1 | tr -d '[:space:]')"
fi
if [ -z "$VERSION" ]; then
  echo "无法从 pubspec.yaml 读取版本号" >&2
  exit 1
fi

BUNDLE_DIR="${BUNDLE_DIR:-$ROOT/build/linux/x64/release/bundle}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
STAGE="$ROOT/build/deb/${PKG_NAME}_${VERSION}_${ARCH}"
DEB="$DIST_DIR/${PKG_NAME}_${VERSION}_${ARCH}.deb"

if [ ! -x "$BUNDLE_DIR/$PKG_NAME" ]; then
  echo "缺少 Release bundle：$BUNDLE_DIR/$PKG_NAME" >&2
  echo "请先执行：flutter build linux --release" >&2
  exit 1
fi

echo "==> 清理 staging：$STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" \
  "$STAGE/opt/$PKG_NAME" \
  "$STAGE/usr/bin" \
  "$STAGE/usr/share/applications" \
  "$STAGE/usr/share/doc/$PKG_NAME"

echo "==> 复制完整 Flutter Release bundle（含 data/lib）"
cp -a "$BUNDLE_DIR/." "$STAGE/opt/$PKG_NAME/"
chmod 0755 "$STAGE/opt/$PKG_NAME/$PKG_NAME"

echo "==> 启动器、桌面入口、图标"
ln -s "/opt/$PKG_NAME/$PKG_NAME" "$STAGE/usr/bin/$PKG_NAME"
install -m0644 "packaging/linux/jihuatai.desktop" \
  "$STAGE/usr/share/applications/${APP_ID}.desktop"
for size in 16 32 48 64 128 256; do
  install -Dm0644 "packaging/linux/icons/hicolor/${size}x${size}/apps/jihuatai.png" \
    "$STAGE/usr/share/icons/hicolor/${size}x${size}/apps/jihuatai.png"
done

cat >"$STAGE/usr/share/doc/$PKG_NAME/copyright" <<EOF
计划台（$APP_ID）
日历式项目与时间管理系统 —— Ubuntu/Linux 桌面版
版本：$VERSION
说明：Flutter Linux Release bundle 安装于 /opt/$PKG_NAME；
用户数据默认位于 ~/.local/share/计划台/data/，不随包安装/卸载删除。
EOF

echo "==> DEBIAN/control"
INSTALL_SIZE="$(du -sk "$STAGE" | cut -f1)"
cat >"$STAGE/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION
Section: office
Priority: optional
Architecture: $ARCH
Installed-Size: $INSTALL_SIZE
Maintainer: PlanTai <plan-tai@users.noreply.github.com>
Homepage: https://github.com/cwllaaz/plan-tai
Description: 计划台 - 日历式项目与时间管理系统
 Flutter 桌面应用：月历主页、跨日期项目阶段、每日任务面板、
 本地 SQLite 数据、本地备份恢复，以及可选的 PocketBase 云端双向同步。
Depends: libc6 (>= 2.35), libgtk-3-0, libsqlite3-0, libsecret-1-0, libx11-6, libxi6, libstdc++6, libgl1, libegl1, libglx0
Recommends: fonts-noto-cjk, libsecret-tools, gnome-keyring | kwallet
EOF

cat >"$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true
fi
exit 0
EOF
cat >"$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true
fi
# 注意：这里只清理系统级文件；用户数据在 ~/.local/share/计划台，绝不删除。
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

echo "==> 构建 deb"
mkdir -p "$DIST_DIR"
rm -f "$DEB"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB"

echo
echo "==> 完成：$DEB"
ls -lh "$DEB"
echo "--- control ---"
dpkg-deb -I "$DEB" | sed -n '1,20p'
echo "--- 包内容（前 30 行）---"
dpkg-deb -c "$DEB" | sed -n '1,30p'
sha256sum "$DEB"
