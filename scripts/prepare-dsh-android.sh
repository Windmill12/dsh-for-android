#!/usr/bin/env bash
# 把 DSH 的 node_modules 适配到 Android。
#
# 用法:
#   ./scripts/prepare-dsh-android.sh <node_modules 路径> [x86_64|arm64]
#
# 例:
#   ./scripts/prepare-dsh-android.sh /tmp/dsh-runtime/node_modules x86_64
#   ./scripts/prepare-dsh-android.sh /tmp/dsh-runtime/node_modules arm64
#
# 处理 DSH 在 Android 上会踩到的全部原生依赖问题：
#
#   1. koffi        —— FFI 库，官方有 Android 预编译包，直接装
#   2. node-pty     —— 伪终端，自带源码，用 NDK 交叉编译
#   3. flock        —— @deepseek-ai/node-addon-system 的原生模块，自带 src/flock.c
#   4. 硬链接        —— Android SELinux 全局禁止 link(2)，patch 掉 4 处调用
#
# 全部步骤幂等，可重复执行。
set -euo pipefail

NM="${1:?用法: prepare-dsh-android.sh <node_modules 路径> [x86_64|arm64]}"
ARCH="${2:-x86_64}"

case "$ARCH" in
  x86_64) ABI="x86_64";    NODE_ARCH="x64";   KOFFI_PKG="koffi-android-x64";   CLANG_TRIPLE="x86_64-linux-android" ;;
  arm64)  ABI="arm64-v8a"; NODE_ARCH="arm64"; KOFFI_PKG="koffi-android-arm64"; CLANG_TRIPLE="aarch64-linux-android" ;;
  *) echo "不支持的 arch: $ARCH（只支持 x86_64 / arm64）" >&2; exit 1 ;;
esac

# node-addon-native-custom-loader 的 platformPackageSuffix() 在 Android 上就是这个形状
# （不带 -gnu/-musl 之类的 libc 后缀，见它抛错时的包名）
platform_suffix="android-$NODE_ARCH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC="$ROOT/.toolchain"
NDK="$TC/sdk/ndk/29.0.14206865"
LLVM="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
API="${DSH_NODE_API:-26}"
NODE_VERSION="${DSH_NODE_VERSION:-22.23.3}"
KOFFI_VERSION="${DSH_KOFFI_VERSION:-3.3.2}"
NPMMIRROR="https://registry.npmmirror.com"

CC="$LLVM/bin/${CLANG_TRIPLE}${API}-clang"
CXX="$LLVM/bin/${CLANG_TRIPLE}${API}-clang++"

[[ -d "$NM" ]] || { echo "找不到 node_modules: $NM" >&2; exit 1; }
[[ -d "$NDK" ]] || { echo "找不到 NDK: $NDK（先跑 scripts/install-sdk-packages.sh）" >&2; exit 1; }

# --- 交叉编译需要 Node 头文件（与目标 Node 版本一致）---
HEADERS="$TC/build/node-headers"
if [[ ! -f "$HEADERS/include/node/node_api.h" ]]; then
  echo "==> 下载 Node $NODE_VERSION 头文件"
  mkdir -p "$TC/downloads" "$HEADERS"
  curl -fL --no-progress-meter --retry 3 \
    -o "$TC/downloads/node-headers.tar.gz" \
    "https://mirrors.aliyun.com/nodejs-release/v$NODE_VERSION/node-v$NODE_VERSION-headers.tar.gz"
  tar xzf "$TC/downloads/node-headers.tar.gz" -C "$HEADERS" --strip-components=1
fi
NODE_INC="$HEADERS/include/node"

echo "==> 目标: android/$ARCH (ABI=$ABI, API=$API)"
echo "    node_modules = $NM"

# ---------------------------------------------------------------- 1. koffi
step_koffi() {
  local dest="$NM/@koromix/$KOFFI_PKG"
  if [[ -f "$dest/index.js" ]]; then
    echo "  [skip] koffi $KOFFI_PKG 已安装"
    return
  fi
  echo "  [install] @koromix/$KOFFI_PKG@$KOFFI_VERSION"
  mkdir -p "$NM/@koromix" "$TC/downloads"
  local tgz="$TC/downloads/$KOFFI_PKG-$KOFFI_VERSION.tgz"
  curl -sSL --retry 3 -o "$tgz" \
    "$NPMMIRROR/@koromix/$KOFFI_PKG/-/$KOFFI_PKG-$KOFFI_VERSION.tgz"
  rm -rf "$dest" "$TC/downloads/koffi-unpack"
  mkdir -p "$TC/downloads/koffi-unpack"
  tar xzf "$tgz" -C "$TC/downloads/koffi-unpack"
  mv "$TC/downloads/koffi-unpack/package" "$dest"
  echo "  [ok]   $(find "$dest" -name '*.node' | head -1)"
}

