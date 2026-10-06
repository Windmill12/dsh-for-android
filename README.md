# AndroidDSH

**English** | [中文](README.zh.md)

Run [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh` — the
Cordis-based, plugin-driven agent runtime) natively on Android.

This is **not a reimplementation with a native Android UI**. The app ships the
real `dsh` together with its own web frontend, and serves that frontend to a
WebView over loopback. What you get is the genuine `dsh web` interface — the same
one that runs on desktop — with the agent executing commands **locally on the
device**.

---

## Highlights

- **The real DSH UI.** Sessions, trajectories, the tool-call tree, the sidebar,
  skills and goals all come from DSH's own `dsh-web-frontend`, so the interface
  tracks upstream instead of drifting from it.
- **Real `bash`.** Android only ships `mksh` as `/system/bin/sh`; this app bundles
  **GNU bash 5.2** and makes it the default shell for tool calls and the terminal
  panel, so pipes, `pipefail`, arrays and process substitution behave normally.
- **Real `python3`.** A bundled **CPython 3.13** with `pip`, `sqlite3`, `ssl`,
  `ctypes`, `zlib`, `hashlib`, `lzma`, `bz2`, `readline`, `socket`, `threading`
  and `subprocess` available to the agent.
- **Real `ripgrep`.** The `glob` and `grep` tools are backed by **ripgrep 15.2**
  with PCRE2, rather than falling back to a slow JS implementation.
- **A working package manager.** `pnpm`, `npm` and `npx` are real executables on
  `PATH`, so installing DSH plugins works — including from the built-in plugin
  UI and the `dsh-market` marketplace.
- **A foreground service.** The agent keeps running when you switch apps, with a
  persistent notification that can stop it.
- **A public working directory.** The agent works in `/sdcard/Documents/DSH`, so
  file managers, USB/MTP and cloud sync see its output immediately.
- **Encrypted credentials.** The API key is stored with the Android Keystore
  (AES-GCM).
- **Tablet-friendly.** A wide-screen mode widens the layout viewport, with a
  narrow-screen fallback for the settings screen.

| Launcher | Empty state | Session | Terminal |
| --- | --- | --- | --- |
| ![Launcher](docs/screenshot-launcher.png) | ![Empty state](docs/screenshot-phone-home.png) | ![Session](docs/screenshot-phone.png) | ![Terminal](docs/screenshot-terminal.png) |

| Settings (wide) | Settings (phone) | Plugin marketplace |
| --- | --- | --- |
| ![Wide settings](docs/screenshot-settings-wide.png) | ![Phone settings](docs/screenshot-settings-phone.png) | ![Plugin marketplace](docs/screenshot-plugin-market.png) |

---

## Install

Download an APK from the
[Releases page](https://github.com/Windmill12/dsh-for-android/releases). Both
builds are **self-contained** — the Node runtime, DSH's dependency tree, bash,
ripgrep and CPython are all inside the package, so there is nothing else to
install.

| File | For |
| --- | --- |
| `AndroidDSH-0.2.0-arm64-v8a.apk` | Phones and tablets (arm64 — almost all modern devices) |
| `AndroidDSH-0.2.0-x86_64.apk` | Android emulators (x86_64 images) |

```bash
adb install -r AndroidDSH-0.2.0-arm64-v8a.apk
```

Or copy the APK to the device and open it — you'll need to allow installing from
unknown sources. Check your download against the attached `SHA256SUMS.txt`.

**Requirements**

- **Android 8.0 (API 26) or newer.**
- ~600MB of free storage for the install plus the first-launch runtime unpack.
- An arm64 device for the phone build (use the x86_64 build on an emulator).
- A DeepSeek API key, entered either in DSH's onboarding flow or the app's
  settings screen.

On first launch the app asks for "All files access", which lets the agent work in
`/sdcard/Documents/DSH`. Decline it and the app falls back to its private
directory with no loss of functionality.

> The released APKs are **debug-signed**. Installing a future release over this
> one works fine, but an APK signed with a different key requires uninstalling
> first.

---

## Architecture

```
┌─ Android app (com.androiddsh) ─────────────────────────────────────────┐
│                                                                        │
│  MainActivity ──── Compose ──── WebView ◄── http://127.0.0.1:7300/?token=… │
│       │                              (DSH's native web frontend)        │
│       │ observes StateFlow                                             │
│  DshServerService (foreground service: keeps alive + persistent notice) │
│       │                                                                │
│  DshServer (singleton) ── ProcessBuilder ──► node --expose-internals …  │
│                                              bin.js --profile web --no-open │
│                                                                        │
│  assets/dsh-runtime.pkg    → filesDir/rt        (DSH's node_modules)   │
│  jniLibs/libnode.so        → nativeLibraryDir   (the Node binary)      │
│  jniLibs/libbash.so        → nativeLibraryDir   (static bash 5.2)      │
│  jniLibs/libripgrep.so     → nativeLibraryDir   (ripgrep; glob/grep)   │
│  jniLibs/libpython3.so     → nativeLibraryDir   (CPython 3.13)         │
│  assets/python-runtime.pkg → filesDir/python    (Python stdlib)        │
│  filesDir/home             → DSH's $HOME (profile / session / creds)   │
│  filesDir/bin              → symlinks to node / bash / rg / python3    │
│  /sdcard/Documents/DSH     → the agent's working directory (visible in │
│                              any file manager)                         │
└────────────────────────────────────────────────────────────────────────┘
```

### Why a WebView

DSH's UI *is* a web frontend, assembled from roughly 60 client plugins
(`dsh-web-frontend` + `dsh-web-app`). Reimplementing it in Compose would mean
rebuilding the entire frontend and then trailing upstream forever. Running
`dsh --profile web` and pointing a WebView at it keeps the interface identical to
desktop in every release.

### Working directory: `/sdcard/Documents/DSH`

DSH uses the child process's `process.cwd()` as the default `workspaceRoot` for
new sessions, so the app simply sets node's cwd to `/sdcard/Documents/DSH` —
file managers, USB/MTP and cloud sync all see the agent's output immediately.

That path requires **"All files access"** (`MANAGE_EXTERNAL_STORAGE`). Without the
permission the app automatically falls back to the zero-permission
`Android/data/com.androiddsh/files/workspace` and everything still works; the
settings screen offers a "Grant access" button and the app restarts into the
public directory once you return.

### Bundled components

| Component | Version |
| --- | --- |
| DeepSeek Harness (`dsh`) | 0.2.0-rc.2 |
| Node.js | 22.23.3 |
| GNU bash | 5.2.37 (statically linked) |
| ripgrep | 15.2.0 (with PCRE2) |
| CPython | 3.13.15 (pip 26.2.1) |
| pnpm / npm | 10.34.6 / bundled with Node |

The native payloads are cross-compiled with the Android NDK and repackaged as
`jniLibs` entries, because Android 10+ forbids executing files from an app's
writable data directory while `nativeLibraryDir` is mounted read-only and
therefore executable.

DeepSeek Harness itself is patched at build time by
`scripts/patch-dsh-android.py` so that it runs on bionic: hard-link publishing is
replaced, and the bundled bash, ripgrep and directory-picker paths are wired up
through environment variables.

---

## Building it

The repository is **source-only**: the prebuilt runtime inputs
(`app/src/main/assets/*.pkg` and `app/src/main/jniLibs/`, ~398MB) are build
outputs and are deliberately not committed. To use the app, download an APK from
the [Releases page](https://github.com/Windmill12/dsh-for-android/releases)
instead. To build it yourself, follow the steps below.

Everything is built inside the workspace; nothing depends on the system package
manager. The toolchain lives in `.toolchain/` (about 26GB, excluded by
`.gitignore`).

### 0. Prerequisites

- Linux x86_64 host (the scripts assume `linux-x86_64` NDK prebuilts).
- `curl`, `unzip`, `tar`, `python3`, `git`, and a C toolchain for host build
  tools (`gcc`/`make`) — needed by the Node, bash, Python and Rust builds.
- Roughly **40GB of free disk space** and considerable patience: the first full
  build is measured in hours, dominated by two architectures of Node.
- Roughly 4GB of RAM available to Gradle (`org.gradle.jvmargs=-Xmx4g`).

### 1. Bootstrap the toolchain

```bash
source scripts/env.sh              # exports JAVA_HOME / ANDROID_HOME / PATH / DSH_GRADLE
./scripts/bootstrap-toolchain.sh   # JDK 21 (Temurin) + Android cmdline-tools
./scripts/install-sdk-packages.sh  # platform 36, build-tools 36.1.0, NDK r29, emulator
```

`scripts/env.sh` points downloads at domestic mirrors (see
[Network constraints](#network-constraints)); outside mainland China you may want
to replace those with the upstream URLs at the top of `scripts/env.sh` and
`settings.gradle.kts`.

Optionally create the emulator AVD used during development (Pixel 7 / API 36 /
x86_64, named `dsh_x86_64`):

```bash
sdkmanager "system-images;android-36;google_apis;x86_64"
avdmanager create avd -n dsh_x86_64 -k "system-images;android-36;google_apis;x86_64" -d pixel_7
emulator -avd dsh_x86_64
```

### 2. Cross-compile the native payloads

Each script takes an architecture (`arm64` for devices, `x86_64` for emulators)
or `all` for both. Re-running any of them is safe and idempotent, and they cache
their sources under `.toolchain/downloads`.

```bash
# Node 22.23.3 — by far the longest step, roughly 40 minutes per ABI
./scripts/build-node-android.sh all

# GNU bash 5.2.37 (static) — about 1 minute per ABI
./scripts/build-bash-android.sh all

# ripgrep 15.2.0 + static PCRE2 — about 1 minute per ABI (installs Rust on first run)
./scripts/build-ripgrep-android.sh all

# CPython 3.13.15 — about 15 minutes per ABI
./scripts/build-python-android.sh all

# jsrun launcher (libpnpm.so / libpnpx.so / libnpm.so) — seconds
./scripts/build-jsrun-android.sh all
```

Node must be **22.18 or newer** — DSH's CLI entry is gated on `import.meta.main`,
which older versions do not provide. The build script pins 22.23.3 and applies
the required Android patches automatically.

### 3. Fetch the DSH runtime and adapt it to Android

Install DSH's dependency tree somewhere outside the repo (any directory will do),
then run the adaptation for **both** architectures:

```bash
# Example: materialize DSH 0.2.0-rc.2's dependency tree
mkdir -p /tmp/dsh-runtime && cd /tmp/dsh-runtime
npm init -y
npm install @deepseek-ai/dsh@0.2.0-rc.2

# Adapt it: koffi / node-pty / flock native modules + the DSH patches
./scripts/prepare-dsh-android.sh /tmp/dsh-runtime/node_modules x86_64
./scripts/prepare-dsh-android.sh /tmp/dsh-runtime/node_modules arm64
```

`prepare-dsh-android.sh` installs the Android builds of koffi, cross-compiles
node-pty and flock with the NDK, applies the hard-link patches, and generates the
`require-builtin` shim that DSH 0.2.0 needs. All steps are idempotent.

Then assemble everything into the app:

```bash
./scripts/prepare-app-assets.sh /tmp/dsh-runtime/node_modules
```

This produces, inside the source tree:

```
app/src/main/jniLibs/<abi>/libnode.so             # Node executable
app/src/main/jniLibs/<abi>/libc++_shared.so       # C++ runtime Node needs
app/src/main/jniLibs/<abi>/libbash.so             # static bash
app/src/main/jniLibs/<abi>/libripgrep.so          # ripgrep
app/src/main/jniLibs/<abi>/libpython3.so          # CPython
app/src/main/jniLibs/<abi>/lib{pnpm,pnpx,npm}.so  # jsrun launchers
app/src/main/assets/dsh-runtime.pkg               # DSH's node_modules (tar.gz)
app/src/main/assets/python-runtime.pkg            # Python stdlib (tar.gz)
```

The script validates that all required artifacts are present and exits with an
error if any is missing — if that happens, re-run step 3 for both architectures.

> After changing anything in the runtime, bump `RUNTIME_VERSION` in
> `DshRuntime.kt`. The app uses it to decide whether to re-unpack the runtime on
> an already-installed device.

### 4. Package the APKs

There is no Gradle wrapper checked in; use the Gradle distribution from
`.toolchain` (via `source scripts/env.sh`):

```bash
source scripts/env.sh
$DSH_GRADLE :app:assembleDebug
```

The output is two ABI-split APKs at
`app/build/outputs/apk/debug/app-<abi>-debug.apk`.

To keep a build, look in `dist/` — `install.sh` copies the artifacts there under
stable versioned names (`build/` gets wiped by `gradle clean`):

```
dist/AndroidDSH-0.2.0-arm64-v8a.apk     # devices  (~277MB)
dist/AndroidDSH-0.2.0-x86_64.apk        # emulators (~243MB)
dist/SHA256SUMS.txt
```

### Condensed

```bash
source scripts/env.sh
./scripts/bootstrap-toolchain.sh
./scripts/install-sdk-packages.sh
./scripts/build-node-android.sh all           # ~40 min / ABI
./scripts/build-bash-android.sh all           # ~1 min  / ABI
./scripts/build-ripgrep-android.sh all        # ~1 min  / ABI
./scripts/build-python-android.sh all         # ~15 min / ABI
./scripts/build-jsrun-android.sh all          # seconds

./scripts/prepare-dsh-android.sh /tmp/dsh-runtime/node_modules x86_64
./scripts/prepare-dsh-android.sh /tmp/dsh-runtime/node_modules arm64
./scripts/prepare-app-assets.sh  /tmp/dsh-runtime/node_modules

$DSH_GRADLE :app:assembleDebug
```

---

## Installing and debugging

```bash
./scripts/install.sh phone      # or emulator / all / <serial>
```

`install.sh` builds, picks the APK matching the device ABI, installs it, grants
`MANAGE_EXTERNAL_STORAGE` via `appops` (a development convenience; for real
distribution the user grants it themselves from the first-launch prompt), then
launches the app and waits for the node process to come up.

The manual equivalent:

```bash
adb -s <serial> install -r -d app/build/outputs/apk/debug/app-<abi>-debug.apk
adb -s <serial> shell appops set com.androiddsh MANAGE_EXTERNAL_STORAGE allow
adb -s <serial> shell am start -n com.androiddsh/.MainActivity
adb -s <serial> logcat -s DshServer DshWeb          # service + WebView console
```

Debug builds enable `WebView.setWebContentsDebuggingEnabled(true)`, so you can
attach DevTools and inspect the real DOM:

```bash
SOCK=$(adb shell cat /proc/net/unix | grep -o 'webview_devtools_remote[^ ]*' | head -1)
adb forward tcp:9222 localabstract:$SOCK
curl -s http://127.0.0.1:9222/json
```

---

## Project layout

```
app/                         Android app (Kotlin + Compose)
  src/main/java/com/androiddsh/
    MainActivity.kt          Compose shell + WebView host
    DshWebView.kt            WebView configuration and in-page shims
    DshServer.kt             Spawns and supervises the dsh process
    DshServerService.kt      Foreground service
    DshRuntime.kt            Runtime unpacking, binaries, environment
    SecretStore.kt           Keystore-backed credential storage
  src/main/assets/           Runtime packages (generated, not committed)
  src/main/jniLibs/          Cross-compiled executables (generated, not committed)

native/jsrun.c               Tiny launcher that execs node with a JS entry

scripts/
  env.sh                     Toolchain environment entry point
  bootstrap-toolchain.sh     JDK + Android cmdline-tools
  install-sdk-packages.sh    SDK packages and NDK
  build-node-android.sh      Cross-compile Node.js
  build-bash-android.sh      Cross-compile GNU bash
  build-ripgrep-android.sh   Cross-compile ripgrep
  build-python-android.sh    Cross-compile CPython
  build-jsrun-android.sh     Build the jsrun launchers
  prepare-dsh-android.sh     Adapt DSH's node_modules to Android
  prepare-app-assets.sh      Assemble the runtime into the app
  install.sh                 Build, install and launch on a device
  patch-dsh-android.py       Applies the DSH patches

docs/                        Screenshots
```

---

## Limitations

1. **No `git`.** Android doesn't ship git, so the agent can't run
   `git status/diff/commit`. Using it as a full coding agent would require
   cross-compiling git or borrowing Termux's prefix.
2. **The package ecosystem is incomplete.** `node` and `python3` both work, but
   without `git` and a C toolchain, packages that need compilation (including
   `pip install` with C extensions) can't be installed. Pure Python and pure JS
   packages are fine.
3. **Credentials have two sources.** The app's Keystore storage and DSH's own
   store both work; if both are set, the environment variable wins (DSH's
   layering rules).
4. **`MANAGE_EXTERNAL_STORAGE` is a sensitive permission.** For sideloaded builds
   this is irrelevant, but publishing on Google Play requires a separate
   declaration and is likely to be rejected, since that permission is only open
   to file managers, backup and antivirus apps.
5. **`pip install` has no compiler.** Anything requiring a build step from source
   is unavailable for the same reason as (2).

---

## Network constraints

On the original development machine, **direct connections to github.com and
services.gradle.org time out**; everything else is reachable. The scripts
therefore use mirrors, configurable in `scripts/env.sh`:

| Purpose | Mirror |
| --- | --- |
| JDK | `mirrors.tuna.tsinghua.edu.cn/Adoptium` |
| Gradle distribution | `mirrors.cloud.tencent.com/gradle` |
| Maven dependencies | `maven.aliyun.com/repository/{google,public,gradle-plugin}` |
| Node source / headers | `mirrors.aliyun.com/nodejs-release` |
| bash source | `mirrors.tuna.tsinghua.edu.cn/gnu/bash` (aliyun fallback) |
| npm | `registry.npmmirror.com` |

If you're building outside mainland China, swap these for the upstream URLs.

---

## Toolchain

Everything is installed under `.toolchain/` (about 26GB, excluded by
`.gitignore`), with **no dependency on the system package manager**.

| Component | Version | Path |
| --- | --- | --- |
| JDK (Temurin) | 21.0.12.1+1 LTS | `.toolchain/jdk` |
| Android cmdline-tools | 23.0 | `.toolchain/sdk/cmdline-tools/latest` |
| platform-tools (adb) | 37.0.1 | `.toolchain/sdk/platform-tools` |
| Android SDK Platform | android-36 (Android 16) | `.toolchain/sdk/platforms/android-36` |
| build-tools | 36.1.0 | `.toolchain/sdk/build-tools/36.1.0` |
| NDK | 29.0.14206865 (r29) | `.toolchain/sdk/ndk/29.0.14206865` |
| Emulator | 37.1.11 | `.toolchain/sdk/emulator` |
| Gradle | 8.14.3 | `.toolchain/gradle-dist/gradle-8.14.3` |
| AVD | `dsh_x86_64` (Pixel 7 / API 36 / x86_64) | `.toolchain/avd` |

```bash
source scripts/env.sh        # exports JAVA_HOME / ANDROID_HOME / PATH / DSH_GRADLE
emulator -avd dsh_x86_64     # start the emulator with a window
```

### Version pinning

- **compileSdk = 36** — the stable API 37 platform package isn't published yet.
- **Compose BOM 2026.06.01 (Compose 1.11.4)** — Compose 1.12.x, as of
  `2026.08.00`, requires `compileSdk 37` + `AGP 9.1.0+`.
- **AGP 8.13.2 + Gradle 8.14.3 + Kotlin 2.3.21** — matches compileSdk 36.
- **Node 22.23.3** — must be ≥ 22.18, see step 2 above.
- **DSH 0.2.0-rc.2** — the runtime version baked into the APK. The anchors in
  `scripts/patch-dsh-android.py` are written for this version, and the script
  fails loudly when it cannot find the expected code, so upgrading DSH means
  re-checking every anchor.

---

## License

[MIT](LICENSE). AndroidDSH is an independent community project and is not
affiliated with or endorsed by DeepSeek.

The released APKs **bundle third-party software** — GNU bash and readline are
GPL-3.0, DSH itself and Node.js are MIT, and so on. If you redistribute a built
APK, keep [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) with it.
