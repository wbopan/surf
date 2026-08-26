#!/bin/bash
# 一次跑完：起探针 → 逐行悬停右列那枚按钮 → 截图。左列同图未被悬停 = 基准。
# 每次换目标前先把游标甩出窗口再进来：窗口级的 enter/exit 是窗口服务器生成的，
# 可靠；窗口内部从一枚按钮直接跳到另一枚，AppKit 那边不一定收得到移动事件。
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SHOT="$HERE/../../../tools/shot.sh"
PARK="60 700"
./HoverProbe --hold > targets.txt 2>/dev/null &
PROBE=$!
trap 'kill $PROBE 2>/dev/null || true' EXIT
sleep 2.5
./warp $PARK >/dev/null; sleep 0.5
"$SHOT" "$HERE/idle.png" --app HoverProbe --scale 2 >/dev/null
for R in 0 1 2 3; do
  read -r X Y <<< "$(awk -v r=$((R*2+2)) 'NR==r{print $5, $6}' targets.txt)"
  ./warp $PARK >/dev/null; sleep 0.4
  ./warp "$X" "$Y" >/dev/null; sleep 0.9
  "$SHOT" "$HERE/hover_$R.png" --app HoverProbe --scale 2 >/dev/null
done
./warp $PARK >/dev/null
