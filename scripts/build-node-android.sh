#!/usr/bin/env bash
# 交叉编译 Node.js for Android。
#
# 用法:
#   ./scripts/build-node-android.sh <arch> [stage]
#     <arch>  = x86_64 | arm64          (x86_64 给模拟器，arm64 给真机)
#     [stage] = configure | make | all   (默认 all)
#
# 例:  ./scripts/build-node-android.sh x86_64 configure
#      ./scripts/build-node-android.sh x86_64 make
#
# 产物: .toolchain/build/node-<ver>-android-<arch>/out/Release/node
#
# 说明：Node 22.x 自带 android_configure.py，会应用 deps/v8 的 trap-handler patch
# （Android 上 V8 的信号式 OOB 检测不可用），然后用 NDK clang 交叉编译。
# 不依赖 Termux 的 patch 集。
set -euo pipefail

ARCH="${1:?用法: build-node-android.sh <x86_64|arm64> [configure|make|all]}"
STAGE="${2:-all}"

NODE_VERSION="${DSH_NODE_VERSION:-22.23.3}"
API="${DSH_NODE_API:-26}"

# 为什么不能低于 22.18.0：DSH 的 CLI 入口用 `if (import.meta.main) await runCli()`
# 决定是否执行，而 import.meta.main 是 Node v24.2.0 / v22.18.0 才加入的。
# 用 22.16.0 构建出来的 node 上该属性是 undefined，dsh 会静默退出（exit=0、无输出）。

case "$ARCH" in
  x86_64) DEST_CPU="x64";   GYP_ARCH="x64";   TOOLCHAIN_PREFIX="x86_64-linux-android" ;;
  arm64)  DEST_CPU="arm64"; GYP_ARCH="arm64"; TOOLCHAIN_PREFIX="aarch64-linux-android" ;;
  *) echo "不支持的 arch: $ARCH（只支持 x86_64 / arm64）" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC="$ROOT/.toolchain"
NDK="$TC/sdk/ndk/29.0.14206865"
SRC="$TC/build/node-v$NODE_VERSION"
OUT="$TC/build/node-v$NODE_VERSION-android-$ARCH"
NPROC="$(nproc)"

[[ -d "$NDK" ]] || { echo "找不到 NDK: $NDK" >&2; exit 1; }
[[ -d "$SRC" ]] || { echo "找不到 Node 源码: $SRC" >&2; exit 1; }

LLVM="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
export PATH="$LLVM/bin:$PATH"

# --- 目标（Android）工具链 ---
export CC="$LLVM/bin/${TOOLCHAIN_PREFIX}${API}-clang"
export CXX="$LLVM/bin/${TOOLCHAIN_PREFIX}${API}-clang++"
export AR="$LLVM/bin/llvm-ar"
export RANLIB="$LLVM/bin/llvm-ranlib"
export STRIP="$LLVM/bin/llvm-strip"
export LD="$LLVM/bin/ld.lld"
export NM="$LLVM/bin/llvm-nm"
export OBJCOPY="$LLVM/bin/llvm-objcopy"

# --- 宿主工具链（交叉编译 mksnapshot / torque / 各种 codegen 工具时用）---
export CC_host="gcc"
export CXX_host="g++"

# --- gyp ---
export GYP_DEFINES="target_arch=$GYP_ARCH v8_target_arch=$GYP_ARCH android_target_arch=$GYP_ARCH host_os=linux OS=android android_ndk_path=$NDK"

echo "==> Node $NODE_VERSION -> android/$ARCH (API $API, dest-cpu=$DEST_CPU)"
echo "    CC  = $CC"
echo "    OUT = $OUT"

