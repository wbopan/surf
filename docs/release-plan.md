# 首次公开发布计划：v0.1.0

把 surf 从「私有仓库 + 本机能装」变成「公开仓库 + 任何一台 macOS 27 都能下载安装」。
四个交付物：**公开的 GitHub 仓库、面向外人的 README、挂着公证过 dmg 的 GitHub Release、
上线的官网**。签名与公证的机制本身已经打通（见 [`internals/distribution.md`](internals/distribution.md)），
这份计划不再讨论它们怎么做，只讨论**还差哪些、按什么顺序、怎么验收**。

---

## 0. 现状盘点（2026-09-04）

### 已到位

| 项 | 证据 |
|---|---|
| 分发流水线 | `surf-app/host/scripts/release-dmg.sh`：Developer ID + Hardened Runtime → 验 → 公证 app → staple → dmg → 签 → 公证 dmg → staple。2026-08-30 实跑，两次公证均 Accepted |
| 公证凭据 | notarytool keychain profile **`surfclam`** 仍有效（`notarytool history` 今天能取到记录） |
| 签名身份 | 钥匙串里恰好一条 `Developer ID Application: Wenbo Pan (HJDT6NYKJC)`，脚本能自动选中 |
| 打包工具 | `dmgbuild`（uv tool）与 `surf-app/host/tools/xcodegen` 都在位 |
| 用户文档 | `docs/use/install.md` 已按最终用户口吻写完：要求、三步安装、首次打开、连接、诊断、升级、卸载 |
| 官网 | `site/` 纯静态，英文 + 中文两页，无构建步骤 |
| 版本号 | `MARKETING_VERSION` 与九个 `package.json` 都是 `0.1.0`；dmg 文件名由 Info.plist 推出 `Surf-0.1.0.dmg` |
| dsh 钉版 | `0.1.1-rc.2`，恰好是 npm 的 `latest`（`next` 已到 `0.1.2-rc.1`，本次不跟） |

### 缺的

按「不补就不能发」到「不补也能发但难看」排序：

1. **没有 LICENSE 文件**，九个 `package.json` 都没有 `license` 字段。官网页脚 `[LICENCE]` 是占位。
2. **仓库是 private**，无 tag、无 Release、无 Pages。`https://github.com/wbopan/surf` 是 origin。
3. **官网 6 处 `href="#"`**（导航 logo、两个 Download、仓库、插件指南、LICENCE），中英两页各 6 处。
4. **官网四个模块名是提案不是实名**：`SurfUI` / `SurfKit` / `SurfSessions` / `SurfShell`，
   实际为 `SurfNativeify` / `SurfBridge` / `SurfSidebar` / 无对应包。`site/README.md` 自己已记下。
5. **官网侧边栏示意按重设计稿画**，而 HEAD 上「待处理」已从置顶分区改成「按状态」第三档
   （提交 `a2ccc76`）。示意与真机不一致。
6. **官网截图是真实会话**：`screen-native@2x.jpg` 底部露出 `/Users/wenbopan/Repos/surf` 一角
   （被输入框遮住大半），Dock、菜单栏第三方工具、模型名 `GLM-5.3` 全部入镜。
7. **README 是维护者视角**：「装」一节提到下载 dmg 却没有链接；没有截图；没有许可证；
   「热替换是怎么成立的」「兼容性」这些段落对第一次打开仓库的人太深。
8. **`docs/` 根下躺着三份已完成的计划**（`surf-rename-plan.md`、`surf-rename-anchors.md`、
   `sidebar-redesign-plan.md`），按约定应进 `docs/archive/` 并在 `docs/README.md` 登记。
9. **个人路径**：`docs/extend/dsh-wire-protocol.md` 三处示例响应带 `/Users/wenbopan/…`；
   `surf-memory/test/paths.test.js` 用它当字面量（测试无妨，但换成中性路径更干净）。
10. **`release-dmg.sh` 顶注仍引用「计划 §4.x」**，指的是已归档的 `distribution-plan.md`，
    应改指 `internals/distribution.md` 的对应节。
11. **Info.plist 没有 `NSHumanReadableCopyright`**，「关于」窗口版权行是空的。
12. **端到端验收欠一条**：在没有开发者证书、没装过本 App 的用户上，下载 dmg → 拖 → 双击 →
    Gatekeeper 首次打开。本机 keychain 会让一切显得正常（`distribution.md` §5.4）。
13. 没有 CHANGELOG / Release notes 底稿。

---

## 1. 决策

带 ★ 的三条要用户拍板，其余是默认值，不同意就改这一节。

