#!/bin/bash
# 按下态：探针自己把游标挪到目标并 postEvent 一记 leftMouseDown 按住，12s 后松开。
# **等 stdout 打出 PRESSED 再截图** —— 窗口没成为 key 之前玻璃是失活渲染，
# 那时候量出来的一切都是错的。
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SHOT="$HERE/../../../dash-app/host/scripts/shot.sh"
for R in 0 1 2 3; do
  LOG="$HERE/press_$R.log"; : > "$LOG"
  ./HoverProbe --hold --press $R > "$LOG" 2>/dev/null &
  P=$!
  for _ in $(seq 60); do grep -q PRESSED "$LOG" && break; sleep 0.25; done
  grep -q PRESSED "$LOG" || { echo "row $R 没等到 PRESSED"; kill $P; exit 1; }
  sleep 0.8
  "$SHOT" "$HERE/press_$R.png" --app HoverProbe --scale 2 >/dev/null
  kill $P 2>/dev/null || true; wait $P 2>/dev/null || true
done
./warp 60 700 >/dev/null
