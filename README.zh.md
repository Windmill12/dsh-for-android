# AndroidDSH

[English](README.md) | **中文**

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`，基于 Cordis 的插件化 agent runtime）搬到 Android 上，**跑的是 DSH 本体与它原生的 Web 界面**，不是另写一套 Android UI。

> **当前状态：真机（Honor MAG-AN00 / arm64 / Android 16）上端到端跑通。**
> APK 启动后会自动拉起内嵌的 Node + `dsh --profile web`，界面就是 `dsh web` 的原生
> Web GUI（会话、轨迹、工具调用树、右侧栏、技能、目标……全部可用），agent 能在
> 设备本地执行 bash 命令。

```
$ ./scripts/install.sh phone        # 构建 + 安装到真机
$ ./scripts/install.sh emulator     # 构建 + 安装到模拟器
```

### 直接安装现成 APK

[Releases](https://github.com/Windmill12/dsh-for-android/releases) 里的两个 APK 都是
**自包含**的——Node 运行时、DSH 依赖树、bash、ripgrep、CPython 全在包里，不需要再装
任何东西。

| 文件 | 适用 |
| --- | --- |
| `AndroidDSH-0.2.0-arm64-v8a.apk` | **真机**（绝大多数手机） |
| `AndroidDSH-0.2.0-x86_64.apk` | Android 模拟器（x86_64 镜像） |

```bash
adb install -r AndroidDSH-0.2.0-arm64-v8a.apk
```

也可以把 APK 拷到手机上直接点开安装（需要允许"安装未知来源应用"）。下载后可用附带的
`SHA256SUMS.txt` 校验。

要求 Android 8.0（API 26）及以上，并预留约 600MB 空间（安装 + 首启解压运行时）。
首启会申请"所有文件访问"权限，好让 agent 在 `/sdcard/Documents/DSH` 里工作；拒绝也不
影响功能，app 会退回自己的私有目录。

> 发行的 APK 是 **debug 签名**。后续版本可以直接覆盖安装；换成别的 key 签的包必须先
> 卸载。

桌面图标用的是 DSH 官方标识（取自 `dsh-web-frontend/dist/favicon.svg` 的那条 path）
配品牌蓝 `#4176e6`（从运行中的界面读到的 `--dsw-static-deepseek-500`），做成自适应
图标，另外给通知栏留了一版 24dp 的白色剪影。

| 桌面 | 空状态 | 会话 | 设置 |
| --- | --- | --- | --- |
| ![桌面图标](docs/screenshot-launcher.png) | ![空状态](docs/screenshot-phone-home.png) | ![会话](docs/screenshot-phone.png) | ![设置](docs/screenshot-settings.png) |


## 一、整体架构

```
┌─ Android app (com.androiddsh) ─────────────────────────────────────────┐
│                                                                        │
│  MainActivity ──── Compose ──── WebView ◄── http://127.0.0.1:7300/?token=…
│       │                              (DSH 原生 Web 前端)                 │
│       │ 观察 StateFlow                                                  │
│  DshServerService（前台服务，保活 + 常驻通知）                            │
│       │                                                                │
│  DshServer（单例）── ProcessBuilder ──► node --expose-internals …       │
│                                          bin.js --profile web --no-open │
│                                                                        │
│  assets/dsh-runtime.pkg   → filesDir/rt         (DSH 的 node_modules)  │
│  jniLibs/libnode.so       → nativeLibraryDir    (Node 二进制)          │
│  jniLibs/libbash.so       → nativeLibraryDir    (静态 bash 5.2)        │
│  jniLibs/libripgrep.so    → nativeLibraryDir    (ripgrep，glob/grep 后端)│
│  jniLibs/libpython3.so    → nativeLibraryDir    (CPython 3.13 解释器)   │
│  assets/python-runtime.pkg→ filesDir/python     (Python 标准库)         │
│  filesDir/home            → DSH 的 $HOME（profile / session / 凭证）    │
│  filesDir/bin             → node / bash / rg / python3 的符号链接       │
│  /sdcard/Documents/DSH    → agent 的工作目录（文件管理器直接可见）      │
└────────────────────────────────────────────────────────────────────────┘
```

为什么界面是 WebView 而不是 Compose 重写：DSH 的 UI 本身就是一套约 60 个 client
插件的 Web 前端（`dsh-web-frontend` + `dsh-web-app`），用 Compose 复刻等于把整个
前端重做一遍，而且会永远落后于上游。直接跑 `dsh --profile web` 并把它喂给
WebView，拿到的是**每个版本都和桌面端一致**的原生界面。

### 工作目录：`/sdcard/Documents/DSH`

DSH 用子进程的 `process.cwd()` 当新会话的默认 `workspaceRoot`，所以 app 直接把
node 的 cwd 设成 `/sdcard/Documents/DSH` —— 文件管理器、USB/MTP、云盘同步都能
立刻看到 agent 产出的文件。

这条路**必须**走 `MANAGE_EXTERNAL_STORAGE`（"所有文件访问"）：SAF / MediaStore
交给应用的是 Content URI，对内嵌的 node / bash 子进程毫无意义，只有真实文件
路径可用。没有权限时 app 会自动退回零权限的
`Android/data/com.androiddsh/files/workspace`，功能不受影响，设置页里有"去授权"
按钮，授权回来会自动重启到公开目录。

配套的两点：

