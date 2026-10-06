#!/usr/bin/env bash
# 把 Node 运行时和 DSH 依赖树装配进 app/。
#
# 用法:
#   ./scripts/prepare-app-assets.sh <dsh node_modules 路径>
#
# 产出:
#   app/src/main/jniLibs/<abi>/libnode.so         Node 可执行文件
#   app/src/main/jniLibs/<abi>/libc++_shared.so   Node 依赖的 C++ 运行时
#   app/src/main/assets/dsh-runtime.pkg        DSH 的 node_modules（含各 ABI 原生模块）
#
# 为什么 Node 二进制要叫 libnode.so 并放进 jniLibs：
#   Android 10+ 的 W^X 策略禁止从 app 可写数据目录 exec()，但 nativeLibraryDir
#   （/data/app/~~xxx/pkg-yyy==/lib/<abi>/）是只读的，允许执行。放进 jniLibs
#   才能落到 nativeLibraryDir。
#
# 前置：
#   ./scripts/build-node-android.sh x86_64 all
#   ./scripts/build-node-android.sh arm64  all
#   ./scripts/prepare-dsh-android.sh <node_modules> x86_64
#   ./scripts/prepare-dsh-android.sh <node_modules> arm64
set -euo pipefail

NM="${1:?用法: prepare-app-assets.sh <dsh node_modules 路径>}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC="$ROOT/.toolchain"
NDK="$TC/sdk/ndk/29.0.14206865"
LLVM="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
NODE_VERSION="${DSH_NODE_VERSION:-22.23.3}"
APP="$ROOT/app/src/main"

[[ -d "$NM" ]] || { echo "找不到 node_modules: $NM" >&2; exit 1; }

# app ABI 名 -> (构建产物目录后缀, NDK sysroot 三元组, Node 的 process.arch)
copy_abi() {
  local abi="$1" aarch="$2" triple="$3"
  local node_src="$TC/build/node-v$NODE_VERSION-android-$aarch/node.stripped"
  local cxx_src="$LLVM/sysroot/usr/lib/$triple/libc++_shared.so"
  local bash_src="$TC/build/bash-android-$aarch/bash"
  local rg_src="$TC/build/ripgrep-android-$aarch/rg"
  local py_src="$TC/build/python-android-$aarch/bin/python3"
  [[ -f "$node_src" ]] || { echo "缺 Node 产物: $node_src（先跑 build-node-android.sh $aarch all）" >&2; return 1; }

  mkdir -p "$APP/jniLibs/$abi"
  cp -f "$node_src" "$APP/jniLibs/$abi/libnode.so"
  cp -f "$cxx_src"  "$APP/jniLibs/$abi/libc++_shared.so"
  chmod 755 "$APP/jniLibs/$abi/libnode.so"
  printf "  %-12s libnode.so %s / libc++_shared.so %s\n" "$abi" \
    "$(du -h "$APP/jniLibs/$abi/libnode.so" | cut -f1)" \
    "$(du -h "$APP/jniLibs/$abi/libc++_shared.so" | cut -f1)"

  # 静态 bash：同样只能以 jniLib 的名义分发（Android 只允许从 nativeLibraryDir
  # 执行文件，且 AGP 只把 *.so 打进 lib/<abi>/）。DSH 侧通过 DSH_BASH_PATH
  # 拿到这个绝对路径，见 scripts/patch-dsh-android.py 的 patch_bash_path()。
  if [[ -f "$bash_src" ]]; then
    cp -f "$bash_src" "$APP/jniLibs/$abi/libbash.so"
    chmod 755 "$APP/jniLibs/$abi/libbash.so"
    printf "  %-12s libbash.so %s\n" "$abi" "$(du -h "$APP/jniLibs/$abi/libbash.so" | cut -f1)"
  else
    echo "  警告: 缺 bash 产物 $bash_src（先跑 build-bash-android.sh $aarch）；" >&2
    echo "        app 将退回 /system/bin/sh(mksh)，bash 语法会失败。" >&2
  fi

  # ripgrep：glob / grep 两个工具的后端。路径通过 DSH_RG_PATH 传给 DSH，
  # 见 patch-dsh-android.py 的 patch_rg_path()。
  if [[ -f "$rg_src" ]]; then
    cp -f "$rg_src" "$APP/jniLibs/$abi/libripgrep.so"
    chmod 755 "$APP/jniLibs/$abi/libripgrep.so"
    printf "  %-12s libripgrep.so %s\n" "$abi" "$(du -h "$APP/jniLibs/$abi/libripgrep.so" | cut -f1)"
  else
    echo "  警告: 缺 ripgrep 产物 $rg_src（先跑 build-ripgrep-android.sh $aarch）；" >&2
    echo "        glob / grep 工具会报 ripgrep launch failed。" >&2
  fi

  # CPython 解释器：标准库由下面的 python-runtime.pkg 提供，这里只放可执行文件。
  if [[ -f "$py_src" ]]; then
    cp -f "$py_src" "$APP/jniLibs/$abi/libpython3.so"
    chmod 755 "$APP/jniLibs/$abi/libpython3.so"
    printf "  %-12s libpython3.so %s\n" "$abi" "$(du -h "$APP/jniLibs/$abi/libpython3.so" | cut -f1)"
  else
    echo "  警告: 缺 python3 产物 $py_src（先跑 build-python-android.sh $aarch）；" >&2
    echo "        agent 的 shell 里不会有 python3。" >&2
  fi

  # jsrun 启动器：把「node + JS 入口」包装成真正可执行的命令（见 native/jsrun.c）。
  # dsh-market 之类按 PATH 找 `pnpm` 可执行文件的工具，靠的就是它。
  local jsrun_dir="$TC/build/jsrun-android-$aarch"
  if [[ ! -f "$jsrun_dir/libpnpm.so" ]]; then
    echo "  缺少 jsrun 启动器，先跑 ./scripts/build-jsrun-android.sh $arch" >&2
    exit 1
  fi
  for name in libpnpm.so libpnpx.so libnpm.so; do
    cp -f "$jsrun_dir/$name" "$APP/jniLibs/$abi/$name"
    chmod 755 "$APP/jniLibs/$abi/$name"
  done
  printf "  %-12s lib{pnpm,pnpx,npm}.so %s each\n" "$abi" "$(du -h "$jsrun_dir/libpnpm.so" | cut -f1)"
}

