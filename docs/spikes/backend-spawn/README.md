# spike：托管后端的进程组与信号

`docs/archive/surf-connection-plan.md` §5 的托管形态要壳自己 spawn 一个后端并在 ⌘Q 时
杀干净。这台验证台只回答一个问题：**信号送得到吗**。

```sh
docs/spikes/backend-spawn/run.sh                  # 默认跑 fake-dev.sh（两层）
docs/spikes/backend-spawn/run.sh 'exec sleep 30'  # 换任意命令
```

`run.sh` 把壳里那份 `surf-app/host/Sources/Native/ManagedProcess.swift` **原文件**
编进来（不抄一份，抄了就会和真实现漂移），跑六条断言。一次通过的输出：

```
断言① 子进程 pgid=79252 自己的 pid=79252 壳 pgid=79233 ✅
断言② 组内成员：79252 79275 79288 ✅（外层 + 内层都在）
断言③ 收尸：signal 15（体面） ✅
断言④ 内层收到 TERM：是 ✅
断言⑤ 组内残留：无 ✅
断言⑥ 壳自己还活着 ✅（killpg 没波及本组）
```

`fake-dev.sh` / `fake-dsh.sh` 模拟的是真身的形状：`./dev` 是
`node → spawnSync(dsh)` **两层**，外层阻塞在 wait 里，真正占着端口的是内层。

## 三条实测结论（2026-08-29，macOS 26）

1. **`Foundation.Process` 做不了这件事**。它 posix_spawn 时不设
   `POSIX_SPAWN_SETPGROUP`，子进程于是继承**壳自己**的进程组。那种形态下两条路
   都是死的：`killpg` 会把壳一起杀；只 `kill` 子进程又漏掉孙子进程。
2. **只 TERM 外层 = 静默的孤儿**。实测：外层 zsh 死了，内层立刻被 init 收养
   （`PPID 1`）继续跑、继续占端口，而壳这边没有任何异常迹象。
   下次启动的查重会看见一个"健康的 isOwn 端点"，于是干脆不 spawn——
   症状是"托管好像没生效"，原因在上一次退出。
3. **正路是 posix_spawn + `posix_spawnattr_setpgroup(&attr, 0)`**（子进程自成组、
   自己当组长），之后 `killpg(pid, SIGTERM)` 一发覆盖整棵子树。
   macOS **没有 `setsid(1)`**（那是 Linux 的），借不到外部工具。

顺带一条：`zsh -lc` 读 `.zshenv` / `.zprofile` / `.zlogin`，**不读 `.zshrc`**
（非交互）。本机 homebrew 装的 node/dsh 在 `.zprofile` 里，解得出来；
只在 `.zshrc` 里配 nvm 的机器解不出来，那时托管会如实报"未找到后端程序"。