- 首装会弹一次说明，也可以在"设置 → 工作目录 → 去授权"里开。
- DSH 的目录选择器在 Android 上解析成**网页版服务端目录浏览器**（原生选择器只有
  darwin/win32/linux 有），它默认从 `os.homedir()` 起步 —— 也就是
  `/data/user/0/<pkg>/files/home`，要选到公开目录得点很多层。所以
  `patch-dsh-android.py` 的 `patch_picker_home()` 让它优先读 `DSH_PICKER_HOME`
  （app 传的就是工作目录），于是第一次"选择工作区"直接就在
  `/sdcard/Documents/DSH`，一按「打开」即可。

## 二、Android 上踩到的坑（都已解决）

### 1. `link(2)` 被 SELinux 全局禁止

见 `scripts/patch-dsh-android.py` 的 `patch_session/attachment/fs_local`。
DSH 有 4 处 `fs.link()` 做「独占发布」，Android 上直接 `EACCES`（app 私有目录
也一样）。按语义替换成 `open(to,"wx")` + `rename`（发布临时文件）或 + 复制
（发布不可变别名）。无竞态风险：DSH 在这些路径前已持有 flock 排他锁。

### 2. `--expose-internals` 不能省

web profile 会挂载 HMR 插件，缺少该 flag 时启动直接失败：

```
failed to apply loader entry (@deepseek-ai/cordis-plugin-hmr):
--expose-internals is required for HMR service
```

`dsh` 自己启动时并没有带这个 flag，所以在 Android 上必须由 app 显式传给 node。
见 `DshRuntime.webCommand()`。

### 3. 沙箱后端不存在 → 所有 bash 调用都被拒

Android 内核既没有 bubblewrap 也没有 Landlock，而 `dsh-base` 默认
`sandbox-policy.mode = workspace-write`，于是 `tool-bash` 直接报：

```
sandbox mode "workspace-write" is requested but no sandbox backend is usable
on this host; refusing to run the command unconfined.
```

修法不用改代码：DSH 自己提供了 `DSH_PERMISSION_MODE` 这个 seam（同时决定
sandbox 模式与 approval 策略）。app 把它设成 `danger-full-access`，
`SandboxBashExecutor.run()` 就会走非沙箱分支（`dsh-bash-sandbox` 里
`mode === "danger-full-access"` 的那一行）。

### 4. Android 没有 bash —— 自带一个

`tool-bash` 的执行器硬编码 `spawn("bash", ["-c", cmd])`。Android 只有
`/system/bin/sh`(mksh)，且 mksh 不支持 `pipefail`、数组、`${v^^}` 等，agent
写的命令会频繁失败。

- `scripts/build-bash-android.sh` 用 NDK 交叉编译 **GNU bash 5.2.37**（静态、
  单文件 1.6MB），产物 `.toolchain/build/bash-android-<arch>/bash`。
- Android 只允许从 `nativeLibraryDir` 执行文件，而 AGP 只把 `*.so` 打进
  `lib/<abi>/`，所以它随 jniLibs 以 **`libbash.so`** 的名义分发，运行时落在
  `<nativeLibraryDir>/libbash.so`。
- 那个绝对路径通过 `DSH_BASH_PATH` 环境变量传给 DSH：`patch-dsh-android.py`
  的 `patch_bash_path()` 把 `dsh-bash-local` 与 `dsh-bash-sandbox` **两处**
  硬编码的 `"bash"` 换成 `process.env.DSH_BASH_PATH ?? "bash"`
  （没有该变量时行为与上游完全一致）。两处都要改：非沙箱模式走父类
  `LocalBashExecutor.run()`，沙箱模式走 `SandboxBashExecutor.confine()`，
  只改一处会在某些模式下继续 `spawn bash ENOENT`。

### 5. WebView 里 `vh` / `dvh` 全部解析成 0px（最隐蔽的一个）

实测 Android WebView 133.0.6943.137（模拟器与真机一致）：

| 表达式 | 结果 |
| --- | --- |
| `window.innerHeight` | 712 ✅ |
| `visualViewport.height` | 712.4 ✅ |
| `position:fixed; inset:0` 的高度 | 712 ✅ |
| `width:100vw` | 366 ✅ |
| **`height:100vh`** | **0px** ❌ |
| **`html{height:100%}`（ICB）** | **0px** ❌ |

这不是 DSH 的锅——`<style>html,body{height:100%}</style><div style="height:100vh">`
这样一张空白页在该 WebView 里同样是 0。`useWideViewPort` /
`loadWithOverviewMode` 各种组合都无效。

后果：DSH 前端那条 `html,body,#root{height:100%}` 一路塌成 0，整个界面只剩一个
`position:fixed` 的弹窗遮罩，看起来就是**白屏 + 一个灰色遮罩**。前端另有 13 个
文件用 `vh`（欢迎弹窗的 `max-height`、下拉菜单、卡片、代码查看器、右侧面板）。

修法见 `DshWebView.kt` 里的 `VIEWPORT_SHIM_JS`：注入一段脚本，**先探测** vh 是否
坏掉（好设备完全不接管），坏掉时做两件事——

1. 把 `html` / `body` / `#root` 的高度钉成 `innerHeight` 像素；
2. 遍历所有样式表，把 `n vh` 改写成 `calc(var(--dsh-vh) * n / 100)`，
   `--dsh-vh` 由同一段脚本按 `innerHeight` 维护。

配合 `MutationObserver`（客户端插件的样式是运行时注入 `<style>` 的）与
`resize` / `visualViewport.resize`（软键盘、旋转）保持同步。

