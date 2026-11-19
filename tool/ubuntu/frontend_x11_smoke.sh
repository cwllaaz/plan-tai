#!/usr/bin/env bash
# Usage: bash tool/ubuntu/frontend_x11_smoke.sh [bundle/jihuatai] [evidence-parent]
# JI_SCREEN=1600x1000x24, JI_GDK_SCALE=1 (or 2). Runs only on a private Xvfb.
set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
wait_for() {
  for ((i = 0; i < 200; i++)); do
    if "$@"; then return; fi
    sleep 0.1
  done
  die "timed out: $*"
}

if [[ ${1:-} != --private-x11 ]]; then
  root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
  app=$(realpath -e -- "${1:-$root/build/linux/x64/release/bundle/jihuatai}")
  [[ -x "$app" ]] || die "not an executable: $app"
  scale=${JI_GDK_SCALE:-1}
  screen=${JI_SCREEN:-1600x1000x24}
  [[ "$scale" =~ ^[12]$ && "$screen" =~ ^[0-9]+x[0-9]+x24$ ]] ||
    die 'JI_GDK_SCALE must be 1 or 2; JI_SCREEN must be WIDTHxHEIGHTx24'
  for cmd in xvfb-run Xvfb xauth openbox xdpyinfo xprop xwininfo wmctrl xdotool import; do
    command -v "$cmd" >/dev/null || die "missing $cmd"
  done
  out=$(mktemp -d -- "${2:-/tmp}/jihuatai-x11.XXXXXXXX")
  echo "Evidence: $out"
  mkdir -m 700 -- "$out/data" "$out/config" "$out/cache" "$out/runtime" "$out/state"
  # xvfb-run picks an unused display and creates its own Xauthority cookie.
  # Forget the caller's GUI session, IBus and D-Bus before launching anything.
  exec env -u DISPLAY -u WAYLAND_DISPLAY -u WAYLAND_SOCKET -u XAUTHORITY \
    -u DBUS_SESSION_BUS_ADDRESS -u IBUS_ADDRESS -u XDG_CURRENT_DESKTOP \
    JIHUATAI_DEMO=1 JIHUATAI_DATA_DIR="$out/data" XDG_CONFIG_HOME="$out/config" \
    XDG_CACHE_HOME="$out/cache" XDG_STATE_HOME="$out/state" XDG_RUNTIME_DIR="$out/runtime" \
    XDG_DATA_HOME="$out/data" XDG_SESSION_TYPE=x11 GDK_BACKEND=x11 \
    GDK_SCALE="$scale" GDK_DPI_SCALE=1 GTK_IM_MODULE=gtk-im-context-simple \
    LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a -e "$out/xvfb.log" \
    -s "-screen 0 $screen -dpi 96 -nolisten tcp" bash "${BASH_SOURCE[0]}" \
    --private-x11 "$app" "$out" "$screen" "$scale"
fi

shift
app=$1 out=$2 screen=$3 scale=$4
exec > >(tee "$out/acceptance.log") 2>&1
# Fail closed if invoked directly with an unrelated desktop/data directory.
[[ ${DISPLAY:-} =~ ^:([0-9]+)$ && -r ${XAUTHORITY:-/nonexistent} ]] ||
  die 'private Xvfb display and Xauthority are required'
read -r display_pid < "/tmp/.X${BASH_REMATCH[1]}-lock"
[[ $(ps -o comm= -p "$display_pid") == Xvfb &&
   $(ps -o ppid= -p "$display_pid" | tr -d ' ') == "$PPID" &&
   ${JIHUATAI_DEMO:-} == 1 && ${JIHUATAI_DATA_DIR:-} == "$out/data" &&
   -d "$out/data" && ! -L "$out/data" &&
   -z $(find "$out/data" -mindepth 1 -print -quit) ]] ||
  die 'display must belong to this xvfb-run; data must be a new empty directory'

