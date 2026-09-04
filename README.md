# Surf

<p>
  <a href="README.zh.md"><img src="https://img.shields.io/badge/%E4%B8%AD%E6%96%87%E8%AF%B4%E6%98%8E-%E7%82%B9%E8%BF%99%E9%87%8C-0E8A94?style=for-the-badge" alt="中文说明"></a>
  <a href="https://github.com/wbopan/surf/releases/latest"><img src="https://img.shields.io/github/v/release/wbopan/surf?style=for-the-badge&label=Download&color=555" alt="Download"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-555?style=for-the-badge" alt="MIT"></a>
</p>

[dsh](https://github.com/deepseek-ai/deepseek-harness) (DeepSeek Harness) is DeepSeek's coding assistant. It ships a web UI
that opens in a browser. Surf puts that UI in a Mac window and adds a native session sidebar, system notifications,
a standalone settings window, and a full menu bar with keyboard shortcuts. Sessions, models, and tools still run on
the dsh side.

<img src="site/screen-native@2x.jpg" width="820" alt="The Surf window: native session sidebar on the left, the dsh UI on the right">

Website: <https://wbopan.github.io/surf/>

## Install

Requires macOS 27 or later, and dsh:

```sh
npm i -g @deepseek-ai/dsh@0.1.1-rc.2
```

Then download `Surf-<version>.dmg` from [Releases](https://github.com/wbopan/surf/releases/latest), drag Surf into
Applications, and open it. The app starts its own dsh backend and stops it on ⌘Q. No Xcode, no other build tools.

The dsh version is pinned. dsh is a developer preview with announced breaking changes; on another version the UI may
misalign or lose a piece. Verified against `0.1.1-rc.2`.

Connection preferences, the diagnostics panel, log locations, upgrading and uninstalling are covered in
[`docs/use/install.md`](docs/use/install.md) (Chinese).

## What it is not

Surf is a shell for dsh. Features, data, and settings live on the dsh side; the native layer only projects them.
Theme, UI language, and session grouping follow dsh.

Anything dsh has not implemented, Surf does not fill in, and it does not work around dsh's public API to do so.
Known gaps are listed in [`docs/internals/dsh-upstream-gaps.md`](docs/internals/dsh-upstream-gaps.md).

## Develop

Prerequisites: macOS 27+, full Xcode (`xcodebuild` needs it; Command Line Tools are not enough),
Node `^22.19.0 || >=24.0.0`, and xcodegen (`brew install xcodegen`, or let `./dev` copy one from PATH).

Clone anywhere and run one line:

```sh
./dev              # install into a profile and run dsh in the foreground, port chosen by the OS
./dev --port 3080  # fixed port
```

`./dev` is idempotent. The first run builds the shell; later runs start in seconds when the source is unchanged.
If no window appears, read the terminal: the lines starting with `surf-app:` say where it stopped.

To make the app double-clickable on this machine:

```sh
./release             # install the Release shell into /Applications and open it once
./release --status    # state of the backend and the app
./release --uninstall # remove the app; sessions and settings stay
```

Changes fall into three loops, two orders of magnitude apart:

| Change | How it takes effect | Time |
|---|---|---|
| A plugin's `swift/` | Save the file. The bridge notices, the shell recompiles, the generation is hot-swapped | 1–3 s, nothing restarts |
| A plugin's `lib/client.js` | Browser-side HMR reloads it | seconds |
| A plugin's `lib/*.js`, `package.json`, the orchestration table | Restart dsh (dsh disables node-side HMR under the web bundle) | seconds |
| Shell source `surf-app/host/` | surf-app watches it, rebuilds in the background, the window offers "restart to apply" | 2 s rebuild + restart |

The first row is the point of the project. Save `surf-sidebar/swift/SidebarView.swift` and the sidebar changes a
second or two later with selection and list contents intact, because the data plane lives in a vault that survives
generations; only the code is replaced. A compile error is printed to the dsh terminal with file and line, the old
generation stays in service, and the UI neither changes nor crashes. The measured results and hard constraints are in
[`docs/internals/architecture.md`](docs/internals/architecture.md) §7–8 and
[`docs/extend/native-abi.md`](docs/extend/native-abi.md).

Tests:

```sh
node --test surf-sidebar/test/*.test.js surf-memory/test/*.test.js
```

## Write a plugin

Plugin authors do not need to read this repository's source. A plugin with a Swift payload usually has a node half of
a few lines:

```js
import { createSwiftPlugin } from "@wenbo/surf-bridge/plugin";

export default createSwiftPlugin({
  name: "surf-sidebar",
  provide: "surf-sidebar",      // empty marker service for downstream inject
  inject: ["surf-layout"],      // cordis: do not mount me until layout is up
  swiftDir: new URL("../swift/", import.meta.url),
  swiftDeps: ["surf-layout"],   // bridge: recompile me when upstream changes generation
});
```

The Swift half exports one C entry point and fills a slot once it has `host`:

```swift
@_cdecl("surf_plugin_entry")
public func surf_plugin_entry() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(SidebarPlugin()).toOpaque()
}

final class SidebarPlugin: SurfPlugin {
    func activate(host: SurfHost) -> AnyObject? {
        let handle = SurfPluginHandle()
        host.register(slot: "sidebar") { AnyView(SidebarView(...)) }.kept(by: handle)
        return handle   // when the shell lets go, this generation retires; registrations and subscriptions go with it
    }
}
```

Keeping the data plane in the node half is deliberate: the shell is frozen in the app bundle, the node half updates
with the package. The full guide is [`docs/extend/plugin-author-guide.md`](docs/extend/plugin-author-guide.md).

## What is in the repository

A set of [cordis](https://github.com/shigma/cordis) plugins plus a very thin macOS shell. The shell's source, build,
and launch all live in one ordinary plugin (`surf-app`); there is no privileged directory.

```
surf/          umbrella bundle @wenbo/surf: the repository's only orchestration table (cordis.patch.yml
                   decides which plugins, in what order, with what config), plus the launcher bin/surf.js
surf-app/          the plugin whose payload is the shell: build + write the endpoint discovery file + launch the app
  host/            Xcode project (project.yml / Sources/ / scripts/)
  host-build/      build capability, not shipped, so the released app structurally cannot build itself
surf-bridge/       the only privileged plugin: Swift payload registry + /surf/bridge WS + watches swift/ directories
surf-layout/       owns the root slot: split view, WebView layout, the sidebar slot, an open toolbar contribution slot
surf-sidebar/      owns the sidebar slot: native session sidebar. Data plane in node, Swift only draws
surf-notify/       desktop notifications: no slot, no UI; absent means no notifications. Also the single source of
                   truth for "what is waiting for you", feeding session state to the sidebar
surf-settings/     native settings window: no slot, its own window; the first four tabs mirror dsh's web settings
surf-nativeify/    makes the dsh web UI feel native: mostly CSS in the client half, plus a thin Swift payload that
                   keeps the native side in step with dsh's ui-theme
surf-memory/       persistent memory across sessions: one directory of markdown, index injected each step, bodies on
                   demand. Pure node, zero macOS dependency; runs on any machine with dsh
tools/             cross-package dev tools. A tool that serves one plugin belongs to that plugin
docs/              documentation in four layers by audience, see below
site/              the website, static, no build step
```

## Documentation

The docs are written in Chinese.

| You are | Start at |
|---|---|
| a user | [`docs/use/install.md`](docs/use/install.md) |
| a plugin author | [`docs/extend/plugin-author-guide.md`](docs/extend/plugin-author-guide.md) → [`docs/extend/contracts.md`](docs/extend/contracts.md) |
| changing this repository | [`docs/internals/`](docs/internals/) |

The full index with a one-line summary per document is [`docs/README.md`](docs/README.md).

## License

[MIT](LICENSE).