### 6. 软键盘会盖住输入框

targetSdk 35+ 强制 edge-to-edge，窗口不再被输入法顶起。修法：
`android:windowSoftInputMode="adjustResize"` + Compose 侧 `Modifier.imePadding()`。

### 7. `glob` / `grep` 的后端 ripgrep 在 Android 上没有

`glob` / `grep` 由 `dsh-tool-fs-search` 驱动，它按两条路找 ripgrep 二进制，
Android 上**两条都不通**：

1. `` `${process.execPath}-rg` `` 这个 sidecar —— 只在一处 `"pkg" in process`
   的分支里才用（单文件运行时专用），而且 AGP 只把 jniLibs 里的 `*.so` 打进
   `lib/<abi>/`：我实测放一个 `libnode.so-rg` 进 jniLibs，它会被**静默丢掉**，
   APK 里根本没有这个文件；
2. `@vscode/ripgrep` 平台包 —— 只有 linux/mac/win 的，没有 Android。

症状是 `glob could not start its search command (ripgrep launch failed)`。

修法沿用 bash 那套：`scripts/build-ripgrep-android.sh` 交叉编译 **ripgrep 15.2.0**
（Rust 1.98.1，`--features pcre2`，PCRE2 10.45 静态链进去），以 `libripgrep.so`
的名义分发，再由 `patch-dsh-android.py` 的 `patch_rg_path()` 读 `DSH_RG_PATH`
指向它。实测 `rg --version` 报 `features:+pcre2`，`-P` 后向断言可用。

### 8. 顺带：`python3`

`scripts/build-python-android.sh` 交叉编译 **CPython 3.13.15**（`--disable-shared`
的 PIE 可执行文件，`readelf -d` 只有 `libdl/libz/libm/liblog/libc`；OpenSSL 3.0.16、
libffi、liblzma、libbz2、sqlite 3.46.1、readline 8.2、ncurses 6.5 全部静态吸收进
各扩展模块）。解释器以 `libpython3.so` 分发，标准库（含 58 个 `lib-dynload/*.so`）
走 `assets/python-runtime.pkg` 解到 `filesDir/python`，用 `PYTHONHOME` 指过去。

实测可用：`python3 -m pip`(26.2.1)、`sqlite3`、`ssl`、`hashlib`、`ctypes`、
`zlib`、`lzma`、`bz2`、`readline`、`socket`、`threading`、`subprocess`、
`multiprocessing.Process`(fork)。

已知做不到的两点，都是 Android 平台的硬限制，不是构建问题：

- `_posixshmem` 缺失 —— 设备上的 `libc.so` 根本没有 `shm_open`；
- `multiprocessing.Pool` / `Lock` / `Semaphore` 报 `ENOSYS` —— Android 内核不支持
  POSIX 具名信号量。`Process` / `fork` 是好的。

14 个 bionic 交叉编译坑（`ac_cv_kthread` 污染 CC、bionic 把 `getrandom` 藏在
API 28 后面、OpenSSL `-static` 隐含 `no-threads`、readline 8.2 不再自带 termcap、
`LDSHARED` 不带 `LIBS` 导致 `_sqlite3.so` 留下未定义符号、ctypes 在 Android 上
假定 libpython 是共享库……）都写在 `scripts/build-python-android.sh` 的头部注释里。

### 9. DSH 0.2.0 新增的纯预编译依赖（`node-addon-require-builtin`）

0.2.0 起 `dsh-app-boot` 在启动最早期就 `require("node-addon-require-builtin")`，
用来拿 Node 的 internal 模块。这个包**只发预编译产物**：没有 `src/`、没有
`binding.gyp`，npm 上的可选包也只有 darwin / linux / win32 九种，**没有 android**。
它的 loader 三条路全落空，于是直接 fatal：

```
dsh: host preparation failed: No usable native binding found
     for node-addon-require-builtin-android-arm64 (auto)
```

但那条"可选包"路径走的是普通 `require()`，而 loader 对 binding 的全部要求只有
`requireBuiltin` / `isAllowedInternalId` / `getNativeBindingInfo` 三个函数，
且后者返回的 `{mode, product, backend, abi}` 里 `product` 必须是 `require-builtin`。
**也就是说一个纯 JS 包就能顶替** —— 见 `prepare-dsh-android.sh` 的
`step_require_builtin()`，它会生成 `node-addon-require-builtin-android-{arm64,x64}`。

能这么干是因为我们本来就带 `--expose-internals` 启动（坑 #2）：带着这个 flag 时
`require("internal/modules/esm/loader")` 在普通 CJS 模块里就是通的，原 addon 要
"绕过 flag 拿 internal"的那件事，由 flag 本身完成了，shim 只负责转发。
不编译真 C++ 是有意的：那要在 C++ 里接 Node 的 internal binding 表，实现成本高、
还随 Node 版本漂移，而在我们这个配置下它提供不了任何额外能力。

### 10. 设置页在窄屏下被挤成一列字

DSH 的 Web 前端**没有任何宽度断点**。设置浮层是"188px 左导航 + 右内容"的固定
两栏，在 366 CSS px 的手机模式下内容列只剩约 130px，每个字都得竖着排。

两层修法：