# Android/bionic 适配补丁。都必须幂等：源码目录会被 x86_64 与 arm64 两次构建共用。
apply_android_patches() {
  # --- 1) libuv: LLONG_MAX 在 --std=gnu89 下不可用 ---
  # Node 用 gnu89 编译 C 源码，而 LLONG_MAX 是 C99 的。glibc 因为 _GNU_SOURCE
  # 会暴露它，bionic 不会，于是 linux.c 报 "use of undeclared identifier 'LLONG_MAX'"。
  # quota_per_period 本身是 int64_t，换成 INT64_MAX 语义完全等价。
  local uv_linux="$SRC/deps/uv/src/unix/linux.c"
  if grep -q 'constraint->quota_per_period = LLONG_MAX;' "$uv_linux"; then
    sed -i 's/constraint->quota_per_period = LLONG_MAX;/constraint->quota_per_period = INT64_MAX;/' "$uv_linux"
    echo "  [patch] deps/uv/src/unix/linux.c: LLONG_MAX -> INT64_MAX"
  fi

  # --- 2) V8 trap handler: host/target 判定不一致导致链接失败 ---
  # v8.gyp 里 trap-handler 源文件的条件只有 linux/mac/ios/freebsd（不含 android），
  # OS=="android" 时 handler-inside-posix.cc 不会进构建；而 host 侧 mksnapshot
  # 编译不带 __ANDROID__，会判定 trap handler 可用。结果链接报
  #   undefined symbol: v8::internal::trap_handler::TryHandleSignal
  # 等效于上游 android-patches/trap-handler.h.patch：统一禁用。
  # Android target 上游本来就是禁用状态，运行时行为不变。
  python3 - "$SRC/deps/v8/src/trap-handler/trap-handler.h" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if '#if V8_HOST_ARCH_X64' not in s:
    print('  [skip] deps/v8/src/trap-handler/trap-handler.h 已处理')
    sys.exit(0)
new, n = re.subn(
    r'#if V8_HOST_ARCH_X64.*?\n#endif\n',
    '#define V8_TRAP_HANDLER_SUPPORTED false  /* Android 交叉编译：见 scripts/build-node-android.sh */\n',
    s, count=1, flags=re.S)
if n != 1:
    print('  [WARN] trap-handler.h 未匹配到预期结构，未修改', file=sys.stderr)
    sys.exit(1)
p.write_text(new)
print('  [patch] deps/v8/src/trap-handler/trap-handler.h: V8_TRAP_HANDLER_SUPPORTED -> false')
PY

  # --- 3) zlib arm: android_getCpuFeatures 的实现没被链接（仅 arm/arm64 触发）---
  # common.gypi 在 OS=="android" 时只加了 cpufeatures 的 include 路径，没有加实现。
  # deps/zlib/zlib.gyp 的 zlib_arm_crc32 在 Android 上定义 ARMV8_OS_ANDROID，
  # 于是 cpu_features.c 会调用 NDK 的 android_getCpuFeatures()，链接报
  #   undefined symbol: android_getCpuFeatures
  # NDK 以源码形式提供该实现（sources/android/cpufeatures/cpu-features.c），补进该 target。
  # x86_64 不走这条 ARM 分支，所以只在 arm64 构建时才暴露。
  local zlib_gyp="$SRC/deps/zlib/zlib.gyp"
  # gyp 无法处理绝对路径的源文件（会拼出 obj.target/zlib_arm_crc32//home/... 这种
  # 重复路径，报 "No rule to make target"），所以先把 NDK 的 cpufeatures 拷进
  # zlib 目录，再用 <(ZLIB_ROOT) 相对路径引用。
  local cpf_dir="$SRC/deps/zlib/cpufeatures"
  if [[ ! -f "$cpf_dir/cpu-features.c" ]]; then
    mkdir -p "$cpf_dir"
    cp -f "$NDK/sources/android/cpufeatures/cpu-features.c" \
          "$NDK/sources/android/cpufeatures/cpu-features.h" "$cpf_dir/"
    echo "  [copy] NDK cpufeatures -> deps/zlib/cpufeatures/"
  fi
  if ! grep -q 'cpufeatures/cpu-features.c' "$zlib_gyp"; then
    python3 - "$zlib_gyp" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = """                ['OS=="win"', {
                  'defines': [ 'ARMV8_OS_WINDOWS' ],
                }],
              ],
              'defines': [ 'CRC32_ARMV8_CRC32' ],"""
new = """                ['OS=="win"', {
                  'defines': [ 'ARMV8_OS_WINDOWS' ],
                }],
                ['OS=="android"', {
                  'sources': [
                    '<(ZLIB_ROOT)/cpufeatures/cpu-features.c',
                  ],
                }],
              ],
              'defines': [ 'CRC32_ARMV8_CRC32' ],"""
if old not in s:
    print('  [WARN] zlib.gyp 未匹配到预期结构，未修改', file=sys.stderr)
    sys.exit(1)
p.write_text(s.replace(old, new, 1))
print('  [patch] deps/zlib/zlib.gyp: 补入 NDK cpufeatures/cpu-features.c')
PY
  else
    echo "  [skip] deps/zlib/zlib.gyp 已补入 cpufeatures"
  fi

  # --- 4) openssl: 交叉编译时误选 x86_64 的内联汇编 ---
  # configure 的 --openssl-no-asm 会写进 config.gypi，但 **不会**出现在
  # out/Makefile 的 regen_makefile 命令行里。一旦因改动 gyp 触发 Makefile 重新生成，
  # 该设置就丢了，openssl 于是选择 config/archs/linux-x86_64/asm_avx2/*.o 与
  # crypto/bn/asm/x86_64-gcc.c，用 arm64 的 clang 去编必然失败：
  #   error: invalid output constraint '=a' in asm
  # 这里直接在 gyp 层面强制 no-asm，不依赖 configure 传参。
  # 注意不能写成 target_arch!="x64"：regen 时 -I config.gypi 会覆盖 -Dtarget_arch，
  # 导致 target_arch 退回 x64 而条件失效（已踩过）。
  local ssl_gyp="$SRC/deps/openssl/openssl.gyp"
  if ! grep -q 'openssl_no_asm==1 or OS=="android"' "$ssl_gyp"; then
    python3 - "$ssl_gyp" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = """        [ 'openssl_no_asm==1', {
          'includes': ['./openssl_no_asm.gypi'],
        }, 'target_arch=="arm64" and OS=="win"', {"""
new = """        [ 'openssl_no_asm==1 or OS=="android"', {
          # 见 scripts/build-node-android.sh：Android 交叉编译强制 no-asm，
          # 不依赖 configure 的 --openssl-no-asm（regen_makefile 会丢失它）。
          'includes': ['./openssl_no_asm.gypi'],
        }, 'target_arch=="arm64" and OS=="win"', {"""
if old not in s:
    print('  [WARN] openssl.gyp 未匹配到预期结构，未修改', file=sys.stderr)
    sys.exit(1)
p.write_text(s.replace(old, new, 1))
print('  [patch] deps/openssl/openssl.gyp: Android 上强制 no-asm')
PY
  else
    echo "  [skip] deps/openssl/openssl.gyp 已强制 no-asm"
  fi
}