| # | 决策 | 取值 | 理由 |
|---|---|---|---|
| D1 ★ | 许可证 | **MIT** | 上游 dsh 与 cordis 都是 MIT；仓库里没有 GPL 依赖；官网与 README 引用「MIT」一词最短 |
| D2 ★ | 官网托管 | **GitHub Pages，Actions 部署 `site/`**，地址 `https://wbopan.github.io/surf/` | Pages 的「分支目录」只认 `/` 或 `/docs`，`docs/` 已被文档占用；用 `actions/deploy-pages` 直接发 `site/`，仓库结构一字不动。自定义域名另议 |
| D3 ★ | 下载链接 | 官网与 README 一律指向 **`https://github.com/wbopan/surf/releases/latest`**（页面），不指某个 dmg 文件 | dmg 文件名带版本号，`releases/latest/download/<文件名>` 每版都要改链接；指页面一次写死。代价是多一次点击 |
| D4 | 版本与 tag | `0.1.0` / `v0.1.0`，`CURRENT_PROJECT_VERSION` 保持 `1` | 版本号已在九处对齐，不动 |
| D5 | 仓库可见性与元数据 | `wbopan/surf` 转 public；description、homepage（D2 地址）、topics（`macos` `swift` `deepseek` `dsh` `cordis` `plugins`） | |
| D6 | Release 资产 | 只有 `Surf-0.1.0.dmg`，notes 里附 SHA-256 | 不上传 zip（zip 不能 staple，见 `distribution.md` §5.4） |
| D7 | 官网截图 | **重拍**两张对照截图（web / native），干净用户、示例会话、Dock 只留系统 App | 第 6 条不是隐私事故，但 Dock 与菜单栏杂物让页面看着不像产品照 |
| D8 | 官网侧边栏示意 | 改成 HEAD 形态：「按状态」是筛选里的第三档，默认分组不置顶「待处理」 | 铁律 1：不制造与真机的显示偏差 |
| D9 | 不在本次做 | 自动更新（Sparkle）、CI 上构建发布、npm 发布 `@wenbo/*`、Homebrew cask、跟进 dsh `0.1.2` | 见 §5 |

---

## 2. 里程碑

依赖关系：**M1 → (M2 ∥ M3 ∥ M4) → M5 → M6**。M4 只依赖 M1 里改 Info.plist 那一项，
其余可以同时推进。

### M1 仓库卫生（半天）

1. 根目录加 `LICENSE`（MIT，版权人 `Wenbo Pan`，年份 2026）。
2. 九个 `package.json` 加 `"license": "MIT"`、`"repository": {"type":"git","url":"https://github.com/wbopan/surf.git","directory":"<pkg>"}`、
   `"homepage"`（D2 地址）。**别动 `version`、`files`、`exports`**。
3. `docs/surf-rename-plan.md`、`docs/surf-rename-anchors.md`、`docs/sidebar-redesign-plan.md`
   → `docs/archive/`，`docs/README.md` 的 archive 表各加一行。`site/README.md` 里指向
   `docs/sidebar-redesign-plan.md` 的引用跟着改路径。
4. `docs/extend/dsh-wire-protocol.md` 三处示例路径改成 `/Users/you/…`；
   `surf-memory/test/paths.test.js` 的字面量同样换掉（断言值一起换，跑一遍
   `node --test surf-memory/test/*.test.js`）。
5. `release-dmg.sh` 顶注与报错文案里的「计划 §x.y」改成 `docs/internals/distribution.md §x`。
   `--help` 输出跟着变。
6. `Info.plist` 加 `NSHumanReadableCopyright`：`© 2026 Wenbo Pan. MIT License.`。
   **这一步会触发壳全量重建**（Info.plist 进 source hash），放在 M4 之前做完。
7. `git grep -n "/Users/wenbopan"` 只剩 `docs/archive/` 里的历史原文时算完（档案不改）。

### M2 README 重写（半天）

面向「第一次打开仓库、不知道 dsh 是什么」的人。结构：

1. **一句话 + 一张截图**：surf 是什么。截图用 M3 重拍的 `screen-native@2x.jpg` 同源文件。
2. **安装**：要求（macOS 27、dsh 钉版）→ 三步 → 「下载」链接（D3）→ 指向 `docs/use/install.md`。
3. **它不是什么**：只是 dsh 的壳；不另建真相源；上游缺口如实报告。两三句。
4. **开发**：前置、`./dev`、三个开发循环那张表（保留，这是项目的卖点）。
5. **写插件**：现有那段代码样例保留。
6. **仓库里都有什么**：现有目录表保留。
7. **文档**：三行指路表保留。
8. **许可证**：MIT。