- **宽屏模式真正加宽布局视口**（`applyViewportWidth`）。注意**不能用 CSS `zoom`**：
  Blink 把 `position:fixed` 元素的包含块算成可见视口宽度，zoom 只把结果等比缩小，
  所以 zoom 版本让固定定位的设置浮层**反而更挤**（内容列 130px → 81px）。正确做法
  是改 `<meta viewport>` 成 `width=720`，配合 `loadWithOverviewMode` 让 Chromium
  整页缩到屏幕宽度（实测 `visualViewport.scale = 0.509`，内容列 484px）。
- **窄屏兜底 CSS**：`@media (max-width: 700px)` 下把设置导航改成横向标签条，内容
  吃满整宽。选择器全走语义/结构（`[role="dialog"][aria-modal="true"]:has(> nav)`），
  一个 CSS module 的哈希类名都不依赖。

### 11. 终端面板：默认 shell 是 mksh，且 app 私有目录禁止 exec

DSH 的右侧栏自带终端（`dsh-api-terminal-controller` + `ui-sidebar-terminal`），
在 Android 上要迈两道坎：

**第一道：shell 选择。** `dsh-subprocess-local.terminalEnvironment()` 的默认值是
`process.env.SHELL || userInfo().shell || "/bin/sh"`。Android 上 `userInfo()` 没有
shell 字段，`/bin/sh` 是 mksh —— 语法弱（无 pipefail / 数组 / `${v^^}`），而且不会
读我们的便捷命令。解法不用打补丁：把 `SHELL` 指到自带的 bash 即可。

**第二道：`~/.bashrc` 里的便捷命令。** 想给终端加 `pnpm` / `dsh` 命令，最直觉的做法
是在 `files/bin/` 放包装脚本 —— **但 Android 的 app 私有目录禁止 exec**：

```
$ /data/user/0/com.androiddsh/files/bin/t.sh
/system/bin/sh: bad interpreter: Permission denied   (exit 126)
```

只有指向 `nativeLibraryDir` 的符号链接能执行（那目录挂载时不带 noexec）。所以只能
用 shell 函数把命令指到 `node <js 入口>`，写在 `~/.bashrc`（bash 读）和 `~/.dshrc`
（mksh/toybox sh 通过 `$ENV` 读）里。

> 测这个坑时注意：用 `adb shell run-as <pkg> ...` 执行脚本会**通过**，因为那只切换
> uid、SELinux 域还是 `shell`，规则和 app 域（`untrusted_app`）不同。要验就得从 app
> 自己的进程里跑（比如让 agent 调 bash 工具）。

![终端](docs/screenshot-terminal.png)

### 12. 装插件：ANDROIDDSH_PNPM_ENTRY

DSH 装插件（界面上的「添加插件」、以及 `dsh plugin add`）都是把活儿交给 pnpm。
Android 上有两个障碍：

1. pnpm 的 bin 是脚本，**不能 exec**（见上一条）。
2. **pnpm 12 起已经是原生二进制**（`bin/pnpm.mjs` 只是个去下载二进制的壳），Android
   没有对应产物。所以随包发的是纯 JS 的 **pnpm 10.x**（`bin/pnpm.cjs`，解包后 23MB）。

解法是在 pnpm 的调用点上做转发：`execa(options.command ?? "pnpm", [...])` 改写成
`execa(...androidPnpmLaunchArgs(options, [...]))`，有 `ANDROIDDSH_PNPM_ENTRY` 时就用
`node <pnpm.cjs>`。这里有两点值得记：

- **必须同时覆盖两份实现**。服务端（`dsh-plugin-manager/lib/index.js`）和 CLI
  （同包的 `lib/types/operations.js`）各有一份、各 5 处 `execa`，只改服务端的话
  终端里跑 `dsh plugin ...` 会报 `dsh: pnpm was not found`（exit 127）。
- **`DSH_*` 变量传不进子进程**。DSH 起子进程时走 `scrubbedParentEnv()`，会把所有
  `DSH_*` 前缀的变量剥掉。服务端进程里是有的，但终端里的 shell 没有，所以
  `~/.bashrc` 里要再 `export ANDROIDDSH_PNPM_ENTRY` 一次。

**已知限制**：pnpm 10.34 把一部分子命令**转发给真正的 npm**
（`view` / `info` / `search` / `whoami` / `ping` …，见 dist 里的 `passThruToNpm`），
而我们没有 npm，所以这些命令静默 exit 1。

好消息是 **`add` / `install` / `remove` 不在转发列表里**，走 pnpm 原生实现 ——
实测在临时目录里 `pnpm add is-number` 全流程正常（resolved → downloaded → added，
exit 0），而装插件用的就是这个命令。受影响的是 DSH 安装前的
「注册表预查询」（`pnpm view`），它失败时 DSH 会当作"查不到"继续，不阻塞安装。
要彻底补齐的话，可以再随包发一份 npm 并给 pnpm 的 `runNpm` 做同样的转发。

### 14. pnpm 转发 npm：界面「添加插件」失败的真正原因

DSH 界面上的「添加插件」装不了，报：

```
无法获取插件信息: pnpm view exited with 1
```

这不是移植问题，而是 **pnpm 10.34 把一批子命令转发给真正的 npm**（`dist/pnpm.cjs`
里的 `passThruToNpm`：`view`/`info`/`search`/`whoami`/`ping`/`version` …）。Android
上没有 npm，`runNpm()` 去 spawn `npm` 就静默 exit 1。

修法两步：

1. **随包发一份 npm**（纯 JS，19MB，入口 `bin/npm-cli.js`）。
2. **改写 pnpm 的 `runNpm()`**，把 `npm` 换成 `node <npm-cli.js>`：

