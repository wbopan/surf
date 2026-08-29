#!/bin/zsh
# 假的 ./dev：模拟"外层等着内层"的两层形态（真身是 node → spawnSync(dsh)）。
# 内层跑在前台，外层阻塞在 wait 里——这正是 SIGTERM 只送外层时会漏掉的那一层。
echo "outer up pid=$$ pgid=$(ps -o pgid= -p $$ | tr -d ' ')"
"$(dirname "$0")/fake-dsh.sh"
echo "outer exiting rc=$?"