**删掉或下沉**：「热替换是怎么成立的」三条硬事实移到 `docs/extend/native-abi.md` 已有的位置
（那里本来就是权威，README 里只留一句话链接）；「兼容性」并入安装一节的钉版说明。
措辞按 [`site-copy-register`] 那套降调：不排比、不警句收尾、不自辩。
事实逐条从代码取，别抄旧 README 的形容词。

### M3 官网收口（一天）

1. 6 处 `href="#"`：logo → `/surf/`（Pages 站内）；两个 Download → D3；仓库 →
   `https://github.com/wbopan/surf`；插件指南 → `https://github.com/wbopan/surf/blob/main/docs/extend/plugin-author-guide.md`；
   LICENCE → `https://github.com/wbopan/surf/blob/main/LICENSE`，文案改 `MIT License`。中英两页同步。
2. 四个模块名改实名（第 4 条）。`SurfShell` 那一档（菜单与快捷键）改标 `SurfLayout · SurfApp`，
   或把那张卡的模块名去掉——两页一致即可。世代 hash 那几个装饰值随意。
3. 侧边栏示意改到 HEAD 形态（D8）：对照 `tools/shot.sh` 截的真机图逐项改
   `site/index.html` 366 行与 379 行附近那两块。
4. 重拍两张对照截图（D7）：同一会话、同一窗口位置，一张 Chrome 一张 Surf；用干净用户或
   至少清空 Dock 与菜单栏杂物；按 `site/README.md` 「数值从哪来」那节的裁切与 `sips` 参数出图。
5. 状态条那句 `It follows dsh 0.1.1-rc.2, and it does not update itself yet.` 保留，事实没变。
6. `.github/workflows/pages.yml`：`on: push: branches: [main]`，`paths: [site/**]`；
   `actions/upload-pages-artifact` 指 `site/`；`actions/deploy-pages`。
   仓库设置 Pages source = GitHub Actions（`gh api -X POST repos/wbopan/surf/pages -f build_type=workflow`）。
7. 本地 `python3 -m http.server -d site` 过一遍两页，`tools/site-shot.mjs` 逐面板截图核对。

### M4 构建发布产物（一小时，其中公证等待约五分钟）

```bash
surf-app/host/scripts/release-dmg.sh --clean --notarize-profile surfclam
```

产物 `surf-app/host/build-dist/Surf-0.1.0.dmg`。脚本自带的验收：`codesign -v --deep --strict`、
entitlements 两项、六个嵌套 dylib 的 Authority、`stapler validate` 两处、`spctl --assess` 报
`Notarized Developer ID`。额外记下：

```bash
shasum -a 256 surf-app/host/build-dist/Surf-0.1.0.dmg
```

**端到端验收**（第 12 条，不能省）：本机建一个标准用户 `surf-qa`（keychain 按用户隔离，
没有开发者证书也没装过 App），登录后用 Safari 从 GitHub Release 页下载 dmg → 拖进「应用程序」
→ 双击。要看到的是「从互联网下载的应用程序，确定要打开吗」而**不是**「已损坏」；打开后
⌥⌘D 里五个插件的来源全部是「bundle 预编译」、一次 swiftc 都没跑；`~/.dsh/profiles/surf/`
自举成功；后端由 App 拉起（这台用户上要先 `npm i -g @deepseek-ai/dsh@0.1.1-rc.2`）。
验完 `sysadminctl -deleteUser surf-qa`。

M4 与 M5 之间：因为要先有 Release 才能从 Release 页下载，端到端验收实际排在 M5 第 3 步之后、
公开仓库之前——Release 可以先建成 **draft**，draft 资产用登录了的浏览器能下载。

### M5 GitHub（一小时）

1. 仓库元数据：`gh repo edit wbopan/surf --description "…" --homepage https://wbopan.github.io/surf/ --add-topic …`。
2. `git tag -a v0.1.0 -m "v0.1.0"`，push tag。
3. `gh release create v0.1.0 surf-app/host/build-dist/Surf-0.1.0.dmg --draft --title "Surf 0.1.0" --notes-file <notes>`。
   Notes 底稿（`docs/release-notes/0.1.0.md`，新目录，此后每版一份）：
   - 要求：macOS 27、`npm i -g @deepseek-ai/dsh@0.1.1-rc.2`
   - 安装三步，指 `docs/use/install.md`
   - 有什么：原生会话边栏、设置窗口、桌面通知、跨会话记忆、原生感 CSS、Swift 插件热替换
   - 已知边界：无自动更新；dsh 钉版；部署目标 27.0
   - `SHA-256: <值>`