```js
const npmEntry = process.env.ANDROIDDSH_NPM_ENTRY;
const npm = npmEntry !== void 0 && npmEntry !== "" ? process.execPath : npmPath ?? "npm";
return runScriptSync(npm, npmEntry !== void 0 && npmEntry !== "" ? [npmEntry, ...args] : args, { … });
```

`add` / `install` / `remove` 本来就不在转发列表里（走 pnpm 原生实现），所以这次的
修复只影响查询类子命令 —— 但界面上的安装前查询正是靠它。

### 15. jsrun：让 `pnpm` 成为真正可执行的命令

有些工具是按 PATH 找 `pnpm` **可执行文件**的（dsh-market 就是：它 spawn
`pnpm --version`，失败就报「需要先配置 pnpm 环境」），而 shell 函数救不了它们。

但 app 私有目录禁止 exec（见第 11 条坑），「node + JS 入口」没法做成包装脚本。
所以仓库里加了 `native/jsrun.c` —— 一个几十行的启动器：

- 用 NDK 编成 `libpnpm.so` / `libpnpx.so` / `libnpm.so`，放进 jniLibs；
- `ensureExecShims()` 在 `files/bin/` 里做同名符号链接（符号链接指向
  nativeLibraryDir，所以能执行）；
- 启动器自己 `execv("…/libnode.so", [node, <JS 入口>, …原样参数])`。

node 的路径靠 `/proc/self/exe` 推出来（同目录的兄弟文件）；JS 入口先读环境变量
（`ANDROIDDSH_PNPM_ENTRY` 等），取不到再用编译期写死的兜底值。启动器在宿主上
跑不了，所以设计成尽量只依赖 bionic，编译后 8KB。

> 为什么一个命令编一份 `.so`：`/proc/self/exe` 给的是**符号链接解析之后**的目标，
> 分不出当初是以哪个名字被调用的。三份各 8KB，无所谓。

### 16. 两个「装完起不来」的坑

**坑 A：改运行时之后 RUNTIME_VERSION 必须涨。** app 用它判断要不要重新解压运行时。
有一次装了个坏包（版本 10 已标记解压），修好后**没涨版本号**又装了一遍 —— app 认为
不用重新解压，设备上还是那份坏的，于是「修好了却还是起不来」。改运行时内容后一定
要 `RUNTIME_VERSION += 1`。

**坑 B：在 staging 里跑 `npm install` 会清掉 Android 专有产物。** 为了加 npm 依赖跑
了一次 `npm install`，npm 把不在 `package.json` 里的「多余包」当垃圾清掉了：

```
node-addon-require-builtin-android-{arm64,x64}   ← require-builtin shim
@koromix/koffi-android-{arm64,x64}
@deepseek-ai/node-addon-system-android-{arm64,x64}
```

只有 node-pty 幸存（它写在自己的 `prebuilds/` 里）。缺了它们的表现是启动时报
`No usable native binding found for node-addon-require-builtin-android-arm64` ——
原因和现象离得很远。**加完依赖记得重跑 `prepare-dsh-android.sh` 的两个架构**，
`prepare-app-assets.sh` 现在也会硬校验这 8 个产物，缺任何一个直接报错退出。

### 13. 插件的兼容性闸门与安装流程

DSH 在装插件时会先读它的 `peerDependencies`，只要里面声明的 `@deepseek-ai/dsh-*`
范围**不覆盖当前运行时版本**，就直接拒绝并回滚：

```
dsh: installation rejected: Plugin dsh-archive-manager@1.1.1 is incompatible with
     dsh 0.2.0-rc.2: peerDependencies {"@deepseek-ai/dsh-agent":"^0.1.0-rc.6", ...}
dsh: restored package.json, pnpm-lock.yaml, and node_modules.
```

**这不是平台问题** —— pnpm 已经成功下载并装好了，是 DSH 主动撤销的。所以看到这句话
说明移植层完全正常。判断某个插件能不能用，就看它 peer 里有没有当前版本，例如
`@michengai/dsh-archive-manager@1.0.11` 把每个包都列成了
`0.1.2-rc.1 || … || 0.2.0-rc.1 || 0.2.0-rc.2`，所以能直接过闸。

实在要用声明不兼容的版本，DSH 留了逃生口（**会真的崩**，慎重）：

```sh
dsh plugin --profile web allow-version <包@版本> --dsh-version 0.2.0-rc.2 --accept-risk
```

**安装流程**（终端里操作，装完要重启）：

```sh
dsh plugin --profile web add <包名>     # 装
# 重启 app（让插件作为 profile bundle 生效）
dsh plugin --profile web remove <包名>  # 卸
dsh plugin --profile web version-exemptions   # 看已授予的豁免
```

装好后 profile 的 `package.json` 会长这样，插件被登记成 bundle：

```json
"dsh": { "profile": { "bundles": [
    "@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "@michengai/dsh-archive-manager"
], "patchReload": "live" } }
```

**宿主编译器里的坑**：`~/.dsh/profiles/node_modules` 是插件解析 `@deepseek-ai/dsh-*`
的地方（240 个包）。升级运行时后 DSH 会把它一并刷新，所以两边版本是一致的
（实测全是 0.2.0-rc.2）。但 web profile 自己的 `pnpm-workspace.yaml` 里写着
`autoInstallPeers: false`，所以装插件时 pnpm 会刷一堆 `✕ missing peer` 警告 ——
**那是正常的**，靠 profile 层的包解析，不影响功能。

