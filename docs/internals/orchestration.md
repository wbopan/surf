# 编排：这些包是怎么被装进 dsh 的

这篇讲 **surfclam 的一堆 npm 包是怎么变成 dsh 进程里的一棵插件树的**：
profile / bundle / plugin 三层怎么分工、编排权在谁手上、模块解析靠什么、
一个插件的三个半边各住在哪、各自改完要付什么代价。写给**本仓库的维护者**。

写外部插件的人只需要读
[`../extend/plugin-author-guide.md`](../extend/plugin-author-guide.md) §7——
接进编排只是往自己 profile 的 patch 层 insert 一行，不必懂这里的全部。

---

## 1. profile / bundle / plugin：三层，别混

| 层 | 是什么 | 我们这一份 |
|---|---|---|
| **profile** | 一张 `bundles` 清单（`<profile>/package.json` 的 `dsh.profile.bundles`）。**零代码** | 装好的那套叫 `surfclam` |
| **bundle** | 一张**编排表**（`cordis.patch.yml`）：装哪些包、什么顺序、什么配置。代码在别处 | 伞包 `@wenbo/surfclam`（目录 `surfclam/`） |
| **plugin** | 真正的代码，纯 npm 包。**不声明 `dsh.bundle`** | `@wenbo/clam-*` 那八个 |

`@deepseek-ai/dsh-web-app` 就是这个形状的范本：自己只有两三百行，却编排了
八十多个 row、依赖近七十个包。

**编排权集中在伞包那一张表上，这是一处刻意的收口。** 子包各自带一份
`cordis.patch.yml`、各自声明 `dsh.bundle` 是可行的（dsh 支持），但那样
"装了哪些插件、什么顺序" 就散在八个包里，而且它们会各自被 reconcile 进
`bundles`——同一个插件挂载两次这类问题从此有了滋生的地方。摘掉子包的
`dsh.bundle` 声明之后，**改编排只改 `surfclam/cordis.patch.yml` 一个文件**。

---

## 2. 我们的 profile 只列三个 bundle

```
@deepseek-ai/dsh-base + @deepseek-ai/dsh-web-app + @wenbo/surfclam
```

**三者平级。** 不存在"我们的 profile 依赖 web profile"这回事——dsh 自带的 `web`
profile 本身也只是 `[dsh-base, dsh-web-app]` 这两层的组合而已，我们只是在后面
再叠一层。

前两个是 dsh 的 **in-box bundle**：`resolveBundleDir` 先从 dsh 的安装目录解析，
所以**既不用装，也不用写进任何 `dependencies`**。

profile 自己的 `cordis.patch.yml`（用户那一层）在所有 bundle 层之后应用，
可以覆盖我们表里的任何 config，也可以 disable 我们任何一个插件。
**那个文件我们绝不碰**——它是 dsh 留给用户的口子。

---

## 3. 编排表长什么样

`surfclam/cordis.patch.yml` 是一串 `insert`，每行三样东西：`id`（诊断树上的名字）、
`name`（包名）、可选的 `config`：

```yaml
- insert:
    - id: clam-bridge
      name: "@wenbo/clam-bridge"
      config:
        path: /clam/bridge
        pollIntervalMs: 500

    - id: clam-app
      name: "@wenbo/clam-app"
      config:
        configuration: Debug
        build: true
        launch: true
        watch: true
        restartOnRebuild: false
    # …
```

**行序不带加载语义。** 挂载时序由 cordis 的依赖解析决定：带 Swift 载荷的插件都
`inject: ["clamBridge"]`（`createSwiftPlugin` 自动补），clam-sidebar 还
`inject: ["clam-layout"]`。表里的顺序只影响诊断树读起来顺不顺眼。

被编排的插件里有一个不需要 macOS：`clam-memory` 是纯 node，不占槽、不碰桥，
排在这张表上只是因为它属于这套编排。

---

## 4. 两个必须知道的坑

`surfclam/bin/surfclam.js` 的 `fixBundles` 就是在收拾它们。

### 4.1 `@deepseek-ai/dsh-web-app` 得手动列进 `bundles`

dsh 的 `PROFILE_TEMPLATES` 只给 `web` 和 `headless` 两个名字配了模板。
**别的 profile 初始化时只拿到 `dsh-base`**，web 那一层不会自己出现——
于是浏览器打开是空的，而没有任何一处报错。

### 4.2 被编排的插件绝不能出现在 `bundles` 里

它们已经没有 `dsh.bundle` 声明了。"列为 bundle 却没有声明"在 dsh 眼里是**配置错误**
而不是"没有 patch"，`loadProfile` 会直接 fails loud。这一条主要防的是从旧结构升级
上来的 profile：那时它们各自是 bundle，留在列表里会和伞包的表各 insert 一遍，
同一个插件挂载两次。

