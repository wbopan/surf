# 设计稿源（`.dc.html` 画板）

两套画布的**源文件**。画布本身是 claude.ai 上的托管页面（artifact），
链接各在子目录的 README 里。

```
settings-layout/    设置窗口的版式草图（六张画板 + 生成脚本）
web-header/         dsh web header 贴原生的对照稿（四张画板）
```

## 为什么把源留在仓库里

画布是托管页面，仓库里留一份源是为了：**改动可 diff**（版式是一行行代码，不是一张
截图）、**离线也打得开**、**artifact 没了还能重建**。

## 怎么打开

每张 `.dc.html` 都是一份自足的静态页面，浏览器直接打开即可：

```sh
open docs/design/settings-layout/Main.dc.html
```

同目录的 `canvas.json` 只记画板在画布上的排布与便签，单看一张画板用不到它。
`settings-layout/` 那套还有 `mk.mjs` / `_parts.mjs`——**改版式改这两个再
`node mk.mjs`**，别手改生成出来的六张。