# ------------------------------------------------------------- 2. node-pty
step_node_pty() {
  local dir="$NM/node-pty"
  [[ -d "$dir" ]] || { echo "  [skip] 无 node-pty"; return; }
  local out="$dir/prebuilds/android-$NODE_ARCH/pty.node"
  if [[ -f "$out" ]]; then
    echo "  [skip] node-pty 已编译"
    return
  fi
  [[ -f "$dir/src/unix/pty.cc" ]] || { echo "  [FAIL] node-pty 无源码" >&2; return 1; }
  echo "  [compile] node-pty (src/unix/pty.cc)"
  mkdir -p "$(dirname "$out")"
  # 不用 node-gyp：binding.gyp 会链接 Android 上不存在的 -lutil，
  # 且 openpty/forkpty/grantpt/unlockpt/ptsname 都已在 bionic libc 里。
  "$CXX" -shared -fPIC -fvisibility=hidden -O2 -std=c++17 -DNAPI_CPP_EXCEPTIONS \
    -I"$NODE_INC" -I"$NM/node-addon-api" \
    -o "$out" "$dir/src/unix/pty.cc"
  echo "  [ok]   $out"
}

# ---------------------------------------------------------------- 3. flock
step_flock() {
  local sysdir="$NM/@deepseek-ai/node-addon-system"
  [[ -d "$sysdir" ]] || { echo "  [skip] 无 node-addon-system"; return; }
  local pkgdir="$NM/@deepseek-ai/node-addon-system-android-$NODE_ARCH"
  local out="$pkgdir/bin/system.node"
  if [[ -f "$out" ]]; then
    echo "  [skip] system.node 已编译"
  else
    [[ -f "$sysdir/src/flock.c" ]] || { echo "  [FAIL] node-addon-system 无 src/flock.c" >&2; return 1; }
    echo "  [compile] system.node (src/flock.c，提供 flock)"
    mkdir -p "$pkgdir/bin"
    # 纯 C，不需要 C++ 运行时；<sys/file.h> 的 flock 在 bionic 里可用。
    "$CC" -shared -fPIC -O2 -std=gnu11 -I"$NODE_INC" -o "$out" "$sysdir/src/flock.c"
    cat > "$pkgdir/package.json" <<EOF
{
  "name": "@deepseek-ai/node-addon-system-android-$NODE_ARCH",
  "version": "0.1.2",
  "description": "system.node (flock) 的 android-$NODE_ARCH 构建，由 src/flock.c 交叉编译而来",
  "os": ["android"],
  "cpu": ["$NODE_ARCH"],
  "files": ["bin/"]
}
EOF
    echo "  [ok]   $out"
  fi

  # flock.js 硬编码只支持 linux/darwin，需要放行 android。
  # 注意：android 走的是 filename='system.node' 分支，不会去找 glibc/musl 子目录。
  local flockjs="$sysdir/lib/flock.js"
  if grep -q "platform !== 'android'" "$flockjs" 2>/dev/null; then
    echo "  [skip] flock.js 已放行 android"
  else
    sed -i "s/if (platform !== 'linux' \&\& platform !== 'darwin') {/if (platform !== 'linux' \&\& platform !== 'darwin' \&\& platform !== 'android') {/" "$flockjs"
    echo "  [patch] flock.js 放行 android"
  fi
}

# ------------------------------------------------------------ 4. 硬链接
step_hardlink() {
  python3 "$ROOT/scripts/patch-dsh-android.py" "$NM"
}