echo "==> 1/2 jniLibs"
copy_abi "arm64-v8a" "arm64"  "aarch64-linux-android"
copy_abi "x86_64"    "x86_64" "x86_64-linux-android"

echo "==> 2/3 assets/dsh-runtime.pkg"
# 这些是 prepare-dsh-android.sh 生成/编译出来的 Android 专有产物。缺任何一个都
# 会打出一个「装得上、起不来」的 APK —— 而且失败点离原因很远（比如 require-builtin
# 缺失只在启动时报 `No usable native binding found`）。所以这里直接判死。
#
# 特别容易踩的坑：在 staging 里跑 `npm install`（比如新加一个依赖）时，npm 会把这些
# 「不在 package.json 里的多余包」当成垃圾清掉。加完依赖记得重跑
# prepare-dsh-android.sh 的两个架构。
missing=0
for m in "@koromix/koffi-android-arm64" "@koromix/koffi-android-x64" \
         "@deepseek-ai/node-addon-system-android-arm64" "@deepseek-ai/node-addon-system-android-x64" \
         "node-addon-require-builtin-android-arm64" "node-addon-require-builtin-android-x64" \
         "node-pty/prebuilds/android-arm64" "node-pty/prebuilds/android-x64"; do
  if [[ ! -e "$NM/$m" ]]; then
    echo "  缺少: $m" >&2
    missing=$((missing + 1))
  fi
done
if (( missing > 0 )); then
  echo "  上面 $missing 项缺失，先跑这两个（顺序无所谓）：" >&2
  echo "    ./scripts/prepare-dsh-android.sh $NM x86_64" >&2
  echo "    ./scripts/prepare-dsh-android.sh $NM arm64" >&2
  exit 1
fi

mkdir -p "$APP/assets"
# -C 切到 node_modules 的父目录，让归档内路径是 node_modules/...
# 排除 .bin（全是符号链接，Android 上创建不了；dsh 用 package.json 的 bin 字段解析入口）
tar czf "$APP/assets/dsh-runtime.pkg" \
  -C "$(dirname "$NM")" \
  --exclude='.bin' --exclude='.cache' --exclude='*.tsbuildinfo' \
  "$(basename "$NM")"
printf "  dsh-runtime.pkg %s\n" "$(du -h "$APP/assets/dsh-runtime.pkg" | cut -f1)"

echo "==> 3/3 assets/python-runtime.pkg"
# 归档里按 ABI 分目录，app 只解压当前设备那一份（见 DshRuntime.extractPython）。
# 纯 Python 标准库两份完全相同，但 gzip 跨文件不去重，分开能让 APK 少十几 MB。
PY_STAGE="$TC/build/python-stage"
rm -rf "$PY_STAGE"
mkdir -p "$PY_STAGE"
py_abis=()
for pair in "arm64-v8a:arm64" "x86_64:x86_64"; do
  abi="${pair%%:*}"; aarch="${pair#*:}"
  root="$TC/build/python-android-$aarch"
  [[ -d "$root/lib" ]] || { echo "  警告: 缺 $root/lib（先跑 build-python-android.sh $aarch）" >&2; continue; }
  mkdir -p "$PY_STAGE/$abi"
  # 硬链接而不是复制：同一文件系统上是瞬时的，也不占额外空间
  cp -al "$root/lib" "$PY_STAGE/$abi/lib" 2>/dev/null || cp -a "$root/lib" "$PY_STAGE/$abi/lib"
  py_abis+=("$abi")
done
if [[ ${#py_abis[@]} -gt 0 ]]; then
  tar czf "$APP/assets/python-runtime.pkg" -C "$PY_STAGE" "${py_abis[@]}"
  printf "  python-runtime.pkg %s\n" "$(du -h "$APP/assets/python-runtime.pkg" | cut -f1)"
  rm -rf "$PY_STAGE"
else
  rm -f "$APP/assets/python-runtime.pkg"
  echo "  跳过：没有可用的 python 产物" >&2
fi

echo
echo "==> app/src/main 内容："
find "$APP/jniLibs" "$APP/assets" -type f 2>/dev/null | while read -r f; do
  printf "    %-58s %s\n" "${f#"$ROOT"/}" "$(du -h "$f" | cut -f1)"
done
