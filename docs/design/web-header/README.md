# dsh web header 贴原生 · 对照稿

画布（私有 artifact，可从页面分享菜单发出去）：
<https://claude.ai/code/artifact/b9a465e2-7a9d-4ad1-ae23-577ea6630205>

这里是画布的**源文件**。画布本身是 claude.ai 上的一份托管页面，
仓库里留源是为了：改动可 diff、离线也打得开、artifact 没了还能重建。

```
Current.dc.html  现状 —— dsh 自己的 web header，标签行把它撑到 76pt 两行，标题偏上
Main.dc.html     方案 · 浅色 —— 52pt 一行，标题簇与三枚胶囊共用同一条中线
Dark.dc.html     方案 · 深色 —— 同一版式的深色态
Spec.dc.html     尺寸标注 —— 每个数值出自 Apple macOS 27 UI Kit
canvas.json      画板在画布上的排布、便签
```

## 对比判据

左半是原生侧边栏（52pt 标题栏、36pt 胶囊、中线 y=26）。四张画板都拿它当尺子：
方案让右半的标题簇与三枚胶囊落在同一条中线上，现状则两样都对不齐。

所有数值来自 Apple 官方 macOS 27 UI Kit（`tools/apple-kit/`）与 dsh 0.1.1-rc.2
的 CSS 源码，权威计划见 `docs/archive/web-header-native-match-plan.md`。