build_configure() {
  cd "$SRC"
  echo "==> 应用 Android 适配补丁"
  apply_android_patches
  # 2022 年的 android-patches/trap-handler.h.patch 已经过时：上游 V8 现在显式把
  # Android 排除在 trap handler 之外（V8_OS_LINUX && !V8_OS_ANDROID），
  # 直接应用会失败并留下 .rej，因此上面的 apply_android_patches 手工做等效修改。
  echo "==> configure"
  rm -rf "$SRC/out"
  ./configure \
    --dest-cpu="$DEST_CPU" \
    --dest-os=android \
    --cross-compiling \
    --openssl-no-asm
  echo "==> configure 完成"
}

build_make() {
  cd "$SRC"
  [[ -d "$SRC/out" ]] || { echo "还没有 configure，先跑 configure 阶段" >&2; exit 1; }
  # 只构建 node 可执行文件本身，不跑默认的 all：
  # all 里含 test/cctest，而它用了 aligned_alloc —— bionic 上要 API 28+，
  # 我们的目标是 API 26。cctest 与 Node 本体无关，跳过即可。
  # gyp 生成的 target 名就是产物绝对路径（见 node.target.mk）。
  echo "==> make -j$NPROC（只构建 node 本体，跳过 cctest 等测试目标）"
  make -C "$SRC/out" -j"$NPROC" BUILDTYPE=Release "$SRC/out/Release/node"

  # 归档到架构专属目录，便于 x86_64 与 arm64 产物共存（out/ 是固定的，会被下一次覆盖）
  echo "==> 归档产物到 $OUT"
  mkdir -p "$OUT"
  cp -a "$SRC/out/Release/node" "$OUT/" 2>/dev/null || true
  for f in "$SRC"/out/Release/*.so; do
    [[ -e "$f" ]] && cp -a "$f" "$OUT/" || true
  done
}

case "$STAGE" in
  configure) build_configure ;;
  make)      build_make ;;
  all)       build_configure; build_make ;;
  *) echo "未知 stage: $STAGE" >&2; exit 1 ;;
esac

if [[ -f "$OUT/Release/node" ]]; then
  echo "==> 产物:"
  ls -lh "$OUT/Release/node"
  file "$OUT/Release/node" 2>/dev/null || true
fi
