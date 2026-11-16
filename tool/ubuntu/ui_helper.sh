#!/usr/bin/env bash
# 计划台 Linux 版无头 GUI 操作助手（Xvfb + xdotool + ImageMagick）
#
# 仅用于开发/验收：在无显示器的 Ubuntu 上启动真实 GTK 窗口，
# 用 xdotool 模拟鼠标键盘并截图，验证业务功能。
#
# 用法：
#   ui_helper.sh start            # 启动 Xvfb + 应用，截图 00-start.png
#   ui_helper.sh shot NAME        # 截图 -> $JI_SHOT_DIR/NAME.png
#   ui_helper.sh click X Y        # 绝对坐标左键单击
#   ui_helper.sh dclick X Y       # 双击
#   ui_helper.sh move X Y         # 移动鼠标（触发 hover）
#   ui_helper.sh type TEXT        # 输入文本
#   ui_helper.sh key KEYS         # 例如 Return / Escape / ctrl+a
#   ui_helper.sh geometry         # 打印窗口位置与尺寸
#   ui_helper.sh db               # 用 sqlite3 打印主库表计数
#   ui_helper.sh stop             # 关闭应用与 Xvfb
#
# 环境变量：
#   APP_BIN     可执行文件（默认 debug bundle）
#   JI_DATA_DIR 数据目录（默认 ~/jht-data，独立于真实用户目录）
#   JI_SHOT_DIR 截图与日志目录（默认 ~/jht-shots）
#   JI_DISPLAY  Xvfb 显示号（默认 :99）
set -euo pipefail

APP="${APP_BIN:-$HOME/jihuatai/build/linux/x64/debug/bundle/jihuatai}"
DATA_DIR="${JI_DATA_DIR:-$HOME/jht-data}"
SHOT_DIR="${JI_SHOT_DIR:-$HOME/jht-shots}"
DISPLAY_NUM="${JI_DISPLAY:-:99}"
SCREEN_SIZE="${JI_SCREEN:-1600x1000x24}"

CMD="${1:-help}"
shift || true

export DISPLAY="$DISPLAY_NUM"

app_pid() { pgrep -f "bundle/jihuatai" | head -1 || true; }

case "$CMD" in
  start)
    mkdir -p "$SHOT_DIR" "$DATA_DIR"
    pkill -f "bundle/jihuatai" >/dev/null 2>&1 || true
    pkill -f "Xvfb $DISPLAY_NUM" >/dev/null 2>&1 || true
    sleep 1
    Xvfb "$DISPLAY_NUM" -screen 0 "$SCREEN_SIZE" -nolisten tcp >"$SHOT_DIR/xvfb.log" 2>&1 &
    sleep 2
    LIBGL_ALWAYS_SOFTWARE=1 JIHUATAI_DATA_DIR="$DATA_DIR" "$APP" >"$SHOT_DIR/app.log" 2>&1 &
    sleep 12
    import -window root "$SHOT_DIR/00-start.png"
    if xdotool search --name '计划台' >/dev/null 2>&1; then
      xdotool search --name '计划台' getwindowgeometry --shell >"$SHOT_DIR/geometry.txt" 2>&1 || true
    else
      xdotool search --class jihuatai getwindowgeometry --shell >"$SHOT_DIR/geometry.txt" 2>&1 || true
    fi
    echo "started app pid $(app_pid)"
    cat "$SHOT_DIR/geometry.txt" 2>/dev/null || true
    ;;
  shot)
    import -window root "$SHOT_DIR/$1.png"
    echo "$SHOT_DIR/$1.png"
    ;;
  click)
    xdotool mousemove --sync "$1" "$2" click 1
    sleep 0.8
    ;;
  dclick)
    xdotool mousemove --sync "$1" "$2" click --repeat 2 --delay 120 1
    sleep 1.2
    ;;
  move)
    xdotool mousemove --sync "$1" "$2"
    sleep 0.4
    ;;
  type)
    xdotool type --delay 40 -- "$1"
    sleep 0.6
    ;;
  key)
    xdotool key -- "$1"
    sleep 0.6
    ;;
  geometry)
    cat "$SHOT_DIR/geometry.txt" 2>/dev/null || echo "no geometry"
    ;;
  db)
    DB="$DATA_DIR/data/app.db"
    echo "db=$DB"
    if [ -f "$DB" ]; then
      sqlite3 "$DB" "SELECT 'projects', COUNT(*) FROM projects UNION ALL SELECT 'tasks', COUNT(*) FROM planner_tasks UNION ALL SELECT 'spans', COUNT(*) FROM plan_spans UNION ALL SELECT 'notes', COUNT(*) FROM daily_notes;"
      sqlite3 "$DB" "PRAGMA user_version;"
    else
      echo "database not found"
    fi
    ;;
  stop)
    pkill -f "bundle/jihuatai" >/dev/null 2>&1 || true
    sleep 1
    pkill -f "Xvfb $DISPLAY_NUM" >/dev/null 2>&1 || true
    echo stopped
    ;;
  *)
    echo "unknown command: $CMD" >&2
    exit 2
    ;;
esac