4. 端到端验收（M4 末段）。
5. `gh release edit v0.1.0 --draft=false`。
6. `gh repo edit wbopan/surf --visibility public --accept-visibility-change-consequences`。
   **这一步不可逆地公开 197 个提交的历史**，含提交者邮箱 `pixelwenbo@gmail.com`、`docs/archive/`
   里的旧名与本机路径。执行前由用户确认一次。
7. Pages 首次部署：push 到 main 触发 workflow，`gh run watch`，打开 D2 地址。

### M6 发布后核对（半小时）

- README 与官网上每个链接点一遍（下载、仓库、指南、LICENSE、Pages 站内锚点）。
- 从 Release 页下载 dmg，`shasum -a 256` 对上 notes 里的值；`spctl --assess --type open --context context:primary-signature -v` 报 accepted。
- `./release --status` 与 `./dev` 在主 worktree 上零回归（M1 改了 Info.plist 与 package.json）。
- 在 `docs/README.md` 登记 `release-notes/`；本计划移入 `docs/archive/`，执行日志留在文内。

---

## 3. 验收清单

| # | 检查 | 命令 / 方法 |
|---|---|---|
| A1 | 仓库无个人路径（archive 除外） | `git grep -n "/Users/wenbopan" -- ':!docs/archive'` 为空 |
| A2 | 九个包有 license 字段 | `for p in surf surf-*; do node -p "require('./$p/package.json').license"; done` 全 `MIT` |
| A3 | 测试过 | `node --test surf-sidebar/test/*.test.js surf-memory/test/*.test.js` |
| A4 | dmg 公证 | 脚本末尾 `spctl` 行含 `Notarized Developer ID` |
| A5 | 零编译启动 | 干净用户 ⌥⌘D：五个插件来源皆 `prebuilt` |
| A6 | Gatekeeper 首次打开 | 干净用户看到「确定要打开」，不是「已损坏」 |
| A7 | 官网无占位 | `grep -c 'href="#"' site/index.html site/index.zh.html` 皆 0 |
| A8 | 官网模块名与代码一致 | `grep -n "SurfUI\|SurfKit\|SurfSessions\|SurfShell" site/*.html` 为空 |
| A9 | Pages 可达 | `curl -sI https://wbopan.github.io/surf/ \| head -1` 为 200 |
| A10 | Release 可达且资产对 | `gh release view v0.1.0 --json assets` 恰一个 dmg；下载后 SHA-256 对上 |
| A11 | 开发形态零回归 | `./dev` 起来、Swift 存盘热替换仍 1~3s |

---

## 4. 风险

| 风险 | 应对 |
|---|---|
| 公证凭据 `surfclam` 过期或 Apple 侧卡 In Progress | `notarytool history` 先探一次；脚本 `--timeout 2h`；卡住就等，别重复提交 |
| 用户机器上 dsh 不在登录 shell 的 PATH（`.zshrc` 配的 node） | 已在 `install.md` 症状表首行；Release notes 再提一句 |
| dsh 升到 `0.1.2` 后 CSS 选择器断 | 本次钉 `0.1.1-rc.2` 不跟；官网状态条与 README 明说钉版 |
| 公开仓库后有人按 README 跑 `./dev` 缺 xcodegen | `surf/bin/surf.js` 的 `ensureXcodegen` 已给三条补法；README 开发节点一句 `brew install xcodegen` |
| Pages 相对路径：站点挂在 `/surf/` 子路径 | `site/` 里资源引用全是相对路径（`surf.png`、`styles.css`），logo 链接用 `./`；本地用 `http.server` 在子目录下模拟一次 |

---

## 5. 明确不做（本次）

- **自动更新（Sparkle）**：要 EdDSA 密钥管理、appcast 托管、`sign_update` 排在 staple 之后
  （`archive/distribution-plan.md` §8 已记）。0.1.0 用户靠重新下载，`install.md` 已写明。
- **CI 上构建发布**：Developer ID 私钥与公证凭据要进 GitHub Secrets，且 runner 得有 Xcode 27
  与 macOS 27。本机跑一次 10 分钟，先不搬。
- **npm 发布 `@wenbo/*`**：`npx` 路径已删，包只作为 App 载荷分发，发 npm 没有消费者。
- **Homebrew cask**：需要稳定下载 URL + sha256，有了 Release 之后随时可加，单独一小步。
- **跟进 dsh `0.1.2-rc.1`**：那是另一轮兼容性工作。

---

## 6. 执行日志

（每完成一个里程碑在此追加一行：日期、做了什么、验收结果、偏离计划之处。）

- 2026-09-04 计划写成。盘点见 §0，三条待拍板决策见 §1（D1 许可证、D2 托管、D3 下载链接）。
