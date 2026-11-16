#!/usr/bin/env bash
# 计划台 Linux 版本地功能验收（无头 GUI，Xvfb + xdotool + sqlite3）
#
# 覆盖 docs 中阶段 1 任务 4 的 12 步：
#   启动 → 月历 → 新建项目/颜色 → 新建跨日期安排 → 双击日期开面板 →
#   新建/编辑/删除任务 → 勾选完成 → 编辑备注 → 切换月份 → 关闭 → 重启 → 校验数据
#
# 前置：
#   - 已用 tool/ubuntu/guest_setup.sh 装好环境；
#   - 已在仓库根目录执行 `flutter build linux --debug`；
#   - 环境变量（可选）：APP_BIN / JI_DATA_DIR / JI_SHOT_DIR / JI_DISPLAY
#
# 用法：
#   bash tool/ubuntu/ui_acceptance.sh
#
# 输出：
#   $JI_SHOT_DIR/01..13-*.png   各步骤截图
#   $JI_SHOT_DIR/acceptance.log 验收日志（含 sqlite 断言结果）
# 退出码 0 = 全部步骤通过；非 0 = 有失败（日志里有 FAIL 行）。
set -uo pipefail

APP="${APP_BIN:-$HOME/jihuatai/build/linux/x64/debug/bundle/jihuatai}"
DATA_DIR="${JI_DATA_DIR:-$HOME/jht-acceptance-data}"
SHOT_DIR="${JI_SHOT_DIR:-$HOME/jht-acceptance-shots}"
DISPLAY_NUM="${JI_DISPLAY:-:99}"
SCREEN_SIZE="${JI_SCREEN:-1600x1000x24}"
LOG="$SHOT_DIR/acceptance.log"

mkdir -p "$SHOT_DIR"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

