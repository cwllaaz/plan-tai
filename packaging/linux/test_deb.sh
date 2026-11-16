#!/usr/bin/env bash
# 计划台 .deb 安装/启动/升级/卸载验收（在 Ubuntu guest 内执行）
# 用法：bash test_deb.sh <deb-path> [<deb-v2-path>]
# 说明：
#   - 使用独立测试数据目录 JIHUATAI_DATA_DIR=/home/ubuntu/jht-release-data，
#     不碰任何真实用户数据；
#   - 升级用例：第 2 个参数是版本号更高的同内容 deb（用于验证“升级不丢数据”）；
#   - 所有系统级操作都经 sudo，结束后卸载包（保留测试数据以证明卸载不删个人数据）。
set -uo pipefail
DEB="${1:?usage: test_deb.sh <deb> [<deb-v2>]}"
DEB2="${2:-}"
DATA=/home/ubuntu/jht-release-data
SHOT=/home/ubuntu/jht-shots
LOG="$SHOT/deb_test.log"
mkdir -p "$SHOT"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

PASS=0; FAIL=0
ok(){ echo "[ OK ] $*"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
step(){ echo; echo "== $* =="; }

cleanup_app(){
  pkill -x jihuatai >/dev/null 2>&1 || true
  pkill -f 'Xvfb :99' >/dev/null 2>&1 || true
  pkill -x openbox >/dev/null 2>&1 || true
  sleep 1
}

step "0. 环境清理"
cleanup_app
rm -rf "$DATA"
mkdir -p "$DATA"

step "1. 安装 deb：$DEB"
sudo dpkg -i "$DEB" || sudo apt-get install -f -y
if dpkg -s jihuatai >/dev/null 2>&1; then ok "包已安装"; else bad "包未安装"; fi
echo "--- 包内容 ---"
dpkg -L jihuatai | head -20

step "2. 包内容检查"
[ -x /opt/jihuatai/jihuatai ] && ok "/opt/jihuatai/jihuatai 可执行" || bad "缺少可执行文件"
[ -d /opt/jihuatai/data/flutter_assets ] && ok "Flutter 资源 data/flutter_assets 存在" || bad "缺少 Flutter 资源"
ls /opt/jihuatai/lib/*.so >/dev/null 2>&1 && ok "随包动态库 lib/*.so 存在" || bad "缺少动态库"
[ -f /usr/share/applications/com.jihuatai.jihuatai.desktop ] && ok ".desktop 菜单入口存在" || bad "缺少 .desktop"
[ -f /usr/share/icons/hicolor/256x256/apps/jihuatai.png ] && ok "图标存在（hicolor 256）" || bad "缺少图标"
[ -L /usr/bin/jihuatai ] && ok "/usr/bin/jihuatai 启动器存在" || bad "缺少 /usr/bin 启动器"
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate /usr/share/applications/com.jihuatai.jihuatai.desktop && ok "desktop-file-validate 通过" || bad "desktop 校验失败"
fi
MISSING=$(ldd /opt/jihuatai/jihuatai 2>/dev/null | grep 'not found' || true)
if [ -z "$MISSING" ]; then ok "主程序动态库依赖齐全（ldd 无 not found）"; else bad "缺少动态库：$MISSING"; fi
ldd /opt/jihuatai/jihuatai 2>/dev/null | awk '{print $3}' | grep -E 'lib(sqlite3|secret|gtk-3|x11|xi)' | sort -u

step "3. 启动验收（Xvfb + openbox，模拟桌面双击图标）"
export DISPLAY=:99
export LIBGL_ALWAYS_SOFTWARE=1
Xvfb :99 -screen 0 1600x1000x24 -nolisten tcp >"$SHOT/xvfb-deb.log" 2>&1 &
sleep 2
nohup openbox >"$SHOT/openbox-deb.log" 2>&1 &
sleep 2
JIHUATAI_DATA_DIR="$DATA" /opt/jihuatai/jihuatai >"$SHOT/app-deb.log" 2>&1 &
for i in $(seq 1 90); do xdotool search --name '计划台' >/dev/null 2>&1 && break; sleep 1; done
sleep 40
W=$(xdotool search --name '计划台' | head -1 || true)
if [ -n "$W" ]; then
  ok "应用窗口已出现"
  TITLE=$(xdotool getwindowname "$W" 2>/dev/null || true)
  echo "窗口标题：$TITLE"
  case "$TITLE" in *计划台*) ok "窗口标题正确（含“计划台”）";; *) bad "窗口标题异常：$TITLE";; esac
  xdotool getwindowgeometry --shell "$W"
else
  bad "应用窗口未出现（见 app-deb.log）"
fi
import -window root "$SHOT/100-deb-installed-home.png" || true

step "4. 数据位置检查（必须在用户目录，不能装进 /opt）"
if [ -f "$DATA/data/app.db" ]; then ok "测试数据目录已建库：$DATA/data/app.db"; else bad "未在测试数据目录建库"; fi
if find /opt/jihuatai -name '*.db' -o -name 'app.db' 2>/dev/null | grep -q .; then
  bad "/opt/jihuatai 内出现数据库文件（违规）"
else
  ok "/opt/jihuatai 内无用户数据库"
fi
if [ -f "$HOME/.local/share/计划台/data/app.db" ]; then
  ok "默认用户数据目录存在（~/.local/share/计划台/data）"
else
  echo "[INFO] 未触发默认目录（本次用 JIHUATAI_DATA_DIR 隔离测试，属预期）"
fi

step "5. 关闭应用（模拟正常关闭）"
pkill -x jihuatai || true
sleep 3
pgrep -x jihuatai >/dev/null && bad "应用未退出" || ok "应用已正常退出"
DB_HASH_BEFORE=$(sha256sum "$DATA/data/app.db" 2>/dev/null | cut -d' ' -f1 || true)
echo "db sha256: $DB_HASH_BEFORE"

step "6. 相同版本重新安装（不破坏数据）"
DB_BEFORE=$(sha256sum "$DATA/data/app.db" 2>/dev/null | cut -d' ' -f1 || true)
sudo dpkg -i "$DEB" >/dev/null || sudo apt-get install -f -y >/dev/null
DB_AFTER=$(sha256sum "$DATA/data/app.db" 2>/dev/null | cut -d' ' -f1 || true)
[ -n "$DB_BEFORE" ] && [ "$DB_BEFORE" = "$DB_AFTER" ] && ok "同版本重装后数据库未变" || bad "同版本重装导致数据库变化"

step "7. 版本升级（新版本 deb 覆盖安装，数据保留）"
if [ -n "$DEB2" ]; then
  sudo dpkg -i "$DEB2" >/dev/null || sudo apt-get install -f -y >/dev/null
  NEWVER=$(dpkg-query -W -f='${Version}' jihuatai 2>/dev/null || echo '?')
  echo "升级后包版本：$NEWVER"
  DB_UP=$(sha256sum "$DATA/data/app.db" 2>/dev/null | cut -d' ' -f1 || true)
  [ -n "$DB_BEFORE" ] && [ "$DB_BEFORE" = "$DB_UP" ] && ok "升级后数据库未变" || bad "升级导致数据库变化"
  [ -f "$DATA/data/app.db" ] && ok "升级后用户数据库仍在" || bad "升级后数据库丢失"
else
  echo "[SKIP] 未提供升级用 deb"
fi

step "8. 卸载（不删除用户数据）"
sudo apt-get remove -y jihuatai >/dev/null 2>&1 || sudo dpkg -r jihuatai >/dev/null
sleep 1
[ ! -e /opt/jihuatai ] && ok "卸载后 /opt/jihuatai 已移除" || bad "/opt/jihuatai 残留"
[ ! -e /usr/share/applications/com.jihuatai.jihuatai.desktop ] && ok "卸载后菜单入口已移除" || bad "菜单入口残留"
[ -f "$DATA/data/app.db" ] && ok "卸载后用户数据仍保留（未删除）" || bad "卸载删除了用户数据（违规）"
sudo apt-get purge -y jihuatai >/dev/null 2>&1 || true

step "9. 结果"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "DEB_TEST_PASS" || echo "DEB_TEST_FAIL"