# ------------------------------------------- 5. node-addon-require-builtin
# DSH 0.2.0 起，`dsh-app-boot` 在启动最早期就 require("node-addon-require-builtin")，
# 用它拿 Node 的 internal 模块（internal/modules/esm/loader 等）。
#
# 这个包**只发预编译产物**：包里没有 src/、没有 binding.gyp，npm 上的可选包也只有
# darwin / linux / win32 九种，**没有 android**。它的 loader
# (`node-addon-native-custom-loader`) 依次找三条路：
#   1. 可选包 `node-addon-require-builtin-<suffix>` —— 不存在（404）
#   2. workspace 里的同名目录
#   3. 本地构建 `build/<backend>/<abi>-<suffix>/require_builtin.node`
# 三条全落空就抛 `No usable native binding found for node-addon-require-builtin-android-arm64`，
# DSH 直接 fatal：`dsh: host preparation failed`。
#
# 但第 1 条路走的是普通 `require()`，而 loader 对 binding 的全部要求只有
#   - requireBuiltin(moduleId) / isAllowedInternalId(moduleId) / getNativeBindingInfo()
#   - getNativeBindingInfo() 返回带 mode/product/backend/abi 四个字符串字段的对象
#     （product 必须是 "require-builtin"）
# 也就是说，**一个纯 JS 包就能顶替**。
#
# 而且我们本来就带 `--expose-internals` 启动（HMR 需要，见 DshRuntime.webCommand），
# 带着这个 flag 时 `require("internal/...")` 在普通 CJS 模块里就是通的 —— 实测
# internal/modules/{esm/loader,cjs/loader,helpers,esm/utils,esm/resolve} 全部可加载。
# 所以原 addon 干的事（绕过 flag 拿 internal）在这里由 flag 本身完成了，shim 只负责转发。
#
# 不编译 C++ 是有意的：真 addon 要在 C++ 里接 Node 的 internal binding 表，实现成本高、
# 且随 Node 版本漂移；而我们这个配置下它没有任何额外能力。
step_require_builtin() {
  local pkg="$NM/node-addon-require-builtin-$platform_suffix"
  if [[ -f "$pkg/index.js" ]]; then
    echo "  [skip] require-builtin shim 已存在"
  else
    echo "  [gen]  $pkg （纯 JS 转发到 --expose-internals 的 require）"
    mkdir -p "$pkg"
    cat > "$pkg/package.json" <<EOF
{
  "name": "node-addon-require-builtin-$platform_suffix",
  "version": "0.1.7",
  "description": "Android 替身：把 requireBuiltin 转发给带了 --expose-internals 的 require()。由 AndroidDSH 的 scripts/prepare-dsh-android.sh 生成，不是上游产物。",
  "main": "index.js",
  "license": "MIT",
  "os": ["android"],
  "cpu": ["$NODE_ARCH"]
}
EOF
    cat > "$pkg/index.js" <<'EOF'
'use strict';
// Android 替身实现，见 scripts/prepare-dsh-android.sh 的 step_require_builtin()。
//
// 上游 @deepseek-ai/dsh-node-addon-require-builtin 是个 N-API 插件，用来在不带
// --expose-internals 的情况下拿到 Node internal 模块。DSH 在 Android 上是我们自己
// 用 `node --expose-internals` 启动的，所以这个能力由 flag 直接提供，这里只做转发。
//
// loader 端 (node-addon-native-custom-loader) 只校验这三个导出，以及
// getNativeBindingInfo() 返回的 mode/product/backend/abi 四个字符串字段。
function requireBuiltin(moduleId) {
  return require(moduleId);
}

function isAllowedInternalId(moduleId) {
  return typeof moduleId === 'string' && moduleId.startsWith('internal/');
}

var info = {
  mode: 'js-expose-internals',
  product: 'require-builtin',
  backend: 'napi',
  abi: 'napi-v9',
};

function getNativeBindingInfo() {
  return info;
}

module.exports = {
  requireBuiltin: requireBuiltin,
  isAllowedInternalId: isAllowedInternalId,
  getNativeBindingInfo: getNativeBindingInfo,
  bindingPath: __filename,
  nativeBindingInfo: info,
};
EOF
  fi
}


echo "==> 1/5 koffi";           step_koffi
echo "==> 2/5 node-pty";        step_node_pty
echo "==> 3/5 flock";           step_flock
echo "==> 4/5 硬链接";           step_hardlink
echo "==> 5/5 require-builtin"; step_require_builtin

echo
echo "==> 适配完成。产出的 Android 原生模块："
find "$NM" -name "*.node" -path "*android*" 2>/dev/null | sed 's|^|    |'