app_pid= wm_pid=
cleanup() {
  for pid in "$app_pid" "$wm_pid"; do
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" || true; fi
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'app=%s\ndisplay=%s\ndata=%s\nGDK_SCALE=%s\n' \
  "$app" "$DISPLAY" "$JIHUATAI_DATA_DIR" "$scale"
xdpyinfo | awk '/dimensions:|resolution:/'
fc-match ':lang=zh-cn' || true
openbox --sm-disable >"$out/openbox.log" 2>&1 &
wm_pid=$!
wait_for sh -c 'wmctrl -m >/dev/null 2>&1'
wmctrl -m
"$app" >"$out/app.log" 2>&1 &
app_pid=$!
find_window() {
  window=$(xdotool search --all --onlyvisible --pid "$app_pid" --name '计划台' 2>/dev/null | head -1) || return 1
  [[ -n "$window" ]]
}
wait_for find_window

read_geometry() {
  read -r x y width height < <(LC_ALL=C xwininfo -id "$window" | awk '
    /Absolute upper-left X:/ { x=$NF }
    /Absolute upper-left Y:/ { y=$NF }
    /Width:/ { w=$NF }
    /Height:/ { h=$NF }
    END { if (w && h) print x,y,w,h }')
}
shot() {
  read_geometry
  printf '%s: %sx%s+%s+%s (physical pixels)\n' "$1" "$width" "$height" "$x" "$y"
  import -window root "$out/$1.png"
}
maximized() {
  local state
  state=$(xprop -id "$window" _NET_WM_STATE)
  [[ $state == *MAXIMIZED_HORZ* && $state == *MAXIMIZED_VERT* ]]
}
at_default_size() {
  read_geometry && [[ $width == "$expected_w" && $height == "$expected_h" ]]
}
restored() {
  ! maximized && read_geometry &&
    [[ $width == "$default_w" && $height == "$default_h" &&
       $x == "$default_x" && $y == "$default_y" ]]
}

screen_w=${screen%%x*}
screen_h=${screen#*x}; screen_h=${screen_h%%x*}
expected_w=$((screen_w / scale - 64))
expected_h=$((screen_h / scale - 64))
(( expected_w >= 1100 && expected_h >= 700 )) ||
  die 'test display must fit the minimum content area and decorations'
(( expected_w <= 1440 )) || expected_w=1440
(( expected_h <= 900 )) || expected_h=900
expected_w=$((expected_w * scale))
expected_h=$((expected_h * scale))
# Dart can map the window before Flutter's first frame applies the work-area
# limit. Wait for that allocation before measuring the restored geometry.
wait_for at_default_size
sleep 1
shot 01-startup
xprop -id "$window" _NET_WM_NAME WM_NORMAL_HINTS _NET_FRAME_EXTENTS
default_w=$width default_h=$height default_x=$x default_y=$y
read -r left right top bottom < <(LC_ALL=C xprop -id "$window" _NET_FRAME_EXTENTS |
  awk -F' = ' '{gsub(/,/, "", $2); print $2}')
[[ $left =~ ^[0-9]+$ && $right =~ ^[0-9]+$ && $top =~ ^[0-9]+$ &&
   $bottom =~ ^[0-9]+$ ]] || die 'missing Openbox frame extents'
wmctrl -ir "$window" -b add,maximized_vert,maximized_horz
wait_for maximized
sleep 0.5
shot 02-maximized
wmctrl -ir "$window" -b remove,maximized_vert,maximized_horz
wait_for restored
shot 03-restored
xdotool windowsize "$window" 640 480
sleep 0.7
shot 04-shrink-request
hint=$(LC_ALL=C xprop -id "$window" WM_NORMAL_HINTS)
printf '%s\n' "$hint"
read -r min_w min_h < <(awk '/minimum size/ {print $(NF-2), $NF}' <<<"$hint")
[[ $width == "$min_w" && $height == "$min_h" ]] ||
  die "shrink request did not end at the WM minimum hint"
[[ $min_w == "$((1100 * scale))" && $min_h == "$((700 * scale))" ]] ||
  die "unexpected minimum client geometry: ${min_w}x${min_h}"
(( default_x - left >= 0 && default_y - top >= 0 &&
   default_x + default_w + right <= screen_w &&
   default_y + default_h + bottom <= screen_h )) ||
  die "startup frame does not fit on screen"
echo 'PASS: startup fits, maximize and restore, minimum size'
