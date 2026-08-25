# 带色玻璃实测台（可复跑）

问「系统的蓝键/红键玻璃到底长什么样」时用的三件套。结论写在
`dash-nativeify/README.md` 的「带色玻璃」一节，这里只留复跑步骤。

```bash
swiftc -O TintProbe.swift -o TintProbe
swiftc -O rgbcol.swift    -o rgbcol      # 逐行打印 RGB
swiftc -O bbox.swift      -o bbox        # 找蓝/红连通块的包围盒

./TintProbe --hold &                     # --hold = 反复抢 key，截激活态
sleep 3
../../../dash-app/host/scripts/shot.sh tint.png --app TintProbe --scale 3
kill %1

./bbox   tint.png                        # 四枚按钮的 y/x 区间
./rgbcol tint.png 150 350 372            # 某一列逐行 RGB
```

**必须截激活态。** 失活窗口里带色玻璃会把 tint 整个丢掉，退成平灰 ——
拿它当基准量出来的一切都是错的。`--hold` 的回执在窗口标题里（`ACTIVE/KEY`），
截图上能直接看见；不带 `--hold` 截到的就是失活态，正好用来量失活那两档。

`--hold` 会抢走前台焦点几秒，别在用户正打字时跑。
