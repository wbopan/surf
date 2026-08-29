#!/bin/zsh
# 假的 dsh：只报到、只等着，收到 TERM 时留一行字据。
trap 'echo "inner got TERM"; exit 0' TERM
echo "inner up pid=$$ pgid=$(ps -o pgid= -p $$ | tr -d ' ')"
while true; do sleep 0.2; done