`fixBundles` 的做法是"把那三行提到最前，踢掉被编排的插件名，**其余条目原样保留**"
——用户自己 `dsh plugin add` 的别家插件不能被我们顺手清掉。

---

## 5. 模块解析：`@deepseek-ai/*` 与仓库根那条符号链接

dsh 把它依赖闭包里的近两百个 `@deepseek-ai/*` 包**扁平铺**在
`$DSH_HOME/profiles/node_modules/`。插件解析这些包名，靠的是 Node 从自己所在目录
**逐级向上**找 `node_modules`。

历史上这意味着仓库必须待在 `profiles/` 之下。其实只要在仓库根补一条指向那里的
符号链接，向上查找第一步就命中，约束即刻解除——`./dev` 会自动补它
（仓库本来就在 `profiles/` 下时什么都不做），`node_modules` 已在 `.gitignore` 里。

**这个失败模式暴露得很晚，别被前两步的绿灯骗了**：链接缺失时
`dsh plugin add` 和 `--dump-config` 都能过，直到真 `import` 才炸
`ERR_MODULE_NOT_FOUND`。判据不是 `ls -l`（软链本身看着是活的），
而是 `node -e 'import("@wenbo/surfclam")'`。

### 为什么是符号链接，而不是把 `@deepseek-ai/*` 真装进仓库

**cordis 的服务与 Schema 按实例身份认人。** 插件必须用 dsh 自己进程里的那一份，
链接天然保证这一点；装一份版本号完全相同的副本反而会因为实例不同而出诡异的错。

同一条理由决定了依赖声明的写法：**`@deepseek-ai/*`（以及 `ws`）一律写
`peerDependencies`**，不是为了包体积。

### `clam-*` 之间用相对路径 import

```js
import { createSwiftPlugin } from "../../clam-bridge/lib/plugin.js";
```

而不是 `@wenbo/clam-bridge/plugin`。包名 import 需要 npm workspace 或手工 symlink，
**那是机器本地状态，新克隆的仓库拿不到**；而"所有 `clam-*` 是同一仓库里的兄弟目录"
永远成立，零配置。

外部插件作者没有这个问题——他们的包被装进 profile 时，`@wenbo/clam-bridge` 会平铺在
profile 的 `node_modules` 里，写包名即可（并写进 peerDependencies）。

---

## 6. 开发形态为什么要把插件**和**伞包都 link 进 profile

`./dev` 装进 profile 的是 `link:` 到本仓库的**九个**包：八个插件加伞包。
看着冗余，其实必要，两条原因叠在一起：

1. **pnpm 对 `link:` 依赖不会去装被 link 目标自己的 dependencies。**
   伞包的 `dependencies` 列着那八个插件，但 link 进来时它们不会被解析安装。
2. **cordis loader 解析插件包名时的锚点是 profile 目录**，而伞包自带的
   `node_modules`（如果有的话）根本不在 Node 的向上查找链上。

不 link 它们，启动即炸：

```
Cannot find package '@wenbo/clam-bridge' imported from ~/.dsh/profiles/<profile>/
```

**发布形态下没有这个问题**：那时它们是伞包真实的 npm 依赖，会被平铺进 profile 的
`node_modules`。装好的 App 走的是第三条路——它把自己 bundle 里那份 node 载荷
镜像进 `<profile>/.surfclam/`，再手写 `link:` 行与符号链接（`Native/ProfileBootstrap.swift`），
不调 pnpm。

**三种形态下 `bundles` 都只有那三行**，因为编排权始终在伞包那张表上。
这正是摘掉子包 `dsh.bundle` 声明换来的好处。

安装顺序有讲究：先让各插件在 `node_modules` 里就位，再 link 伞包
——这样伞包那张表指向的包名在任何时刻都解析得到。

---

## 7. 一个插件的三个半边

| 半边 | 住哪 | 跑在哪 | 怎么被发现 |
|---|---|---|---|
| **node** | `lib/index.js` | dsh 进程 | 编排表里那一行 |
| **client** | `lib/client.js` | 浏览器（壳里的 WKWebView） | `package.json` 的 `dsh.client` + `exports["./client"]` |
| **swift** | `swift/*.swift` | 壳进程（运行时编译装载） | node 半边经 `createSwiftPlugin` 登记给桥 |

**三者彼此独立。** Swift 半边靠桥与自己的 node 半边说话（`push` / `invoke`），
client 半边靠页内桥与壳说话（`postMessage` → `clam.page.<type>` 广播），
node 半边与 client 半边之间**没有直连通道**。

### 更新边界（这张表决定了开发循环）