实测可用的 0.2.0-rc.2 兼容插件（peer 范围明确覆盖 `0.2.0-rc.2`）：

| 插件 | 功能 |
| --- | --- |
| `@michengai/dsh-archive-manager` | 归档会话管理：按工作区分组、搜索标题与正文、批量恢复/删除、收藏、闲置整理（入口在**设置 → 归档会话**） |
| `@linxin666/dsh-session-archive` | 归档清单、批量归档/恢复、级联物理删除 |
| `dsh-session-steward` | 会话管家（自称 0.2.0 专线）：归档浏览清理 + 会话体检 |
| `dsh-chat-manager` | 会话历史管理：搜索归档、恢复、安全删除 |
| `dshmarket` | **可视化插件市场**：在 DSH 里浏览/搜索/一键安装社区插件 |

![归档会话插件](docs/screenshot-plugin-archive.png)

社区插件市场 `dsh-market`（`v1.66.8`）在真机上浏览 / 搜索 / 一键安装均正常：

![插件市场](docs/screenshot-plugin-market.png)

## 三、把它跑起来

### 构建

本仓库**只收源码**：预编译的运行时输入（`app/src/main/assets/*.pkg` 与
`app/src/main/jniLibs/`，合计约 398MB）是构建产物，故意不入库。想直接装来用请从
[Releases 页面](https://github.com/Windmill12/dsh-for-android/releases) 下载现成 APK
（已自包含运行时，装完即用）；想自己构建就按下面的步骤走一遍。

工具链全部落在工作区的 `.toolchain/`（约 26GB，`.gitignore` 已排除），**不依赖系统包管理器**。
需要 Linux x86_64 宿主、约 40GB 空闲磁盘，以及耐心——首次全量构建以小时计，
大头是两个架构的 Node 交叉编译。

```bash
source scripts/env.sh

# 1) 工具链（一次性）
./scripts/bootstrap-toolchain.sh
./scripts/install-sdk-packages.sh

# 2) 交叉编译自带的可执行文件（每个脚本接受 arm64 | x86_64 | all，可重复执行）
./scripts/build-node-android.sh all          # 两个 ABI，各约 40 分钟（最慢的一步）
./scripts/build-bash-android.sh all          # 两个 ABI，各约 1 分钟
./scripts/build-ripgrep-android.sh all       # 两个 ABI，各约 1 分钟（含装 Rust）
./scripts/build-python-android.sh all        # 两个 ABI，各十几分钟
./scripts/build-jsrun-android.sh all         # 秒级（libpnpm/libpnpx/libnpm 启动器）

# 3) 取 DSH 依赖树并适配 Android（仓库外任意目录；两个架构各跑一次）
mkdir -p /tmp/dsh-runtime && cd /tmp/dsh-runtime && npm init -y
npm install @deepseek-ai/dsh@0.2.0-rc.2
cd -
# 每次升级 DSH / 改完 DSH 侧补丁后重跑（5 步：koffi / node-pty / flock / 硬链接 / require-builtin shim）
./scripts/prepare-dsh-android.sh /tmp/dsh-runtime/node_modules x86_64
./scripts/prepare-dsh-android.sh /tmp/dsh-runtime/node_modules arm64
./scripts/prepare-app-assets.sh  /tmp/dsh-runtime/node_modules

# 4) 打包
$DSH_GRADLE :app:assembleDebug
```

> **改完运行时内容一定要 `RUNTIME_VERSION += 1`**（见第 16 条坑 A），否则设备上不会重新解压。
> 另外 `prepare-app-assets.sh` 会硬校验 8 个 Android 专有产物，缺任何一个直接报错退出。

产物是 ABI split 的两个 APK。**要留档就看 `dist/`** —— `install.sh` 每次构建都会
把产物复制过去并起一个带版本号的稳定名字（`build/` 会被 `gradle clean` 清掉）：

```
dist/AndroidDSH-0.2.0-arm64-v8a.apk     # 真机（约 277MB）
dist/AndroidDSH-0.2.0-x86_64.apk        # 模拟器（约 243MB）
dist/SHA256SUMS.txt
```

原始产物路径（每次 `assembleDebug` 覆盖）：

```
app/build/outputs/apk/debug/app-arm64-v8a-debug.apk
app/build/outputs/apk/debug/app-x86_64-debug.apk
```

装到别的手机：`adb install -r -d dist/AndroidDSH-<版本>-arm64-v8a.apk`
（通常的手机都是 arm64。debug 包用本机 `~/.android/debug.keystore` 签名，
所以后续再装新版本能直接覆盖升级；换成别的 key 签的包必须先卸载。）

### 安装与调试

```bash
./scripts/install.sh phone      # 或 emulator / all / <serial>
```

`install.sh` 会构建、按设备 ABI 选包、安装、用 `appops` 授予
`MANAGE_EXTERNAL_STORAGE`（开发便利；正式分发时由用户在首启弹窗里自己开），
然后拉起 app 并等 node 进程起来。

手工等价操作：

```bash
adb -s <serial> install -r -d app/build/outputs/apk/debug/app-<abi>-debug.apk
adb -s <serial> shell appops set com.androiddsh MANAGE_EXTERNAL_STORAGE allow
adb -s <serial> shell am start -n com.androiddsh/.MainActivity
adb -s <serial> logcat -s DshServer DshWeb          # 服务与 WebView 控制台
```

Debug 构建开了 `WebView.setWebContentsDebuggingEnabled(true)`，可以接
DevTools 看真实 DOM：

```bash
SOCK=$(adb shell cat /proc/net/unix | grep -o 'webview_devtools_remote[^ ]*' | head -1)
adb forward tcp:9222 localabstract:$SOCK
curl -s http://127.0.0.1:9222/json
```

## 四、真机实测结论（Honor MAG-AN00 / arm64 / Android 16）

| 项 | 结果 |
| --- | --- |
| 内嵌 DSH 版本 | **0.2.0-rc.2** ✅ |
| 内嵌 `node -v` | `v22.23.3` ✅ |
| 内嵌 `bash --version` | `GNU bash, version 5.2.37(1)-release (aarch64-unknown-linux-android)` ✅ |
| `dsh --profile web` 启动 | 打印 `dsh web: http://127.0.0.1:7300/?token=…` ✅ |
| DSH 原生 Web UI | 会话 / 轨迹 / 工具树 / 右侧栏 / 设置 全部可用 ✅ |
| agent 执行 bash | `which node` → `files/bin/node`；`pwd`、写文件、`cat` 回读 全部成功 ✅ |
| 工作目录 | `pwd` → `/storage/emulated/0/Documents/DSH`；agent 写的 `hello-dsh.txt` 从 `adb shell` / 文件管理器直接可见 ✅ |
| 目录选择器 | 打开即位于 `/sdcard/Documents/DSH`（`DSH_PICKER_HOME`），一按「打开」完成选择 ✅ |
| `glob` / `grep` 工具 | ripgrep 15.2.0（`features:+pcre2`）实测可用，退出码 0/1/2 正确 ✅ |
| agent 执行 python | `python3` = CPython 3.13.15；`python3 -m pip` = 26.2.1；`sqlite3`/`ssl`(OpenSSL 3.0.16)/`ctypes`/`zlib`/`hashlib` 全部可用 ✅ |
| 0.2.0 升级后回归 | bash / glob / python3 三个工具全部 exit 0；`require-builtin` shim 生效；旧会话历史完整迁移 ✅ |
| 终端面板 | 默认 shell = 自带 bash 5.2；`pnpm --version`→10.34.6、`dsh -V`→0.2.0-rc.2 均可在终端直接调用 ✅ |
| 装插件 | 随包发 npm，pnpm 的查询类子命令（`view`/`search`）已可用；`pnpm add` 全流程正常 ✅ |
| 图形界面装插件 | DSH 内置「添加插件」与 `dsh-market` 插件市场均可正常查询与安装 ✅ |
| 终端与命令 | 自带 bash 5.2；`pnpm`/`npm`/`npx`/`dsh` 都是 `files/bin` 里的真实可执行文件 ✅ |
| 宽屏模式 | 布局视口 720 CSS px、`visualViewport.scale=0.509`；设置页内容列 484px（手机模式 318px）✅ |
| 前台服务 | 退到后台后 agent 继续跑，通知栏可一键停止 ✅ |
| API key | 由 Android Keystore（AES-GCM）加密保存；也可直接在 DSH 的引导页里录入 ✅ |

![工作目录](docs/screenshot-workspace.png)

![工具链实测](docs/screenshot-toolchain.png)

设置页在两种模式下的对比（左：宽屏 720 CSS px，内容列 484px；右：手机 366 CSS px，
导航变成横向标签条后内容列 318px）：

| 宽屏 | 手机 |
| --- | --- |
| ![宽屏设置](docs/screenshot-settings-wide.png) | ![窄屏设置](docs/screenshot-settings-phone.png) |

## 五、仍然做不到的事

1. **没有 `git`**。Android 系统不带 git，agent 无法 `git status/diff/commit`。
   要真正当 coding agent 用，需要交叉编译 git（依赖 zlib/openssl/curl，
   工作量比 bash 大得多）或者装 Termux 借它的 prefix。
2. **`npm install` 生态不完整**。`node` / `python3` 都可用，但没有 `git`、
   没有 C 编译工具链，需要编译的包（含 `pip install` 里带 C 扩展的）装不上；
   纯 Python / 纯 JS 的包正常。
3. **模型凭证只有 env 与 DSH 自己的存储两条路**。app 的 Keystore 存储是为了
   在没有 DSH 引导流程时也能用；两处都设的话 **环境变量赢**（DSH 的分层规则）。
4. **`MANAGE_EXTERNAL_STORAGE` 是敏感权限**。自签名/侧载无所谓；上 Google Play
   需要单独申报，且很可能被拒（该权限只对文件管理器、备份、杀毒这类应用开放）。
5. **16KB 对齐**：Node 二进制已经是 16KB 对齐（见下）；`libbash.so` /
   `libripgrep.so` / `libpython3.so` 是静态或只依赖系统库的可执行文件，
   `readelf -l` 显示 LOAD 段已 16KB 对齐。
6. **ncurses 没有 terminfo 数据库**。Android 的 `/system/usr/share/terminfo`
   不存在，Python 的 `readline` 只能退到内建 `dumb` 条目。agent 跑的是非交互
   命令，不受影响；要做真正的交互式终端需要自带 terminfo 目录并设 `TERMINFO`。
7. **`adb install` 的包体约 230–260MB**（debug、未混淆；DSH 0.2.0 的 node_modules
   本身就涨到 122MB）。开 R8 + 只留一个 ABI 能砍掉不少，但会牺牲可调试性。

## 六、开发环境

全部装在 `.toolchain/`（约 14 GB，`.gitignore` 已排除），**不依赖系统包管理器**。

| 组件 | 版本 | 路径 |
| --- | --- | --- |
| JDK (Temurin) | 21.0.12.1+1 LTS | `.toolchain/jdk` |
| Android cmdline-tools | 23.0 | `.toolchain/sdk/cmdline-tools/latest` |
| platform-tools (adb) | 37.0.1 | `.toolchain/sdk/platform-tools` |
| Android SDK Platform | android-36（Android 16） | `.toolchain/sdk/platforms/android-36` |
| build-tools | 36.1.0 | `.toolchain/sdk/build-tools/36.1.0` |
| NDK | 29.0.14206865 (r29) | `.toolchain/sdk/ndk/29.0.14206865` |
| Emulator | 37.1.11 | `.toolchain/sdk/emulator` |
| Gradle | 8.14.3 | `.toolchain/gradle-dist/gradle-8.14.3` |
| AVD | `dsh_x86_64`（Pixel 7 / API 36 / x86_64） | `.toolchain/avd` |

```bash
source scripts/env.sh        # 导出 JAVA_HOME / ANDROID_HOME / PATH / DSH_GRADLE
emulator -avd dsh_x86_64     # 带窗口启动模拟器
```

### 为什么 Node 必须 ≥ 22.18

DSH 的 CLI 入口是 `if (import.meta.main) await runCli()`，而 `import.meta.main`
是 **v24.2.0 / v22.18.0** 才加入的。低版本上该属性为 `undefined`，dsh 会
**静默退出（exit=0、无任何输出）**，非常难排查。因此锁定 **22.23.3**。

### Node 交叉编译必须打的 2 个补丁

`scripts/build-node-android.sh` 里的 `apply_android_patches()` 自动处理，幂等：

1. **`deps/uv/src/unix/linux.c`：`LLONG_MAX` → `INT64_MAX`**
   Node 用 `--std=gnu89` 编译 C 源码，`LLONG_MAX` 是 C99 的。glibc 因
   `_GNU_SOURCE` 会暴露它，bionic 不会。
2. **`deps/v8/src/trap-handler/trap-handler.h`：强制 `V8_TRAP_HANDLER_SUPPORTED false`**
   `v8.gyp` 里 trap-handler 源文件的条件是 `OS in (linux, mac, ios, freebsd)`
   ——**不含 android**。交叉编译时全局 `OS=android`，host 侧 mksnapshot 却判定
   trap handler 可用 → 链接报 `undefined symbol: TryHandleSignal`。

### bash 交叉编译的坑

全在 `scripts/build-bash-android.sh` 的头部注释里，要点：
`--without-bash-malloc`（Android 的 `sbrk` 是废桩）、`ac_cv_func_faccessat=no`
（bionic 的 `faccessat(AT_EACCESS)` 返回 EINVAL，会让 `test -x` 对所有文件返回假）、
`ac_cv_func_getrandom=no`（NDK 头文件在 API 28 以下隐藏声明，但 configure 的链接
探针会过，结果 clang 报未声明）、`bash_cv_termcap_lib=gnutermcap`（别去链宿主的
libtinfo）、`CC_FOR_BUILD=gcc`（构建期工具要用宿主编译器）、`LDFLAGS=-static`
（`--enable-static-link` 在 linux 上并不加 `-static`）。

## 七、网络约束（重要）

本机到 **github.com / services.gradle.org 直连超时**，其余可达。因此：

| 用途 | 镜像 |
| --- | --- |
| JDK | `mirrors.tuna.tsinghua.edu.cn/Adoptium` |
| Gradle 发行版 | `mirrors.cloud.tencent.com/gradle` |
| Maven 依赖 | `maven.aliyun.com/repository/{google,public,gradle-plugin}` |
| Node 源码 / 头文件 | `mirrors.aliyun.com/nodejs-release` |
| bash 源码 | `mirrors.tuna.tsinghua.edu.cn/gnu/bash`（aliyun 兜底） |
| npm | `registry.npmmirror.com` |

## 八、版本锁定

- **compileSdk = 36**：API 37 的稳定平台包尚未发布。
- **Compose BOM 2026.06.01（Compose 1.11.4）**：`2026.08.00` 起的 Compose 1.12.x
  要求 `compileSdk 37` + `AGP 9.1.0+`。
- **AGP 8.13.2 + Gradle 8.14.3 + Kotlin 2.3.21**：与 compileSdk 36 匹配、已实测可构建。
- **DSH 0.2.0-rc.2**：打进 APK 的运行时版本。
  `scripts/patch-dsh-android.py` 里的锚点字符串是按这个版本写的；升级 DSH 时
  必须重新核对每个 `replace_once` 的锚点，脚本找不到预期代码会 `[FAIL]` 而不是
  静默跳过。0.1.5 → 0.2.0 那次升级里，13 处锚点只有 bash 那两处失效（上游把
  `LocalBashExecutor.run()` 改名成了 `execute()`），所以那两处已经改成匹配
  `["bash", "-c", …]` 这个 argv 形状的正则。

## 九、许可

[MIT](LICENSE)。AndroidDSH 是独立的社区项目，与 DeepSeek 官方无隶属或背书关系。

发行的 APK **内含第三方软件** —— GNU bash 与 readline 是 GPL-3.0，DSH 本体与
Node.js 是 MIT，等等。若你要再分发构建出来的 APK，请一并保留
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