PASS=0
FAIL=0
ok()   { echo "[ OK ] $*"; PASS=$((PASS + 1)); }
bad()  { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
step() { echo; echo "== $* =="; }

export DISPLAY="$DISPLAY_NUM"
export LIBGL_ALWAYS_SOFTWARE=1

shot() { import -window root "$SHOT_DIR/$1.png"; echo "  shot: $1.png"; }
click() { xdotool mousemove --sync "$1" "$2" click 1; sleep 0.9; }
dclick() { xdotool mousemove --sync "$1" "$2" click --repeat 2 --delay 120 1; sleep 1.3; }
type_text() { xdotool type --delay 45 -- "$1"; sleep 0.7; }
send_key() { xdotool key -- "$1"; sleep 0.7; }
wait_ui() { sleep "${1:-1}"; }

# 窗口原点（窗口 1440x900 居中于 1600x1000 → 默认 80,50；启动后从 geometry 校正）
WIN_X=80
WIN_Y=50
# 相对窗口内容区（本地坐标）的坐标：均为 2026-11-15 在 Ubuntu 24.04 + Xvfb 1600x1000 上实测。
# 注意：无窗口管理器环境下 xdotool 单击偶发丢失，正式跑前建议先点一次空白处聚焦（脚本里已做）。
# 侧栏
SIDEBAR_X=86
NAV_CALENDAR_Y=116
NAV_PROJECTS_Y=150
MANAGE_PROJECTS_Y=362
# 顶栏
NEW_SPAN_X=1390
NEW_SPAN_Y=28
PREV_MONTH_X=255
NEXT_MONTH_X=337
MONTH_TOGGLE_Y=29
# 日历网格（实测：网格左上 local x≈240 已被面板挤压；无面板时 x≈160，行高≈155，列宽≈165）
GRID_X0=160
GRID_Y0=140
CELL_W=165
CELL_H=155
day_cell_x() { echo $((WIN_X + GRID_X0 + (($1 - 1) % 7) * CELL_W + CELL_W / 2)); }
day_cell_y() { echo $((WIN_Y + GRID_Y0 + ($1 / 7) * CELL_H + CELL_H / 2)); }

cx() { echo $((WIN_X + $1)); }
cy() { echo $((WIN_Y + $1)); }

db_counts() {
  local db="$DATA_DIR/data/app.db"
  sqlite3 "$db" "SELECT COUNT(*) FROM projects WHERE deleted_at IS NULL;" 2>/dev/null || echo -1
}

expect_db() {
  local sql="$1" expected="$2" label="$3"
  local actual
  actual=$(sqlite3 "$DATA_DIR/data/app.db" "$sql" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then ok "$label（$actual）"; else bad "$label：期望 [$expected] 实际 [$actual]"; fi
}

cleanup() {
  pkill -f "bundle/jihuatai" >/dev/null 2>&1 || true
  pkill -f "Xvfb $DISPLAY_NUM" >/dev/null 2>&1 || true
  sleep 1
}
trap cleanup EXIT

step "0. 准备独立数据目录（不触碰真实用户数据）"
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"
cleanup
Xvfb "$DISPLAY_NUM" -screen 0 "$SCREEN_SIZE" -nolisten tcp >"$SHOT_DIR/xvfb.log" 2>&1 &
sleep 2

start_app() {
  JIHUATAI_DATA_DIR="$DATA_DIR" "$APP" >"$SHOT_DIR/app.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 30); do
    if xdotool search --name '计划台' >/dev/null 2>&1; then break; fi
    sleep 1
  done
  sleep 6
  local win
  win=$(xdotool search --name '计划台' | head -1)
  if [ -n "$win" ]; then
    eval "$(xdotool getwindowgeometry --shell "$win")"
    WIN_X="$X"
    WIN_Y="$Y"
    ok "应用已启动（窗口 $WIDTH x $HEIGHT @ $WIN_X,$WIN_Y）"
  else
    bad "应用窗口未出现，见 app.log"
  fi
}

step "1. 启动计划台"
start_app
shot "01-home"
wait_ui 2

step "2. 月历主页"
shot "02-calendar"
ok "月历截图已保存"

step "3. 新建项目并设置颜色"
click "$(cx $SIDEBAR_X)" "$(cy $MANAGE_PROJECTS_Y)"
wait_ui 2
shot "03-projects-page"
# 新建项目按钮在项目管理页右上角
click "$(cx 1290)" "$(cy 64)"
wait_ui 2
shot "03b-new-project-dialog"
xdotool key -- 'ctrl+a' >/dev/null 2>&1 || true
type_text "Ubuntu验收项目"
# 选一个非默认颜色（色板第 2 个圆形色块，坐标见实测修正）
click "$(cx 700)" "$(cy 300)"
shot "03c-project-color"
# 保存
send_key "Return"
wait_ui 2
shot "04-project-created"
expect_db "SELECT COUNT(*) FROM projects WHERE name='Ubuntu验收项目' AND deleted_at IS NULL;" "1" "项目已写入数据库"

step "4. 创建跨日期安排"
click "$(cx $SIDEBAR_X)" "$(cy $NAV_CALENDAR_Y)"
wait_ui 2
click "$(cx $NEW_SPAN_X)" "$(cy $NEW_SPAN_Y)"
wait_ui 2
shot "05-span-editor"
type_text "Ubuntu跨天阶段"
click "$(cx 760)" "$(cy 320)"
send_key "Return"
wait_ui 2
shot "06-span-created"
expect_db "SELECT COUNT(*) FROM plan_spans WHERE title='Ubuntu跨天阶段' AND deleted_at IS NULL;" "1" "跨天阶段已写入数据库"

step "5. 双击日期打开右侧面板"
dclick "$(day_cell_x 3)" "$(day_cell_y 15)"
wait_ui 2
shot "07-day-panel"

step "6. 新建每日任务"
click "$(cx 1200)" "$(cy 700)"
wait_ui 1
shot "08a-task-editor"
type_text "Ubuntu每日任务"
send_key "Return"
wait_ui 2
shot "08b-task-created"
expect_db "SELECT COUNT(*) FROM planner_tasks WHERE title='Ubuntu每日任务' AND deleted_at IS NULL;" "1" "任务已写入数据库"

step "7. 编辑任务"
# 打开任务编辑器，改标题
click "$(cx 1200)" "$(cy 700)"
wait_ui 1
send_key "ctrl+a"
type_text "Ubuntu任务已编辑"
send_key "Return"
wait_ui 2
shot "09-task-edited"
expect_db "SELECT COUNT(*) FROM planner_tasks WHERE title='Ubuntu任务已编辑' AND deleted_at IS NULL;" "1" "任务标题已更新"

step "8. 勾选任务完成"
click "$(cx 1250)" "$(cy 700)"
wait_ui 2
shot "10-task-completed"
expect_db "SELECT COUNT(*) FROM planner_tasks WHERE title='Ubuntu任务已编辑' AND deleted_at IS NULL AND completed_at IS NOT NULL;" "1" "任务完成状态已持久化"

step "9. 编辑每日备注"
click "$(cx 1100)" "$(cy 800)"
wait_ui 1
type_text "Ubuntu本地备注：离线也可用"
send_key "Return"
wait_ui 2
shot "11-note-edited"
expect_db "SELECT COUNT(*) FROM daily_notes WHERE note LIKE '%Ubuntu本地备注%';" "1" "每日备注已写入数据库"

step "10. 切换月份"
click "$(cx $NEXT_MONTH_X)" "$(cy $MONTH_TOGGLE_Y)"
wait_ui 2
shot "12-next-month"
click "$(cx $PREV_MONTH_X)" "$(cy $MONTH_TOGGLE_Y)"
wait_ui 2

step "11. 关闭软件"
send_key "alt+F4"
wait_ui 3
if pgrep -f "bundle/jihuatai" >/dev/null; then
  bad "应用未退出"
else
  ok "应用已正常退出"
fi
sleep 1
cp -f "$DATA_DIR/data/app.db" "$SHOT_DIR/app-before-restart.db" 2>/dev/null || true
shot "12b-closed"

step "12. 重新启动并校验数据"
start_app
wait_ui 2
shot "13-restarted"
expect_db "SELECT COUNT(*) FROM projects WHERE name='Ubuntu验收项目' AND deleted_at IS NULL;" "1" "重启后项目仍在"
expect_db "SELECT COUNT(*) FROM plan_spans WHERE title='Ubuntu跨天阶段' AND deleted_at IS NULL;" "1" "重启后跨天阶段仍在"
expect_db "SELECT COUNT(*) FROM planner_tasks WHERE title='Ubuntu任务已编辑' AND deleted_at IS NULL AND completed_at IS NOT NULL;" "1" "重启后任务及其完成状态仍在"
expect_db "SELECT COUNT(*) FROM daily_notes WHERE note LIKE '%Ubuntu本地备注%';" "1" "重启后备注仍在"

step "13. 断网状态下核心本地操作"
# 用独立网络命名空间运行（无任何网络接口），验证本地功能不依赖网络
if sudo -n true 2>/dev/null; then
  pkill -f "bundle/jihuatai" >/dev/null 2>&1 || true
  sleep 2
  sudo -n unshare -n env JIHUATAI_DATA_DIR="$DATA_DIR" DISPLAY="$DISPLAY_NUM" LIBGL_ALWAYS_SOFTWARE=1 \
    "$APP" >"$SHOT_DIR/app-offline.log" 2>&1 &
  sleep 12
  shot "14-offline"
  if pgrep -f "bundle/jihuatai" >/dev/null; then
    ok "断网（独立网络命名空间）下应用可启动并渲染"
  else
    bad "断网下应用启动失败，见 app-offline.log"
  fi
  pkill -f "bundle/jihuatai" >/dev/null 2>&1 || true
else
  echo "[SKIP] 无免密 sudo，跳过独立网络命名空间的断网测试；本地功能本身不发起网络请求（云未配置）"
fi

step "结果"
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "ACCEPTANCE_PASS"
  exit 0
else
  echo "ACCEPTANCE_FAIL"
  exit 1
fi