| 改什么 | 怎么生效 | 为什么 |
|---|---|---|
| `swift/` | **存盘即热替换，1~3s，不重启任何东西** | 桥常驻、500ms 轮询各 `swift/` 目录，变了就 bump 版本广播；壳重编、换代 |
| `lib/client.js` | 约 0.5s 自动重载 | `dsh-client-hmr` 常开（500ms 轮询 + SSE） |
| `lib/index.js`、`package.json`、增删插件、编排表 | **必须重启 dsh** | 官方在 web bundle 下把 node 侧 HMR `disabled: true` 了 |

第三行还藏着一个容易忘的东西：**插件的 `commands` 声明（菜单项与默认键位）住在
node 半边**，而且刻意**不进 contentHash**（改一句菜单文案不该让 Swift 半边重编）。
所以单独改它连 snapshot 里的 Swift 那部分都不会动——得重启 dsh。

**Swift 的热循环刻意不依赖 node HMR**，这是整套设计的关键推论：桥自己盯文件，
TS 半身完全不用重载。否则第一行那个"1~3 秒"就不可能成立。

---

## 8. `surfclam/bin/surfclam.js`：`./dev` 与 `./release`

伞包**不含任何运行时代码**，只有一张编排表和这一个脚本。它服务开发者，
不在仓库里跑就当场 fails loud。

### `./dev` —— 装好并前台起 dsh

```sh
./dev              # 端口交给 OS 挑
./dev --port 3080  # 想要固定端口
./dev --help
```

幂等，随便重复跑。四步：

1. `ensureModuleResolution` —— 补仓库根那条 `node_modules` 符号链接（§5）。
2. `ensureXcodegen` —— 补齐壳构建需要、但按规矩不入库的那份本机状态。
3. `installInto` —— `dsh plugin add` 把九个 `link:` 装进 profile（§6）。
4. `fixBundles` —— 校正 `bundles` 那三行（§4）。

然后前台跑 dsh（总是带 `--no-open`，免得另开一个重复的浏览器标签页）。
Ctrl-C 直达 dsh。装好之后 `dsh --profile <名字> --no-open` 也照样能用——
`./dev` 只是替你把安装那步做了。

clam-app 随之按需构建并拉起 App。**不需要手动 `dsh plugin add`。**

### `./release` —— 把这台机器装成正式形态

```sh
./release              # Release 壳进 /Applications，装完打开一次
./release --status     # endpoint / App 各在什么状态
./release --uninstall  # 删 App（会话与设置不动）
```

它复用 `./dev` 的安装函数，但**只装 App，不装任何常驻服务**：后端由壳自己托管
（连接偏好默认 `managed`，打开即有、⌘Q 即退）。

**它不备 profile。** 装好的那个 profile 的内容由 App 首次打开时自举出来（§6 末），
在这里再 link 一遍仓库源码等于给它埋一份开发形态的残留。

理由是生命周期归属：壳自托管时，后端的启动、退避重启、⌘Q 收尾都在一处可见可控
（`Native/BackendManager.swift`）；交给外部常驻服务之后，壳对它只有观测权没有控制权，
而两者会抢同一个 profile、互抹 endpoint 发现文件。

装好之后的开发循环与 §7 那张表**只差一行**：

| 改什么 | 正式形态下怎么生效 |
|---|---|
| 插件的 `swift/` | 存盘即热替换，什么都不用做 |
| node 半边 / 编排表 | 在仓库里跑一次 `./release`（换掉 App 里的镜像），⌘Q 再打开一次让自举重拷 |
| 壳源码 | **没有自动路径**——正式形态不构建壳，跑一次 `./release` |

最后一条是有意的：发布的 App 是 Developer ID 签名并公证过的，自己 `xcodebuild`
重建自己产出的是 ad-hoc 签名，**当场把自己降级成"来路不明"**，Hardened Runtime 与
entitlements 随之对不上，所有热插件突然装载失败——而症状完全不像签名问题。
所以正式形态下"要不要构建"这个开关根本不存在，不是默认关掉：
**构建那一整套代码就不随包分发**（住在 `clam-app/host-build/`，`files` 白名单只收 `lib/`），
判据是"那个模块 `import` 得到吗"，而不是任何旋钮。

---

## 延伸阅读

- [`architecture.md`](architecture.md) —— 壳与插件的运行时架构。
- [`connection.md`](connection.md) —— 壳连着哪个后端，以及托管后端的生命周期。
- [`../extend/plugin-author-guide.md`](../extend/plugin-author-guide.md) §7 ——
  外部插件怎么接进编排（不必改伞包）。
- [`../extend/contracts.md`](../extend/contracts.md) —— 跨插件字符串约定的汇总索引。
- `surfclam/cordis.patch.yml` —— 编排表本体，注释比这篇细。
- `clam-bridge/lib/plugin.js` —— `createSwiftPlugin` 与 `CommandDeclaration` 的权威。
