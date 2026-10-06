# AndroidDSH

[English](README.md) | **中文**

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`，基于
Cordis 的插件化 agent runtime）原生跑在 Android 上。

这**不是**用原生 Android UI 重写一遍。app 打包的是 DSH 本体和它自己的 Web 前端，然后
通过回环地址把前端喂给 WebView。你得到的是**真正的 `dsh web` 界面**——和桌面端完全同
一个——而 agent 在**设备本地**执行命令。

---

## 特性

- **真正的 DSH 界面。** 会话、轨迹、工具调用树、右侧栏、技能、目标全部来自 DSH 自带
  的 `dsh-web-frontend`，界面跟着上游走，不会逐渐跑偏。
- **真正的 `bash`。** Android 只自带 `mksh`（`/system/bin/sh`）；本 app 内置
  **GNU bash 5.2** 并把它设为工具调用与终端面板的默认 shell，管道、`pipefail`、数组、
  进程替换都能正常工作。
- **真正的 `python3`。** 内置 **CPython 3.13**，agent 可直接使用 `pip`、`sqlite3`、
  `ssl`、`ctypes`、`zlib`、`hashlib`、`lzma`、`bz2`、`readline`、`socket`、
  `threading`、`subprocess`。
- **真正的 `ripgrep`。** `glob` / `grep` 两个工具由 **ripgrep 15.2**（带 PCRE2）驱动，
  而不是退化成慢速的 JS 实现。
- **可用的包管理器。** `pnpm`、`npm`、`npx` 都是 `PATH` 上的真实可执行文件，因此可以
  安装 DSH 插件——包括界面上的插件入口和 `dsh-market` 插件市场。
- **前台服务。** 切到后台后 agent 继续运行，通知栏可一键停止。
- **公开的工作目录。** agent 在 `/sdcard/Documents/DSH` 里工作，文件管理器、USB/MTP、
  云盘同步都能立刻看到它的产出。
- **凭证加密。** API key 由 Android Keystore（AES-GCM）加密保存。
- **适配平板。** 宽屏模式会加宽布局视口，设置页在窄屏下有专门的兜底布局。

| 桌面 | 空状态 | 会话 | 终端 |
| --- | --- | --- | --- |
| ![桌面](docs/screenshot-launcher.png) | ![空状态](docs/screenshot-phone-home.png) | ![会话](docs/screenshot-phone.png) | ![终端](docs/screenshot-terminal.png) |

| 宽屏设置 | 手机设置 | 插件市场 |
| --- | --- | --- |
| ![宽屏设置](docs/screenshot-settings-wide.png) | ![手机设置](docs/screenshot-settings-phone.png) | ![插件市场](docs/screenshot-plugin-market.png) |

---

## 安装

从 [Releases 页面](https://github.com/Windmill12/dsh-for-android/releases) 下载 APK。
两个包都是**自包含**的——Node 运行时、DSH 依赖树、bash、ripgrep、CPython 全在包里，
不需要再装任何东西。

| 文件 | 适用 |
| --- | --- |
| `AndroidDSH-0.2.0-arm64-v8a.apk` | 手机 / 平板（arm64，绝大多数现代设备） |
| `AndroidDSH-0.2.0-x86_64.apk` | Android 模拟器（x86_64 镜像） |

```bash
adb install -r AndroidDSH-0.2.0-arm64-v8a.apk
```

也可以把 APK 拷到设备上直接点开安装（需要允许"安装未知来源应用"）。下载后可用附带的
`SHA256SUMS.txt` 校验。

**环境要求**

- **Android 8.0（API 26）及以上。**
- 预留约 600MB 空间（安装 + 首启解压运行时）。
- 手机包需要 arm64 设备；模拟器请用 x86_64 包。
- 一个 DeepSeek API key，在 DSH 的引导流程里录入，或在 app 的设置页录入。

首启会申请"所有文件访问"权限，好让 agent 在 `/sdcard/Documents/DSH` 里工作；拒绝也不
影响功能，app 会退回自己的私有目录。

> 发行的 APK 是 **debug 签名**。后续版本可以直接覆盖安装；换成别的 key 签的包必须先
> 卸载。

---

## 架构

```
┌─ Android app (com.androiddsh) ─────────────────────────────────────────┐
│                                                                        │
│  MainActivity ──── Compose ──── WebView ◄── http://127.0.0.1:7300/?token=… │
│       │                              (DSH 原生 Web 前端)                 │
│       │ 观察 StateFlow                                                  │
│  DshServerService（前台服务，保活 + 常驻通知）                            │
│       │                                                                │
│  DshServer（单例）── ProcessBuilder ──► node --expose-internals …       │
│                                          bin.js --profile web --no-open │
│                                                                        │
│  assets/dsh-runtime.pkg    → filesDir/rt        (DSH 的 node_modules)  │
│  jniLibs/libnode.so        → nativeLibraryDir   (Node 二进制)          │
│  jniLibs/libbash.so        → nativeLibraryDir   (静态 bash 5.2)        │
│  jniLibs/libripgrep.so     → nativeLibraryDir   (ripgrep，glob/grep)   │
│  jniLibs/libpython3.so     → nativeLibraryDir   (CPython 3.13)         │
│  assets/python-runtime.pkg → filesDir/python    (Python 标准库)         │
│  filesDir/home             → DSH 的 $HOME（profile / session / 凭证）   │
│  filesDir/bin              → node / bash / rg / python3 的符号链接      │
│  /sdcard/Documents/DSH     → agent 的工作目录（文件管理器直接可见）      │
└────────────────────────────────────────────────────────────────────────┘
```

### 为什么用 WebView

DSH 的界面本身就是一套 Web 前端，由约 60 个 client 插件（`dsh-web-frontend` +
`dsh-web-app`）组装而成。用 Compose 复刻等于把整个前端重做一遍，而且会永远落后于上游。
直接跑 `dsh --profile web` 并把它喂给 WebView，拿到的是**每个版本都和桌面端一致**的原生
界面。

### 工作目录：`/sdcard/Documents/DSH`

DSH 用子进程的 `process.cwd()` 当新会话的默认 `workspaceRoot`，所以 app 直接把 node 的
cwd 设成 `/sdcard/Documents/DSH`——文件管理器、USB/MTP、云盘同步都能立刻看到 agent 产出
的文件。

这条路需要**"所有文件访问"**（`MANAGE_EXTERNAL_STORAGE`）。没有权限时 app 会自动退回零
权限的 `Android/data/com.androiddsh/files/workspace`，功能不受影响；设置页里有"去授权"
按钮，授权回来会自动重启到公开目录。

### 内置组件

| 组件 | 版本 |
| --- | --- |
| DeepSeek Harness (`dsh`) | 0.2.0-rc.2 |
| Node.js | 22.23.3 |
| GNU bash | 5.2.37（静态链接） |
| ripgrep | 15.2.0（含 PCRE2） |
| CPython | 3.13.15（pip 26.2.1） |
| pnpm / npm | 10.34.6 / 随 Node 附带 |

原生部分用 Android NDK 交叉编译，再以 `jniLibs` 条目的形式打包：Android 10 起禁止从
app 的可写数据目录执行文件，而 `nativeLibraryDir` 是只读挂载的、因此允许执行。

DSH 本体在构建期由 `scripts/patch-dsh-android.py` 打补丁以适配 bionic：替换掉硬链接式
的发布逻辑，并通过环境变量把内置的 bash、ripgrep 以及目录选择器的起始路径接上去。

---

## 构建

本仓库**只收源码**：预编译的运行时输入（`app/src/main/assets/*.pkg` 与
`app/src/main/jniLibs/`，合计约 398MB）是构建产物，故意不入库。想直接装来用请从
[Releases 页面](https://github.com/Windmill12/dsh-for-android/releases) 下载现成 APK；
想自己构建就按下面的步骤走一遍。

一切都在工作区内构建，不依赖系统包管理器。工具链落在 `.toolchain/`（约 26GB，
`.gitignore` 已排除）。

### 0. 前置条件

- Linux x86_64 宿主（脚本按 `linux-x86_64` 的 NDK prebuilt 写死）。
- `curl`、`unzip`、`tar`、`python3`、`git`，以及宿主 C 工具链（`gcc`/`make`）——Node、
  bash、Python、Rust 的构建期工具需要。
- 约 **40GB 空闲磁盘**，以及耐心：首次全量构建以小时计，大头是两个架构的 Node。
- 给 Gradle 留约 4GB 内存（`org.gradle.jvmargs=-Xmx4g`）。

### 1. 准备工具链

```bash
source scripts/env.sh              # 导出 JAVA_HOME / ANDROID_HOME / PATH / DSH_GRADLE
./scripts/bootstrap-toolchain.sh   # JDK 21 (Temurin) + Android cmdline-tools
./scripts/install-sdk-packages.sh  # platform 36、build-tools 36.1.0、NDK r29、emulator
```

`scripts/env.sh` 把下载源指向国内镜像（见[网络约束](#网络约束)）；在境外构建时可以换成
`scripts/env.sh` 与 `settings.gradle.kts` 顶部的上游地址。

可选：创建开发时用的模拟器 AVD（Pixel 7 / API 36 / x86_64，名为 `dsh_x86_64`）：

```bash
sdkmanager "system-images;android-36;google_apis;x86_64"
avdmanager create avd -n dsh_x86_64 -k "system-images;android-36;google_apis;x86_64" -d pixel_7
emulator -avd dsh_x86_64
```

### 2. 交叉编译原生可执行文件

每个脚本接受一个架构参数（真机用 `arm64`，模拟器用 `x86_64`）或 `all` 表示两个都编。
重复执行是安全且幂等的，源码会缓存在 `.toolchain/downloads`。

```bash
# Node 22.23.3 —— 最慢的一步，每个 ABI 约 40 分钟
./scripts/build-node-android.sh all

# GNU bash 5.2.37（静态）—— 每个 ABI 约 1 分钟
./scripts/build-bash-android.sh all

# ripgrep 15.2.0 + 静态 PCRE2 —— 每个 ABI 约 1 分钟（首次会装 Rust）
./scripts/build-ripgrep-android.sh all

# CPython 3.13.15 —— 每个 ABI 约 15 分钟
./scripts/build-python-android.sh all

# jsrun 启动器（libpnpm.so / libpnpx.so / libnpm.so）—— 秒级
./scripts/build-jsrun-android.sh all
```

Node 必须 **≥ 22.18**：DSH 的 CLI 入口以 `import.meta.main` 为条件，低版本没有这个属性。
构建脚本锁定 22.23.3，并自动打上 Android 所需的补丁。

### 3. 取 DSH 运行时并适配 Android

把 DSH 的依赖树装到仓库外的任意目录，然后**两个架构各跑一次**适配：

```bash
# 例：拉出 DSH 0.2.0-rc.2 的依赖树
mkdir -p /tmp/dsh-runtime && cd /tmp/dsh-runtime
npm init -y
npm install @deepseek-ai/dsh@0.2.0-rc.2

# 适配：koffi / node-pty / flock 原生模块 + DSH 补丁
./scripts/prepare-dsh-android.sh /tmp/dsh-runtime/node_modules x86_64
./scripts/prepare-dsh-android.sh /tmp/dsh-runtime/node_modules arm64
```

`prepare-dsh-android.sh` 会装上 koffi 的 Android 版、用 NDK 交叉编译 node-pty 与 flock、
应用硬链接相关的补丁，并生成 DSH 0.2.0 需要的 `require-builtin` shim。所有步骤幂等。

然后把所有东西装配进 app：

```bash
./scripts/prepare-app-assets.sh /tmp/dsh-runtime/node_modules
```

它会在源码树里生成：

```
app/src/main/jniLibs/<abi>/libnode.so             # Node 可执行文件
app/src/main/jniLibs/<abi>/libc++_shared.so       # Node 依赖的 C++ 运行时
app/src/main/jniLibs/<abi>/libbash.so             # 静态 bash
app/src/main/jniLibs/<abi>/libripgrep.so          # ripgrep
app/src/main/jniLibs/<abi>/libpython3.so          # CPython
app/src/main/jniLibs/<abi>/lib{pnpm,pnpx,npm}.so  # jsrun 启动器
app/src/main/assets/dsh-runtime.pkg               # DSH 的 node_modules（tar.gz）
app/src/main/assets/python-runtime.pkg            # Python 标准库（tar.gz）
```

脚本会校验所有必需产物是否齐全，缺任何一个直接报错退出——真遇到就重跑第 3 步的两个架构。

> 改完运行时内容后，记得在 `DshRuntime.kt` 里 `RUNTIME_VERSION += 1`。app 用它判断已
> 安装的设备要不要重新解压运行时。

### 4. 打包

仓库没有带 Gradle wrapper，用 `.toolchain` 里的 Gradle 发行版（先 `source scripts/env.sh`）：

```bash
source scripts/env.sh
$DSH_GRADLE :app:assembleDebug
```

产物是 ABI split 的两个 APK，位于
`app/build/outputs/apk/debug/app-<abi>-debug.apk`。

**要留档就看 `dist/`**——`install.sh` 每次构建都会把产物复制过去并起一个带版本号的稳定
名字（`build/` 会被 `gradle clean` 清掉）：

```
dist/AndroidDSH-0.2.0-arm64-v8a.apk     # 真机（约 277MB）
dist/AndroidDSH-0.2.0-x86_64.apk        # 模拟器（约 243MB）
dist/SHA256SUMS.txt
```

### 精简版

```bash
source scripts/env.sh
./scripts/bootstrap-toolchain.sh
./scripts/install-sdk-packages.sh
./scripts/build-node-android.sh all           # 每个 ABI 约 40 分钟
./scripts/build-bash-android.sh all           # 每个 ABI 约 1 分钟
./scripts/build-ripgrep-android.sh all        # 每个 ABI 约 1 分钟
./scripts/build-python-android.sh all         # 每个 ABI 约 15 分钟
./scripts/build-jsrun-android.sh all          # 秒级

./scripts/prepare-dsh-android.sh /tmp/dsh-runtime/node_modules x86_64
./scripts/prepare-dsh-android.sh /tmp/dsh-runtime/node_modules arm64
./scripts/prepare-app-assets.sh  /tmp/dsh-runtime/node_modules

$DSH_GRADLE :app:assembleDebug
```

---

## 安装与调试

```bash
./scripts/install.sh phone      # 或 emulator / all / <serial>
```

`install.sh` 会构建、按设备 ABI 选包、安装、用 `appops` 授予
`MANAGE_EXTERNAL_STORAGE`（开发便利；正式分发时由用户在首启弹窗里自己开），然后拉起
app 并等 node 进程起来。

手工等价操作：

```bash
adb -s <serial> install -r -d app/build/outputs/apk/debug/app-<abi>-debug.apk
adb -s <serial> shell appops set com.androiddsh MANAGE_EXTERNAL_STORAGE allow
adb -s <serial> shell am start -n com.androiddsh/.MainActivity
adb -s <serial> logcat -s DshServer DshWeb          # 服务与 WebView 控制台
```

Debug 构建开了 `WebView.setWebContentsDebuggingEnabled(true)`，可以接 DevTools 看真实
DOM：

```bash
SOCK=$(adb shell cat /proc/net/unix | grep -o 'webview_devtools_remote[^ ]*' | head -1)
adb forward tcp:9222 localabstract:$SOCK
curl -s http://127.0.0.1:9222/json
```

---

## 项目结构

```
app/                         Android app（Kotlin + Compose）
  src/main/java/com/androiddsh/
    MainActivity.kt          Compose 外壳 + WebView 宿主
    DshWebView.kt            WebView 配置与页面内 shim
    DshServer.kt             拉起并守护 dsh 进程
    DshServerService.kt      前台服务
    DshRuntime.kt            运行时解压、二进制、环境变量
    SecretStore.kt           基于 Keystore 的凭证存储
  src/main/assets/           运行时包（生成物，不入库）
  src/main/jniLibs/          交叉编译的可执行文件（生成物，不入库）

native/jsrun.c               用 node 执行指定 JS 入口的小启动器

scripts/
  env.sh                     工具链环境入口
  bootstrap-toolchain.sh     JDK + Android cmdline-tools
  install-sdk-packages.sh    SDK 包与 NDK
  build-node-android.sh      交叉编译 Node.js
  build-bash-android.sh      交叉编译 GNU bash
  build-ripgrep-android.sh   交叉编译 ripgrep
  build-python-android.sh    交叉编译 CPython
  build-jsrun-android.sh     构建 jsrun 启动器
  prepare-dsh-android.sh     把 DSH 的 node_modules 适配到 Android
  prepare-app-assets.sh      把运行时装配进 app
  install.sh                 构建、安装并拉起
  patch-dsh-android.py       应用 DSH 补丁

docs/                        截图
```

---

## 已知限制

1. **没有 `git`。** Android 系统不带 git，agent 无法 `git status/diff/commit`。要真正当
   coding agent 用，需要交叉编译 git，或者借 Termux 的 prefix。
2. **包生态不完整。** `node` 与 `python3` 都可用，但没有 `git`、没有 C 编译工具链，需要
   编译的包（含 `pip install` 里带 C 扩展的）装不上。纯 Python / 纯 JS 的包正常。
3. **凭证有两个来源。** app 的 Keystore 存储与 DSH 自己的存储都可用；两处都设的话**环境
   变量赢**（DSH 的分层规则）。
4. **`MANAGE_EXTERNAL_STORAGE` 是敏感权限。** 侧载无所谓；上 Google Play 需要单独申报，
   且很可能被拒（该权限只对文件管理器、备份、杀毒这类应用开放）。
5. **`pip install` 没有编译器。** 原因同第 2 条，需要从源码构建的包都用不了。

---

## 网络约束

在原开发机器上，**直连 github.com / services.gradle.org 会超时**，其余可达。因此脚本走
镜像，可在 `scripts/env.sh` 中配置：

| 用途 | 镜像 |
| --- | --- |
| JDK | `mirrors.tuna.tsinghua.edu.cn/Adoptium` |
| Gradle 发行版 | `mirrors.cloud.tencent.com/gradle` |
| Maven 依赖 | `maven.aliyun.com/repository/{google,public,gradle-plugin}` |
| Node 源码 / 头文件 | `mirrors.aliyun.com/nodejs-release` |
| bash 源码 | `mirrors.tuna.tsinghua.edu.cn/gnu/bash`（aliyun 兜底） |
| npm | `registry.npmmirror.com` |

在境外构建时，换成上游地址即可。

---

## 工具链

全部装在 `.toolchain/`（约 26GB，`.gitignore` 已排除），**不依赖系统包管理器**。

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

### 版本锁定

- **compileSdk = 36** —— API 37 的稳定平台包尚未发布。
- **Compose BOM 2026.06.01（Compose 1.11.4）** —— `2026.08.00` 起的 Compose 1.12.x 要求
  `compileSdk 37` + `AGP 9.1.0+`。
- **AGP 8.13.2 + Gradle 8.14.3 + Kotlin 2.3.21** —— 与 compileSdk 36 匹配。
- **Node 22.23.3** —— 必须 ≥ 22.18，见上面第 2 步。
- **DSH 0.2.0-rc.2** —— 打进 APK 的运行时版本。`scripts/patch-dsh-android.py` 里的锚点
  是按这个版本写的，脚本找不到预期代码会直接报错，所以升级 DSH 时必须重新核对每个锚点。

---

## 许可

[MIT](LICENSE)。AndroidDSH 是独立的社区项目，与 DeepSeek 官方无隶属或背书关系。

发行的 APK **内含第三方软件**——GNU bash 与 readline 是 GPL-3.0，DSH 本体与 Node.js 是
MIT，等等。若你要再分发构建出来的 APK，请一并保留
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
