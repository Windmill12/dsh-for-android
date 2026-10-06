#!/usr/bin/env bash
# 编译 jsrun 启动器（native/jsrun.c），产出：
#   .toolchain/build/jsrun-android-<arch>/libpnpm.so
#   .toolchain/build/jsrun-android-<arch>/libnpm.so
#   .toolchain/build/jsrun-android-<arch>/libpnpx.so
#
# 用法: ./scripts/build-jsrun-android.sh <arm64|x86_64|all>
#
# 为什么是三个 .so：启动器要靠 /proc/self/exe 找到同目录的 libnode.so，
# 而 /proc/self/exe 给的是**符号链接解析之后**的目标，分不出「当初是以哪个名字
# 被调用的」。所以每个命令编一份，各自用 -D 写死自己的入口（见 native/jsrun.c）。
# 体积只有几十 KB，重复几份无所谓。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC="$ROOT/.toolchain"
NDK="$TC/sdk/ndk/29.0.14206865"
LLVM="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
SRC="$ROOT/native/jsrun.c"
API="${DSH_JSRUN_API:-26}"

# app 私有目录。运行时优先读环境变量，这只是环境变量缺席时的兜底，
# 所以写死 /data/data/<pkg>（它是 /data/user/0/<pkg> 的别名）。
APP_DATA="${DSH_APP_DATA_DIR:-/data/data/com.androiddsh/files}"

target="${1:-all}"
[[ -f "$SRC" ]] || { echo "找不到 $SRC" >&2; exit 1; }
[[ -d "$LLVM" ]] || { echo "找不到 NDK: $LLVM" >&2; exit 1; }

build_one() {
  local arch="$1" triple out

  case "$arch" in
    arm64)  triple="aarch64-linux-android" ;;
    x86_64) triple="x86_64-linux-android" ;;
    *) echo "不支持的 arch: $arch（只支持 arm64 / x86_64）" >&2; return 1 ;;
  esac

  out="$TC/build/jsrun-android-$arch"
  mkdir -p "$out"

  local cc="$LLVM/bin/${triple}${API}-clang"

  # 每个命令一份，字段顺序：产物名|显示名|入口环境变量|入口相对路径|固定前置参数
  local specs=(
    "libpnpm.so|pnpm|ANDROIDDSH_PNPM_ENTRY|rt/node_modules/pnpm/bin/pnpm.cjs|"
    "libpnpx.so|pnpx|ANDROIDDSH_PNPM_ENTRY|rt/node_modules/pnpm/bin/pnpm.cjs|dlx"
    "libnpm.so|npm|ANDROIDDSH_NPM_ENTRY|rt/node_modules/npm/bin/npm-cli.js|"
  )

  local spec name shown entry_env entry_rel extra_a
  for spec in "${specs[@]}"; do
    IFS='|' read -r name shown entry_env entry_rel extra_a <<<"$spec"

    "$cc" -O2 -Wall -Wextra -fPIE -pie \
      -D"JSRUN_NAME=\"$shown\"" \
      -D"JSRUN_ENTRY_ENV=\"$entry_env\"" \
      -D"JSRUN_ENTRY_DEFAULT=\"$APP_DATA/$entry_rel\"" \
      -D"JSRUN_EXTRA_1=\"$extra_a\"" \
      -o "$out/$name" "$SRC"

    chmod 755 "$out/$name"
    printf "  %-12s %-14s %s\n" "$arch" "$name" "$(du -h "$out/$name" | cut -f1)"
  done

  # 宿主上跑不了（是 Android 二进制），只确认格式与架构
  if command -v file >/dev/null 2>&1; then
    file "$out"/*.so | sed 's/^/    /'
  fi
}

case "$target" in
  arm64)  build_one arm64 ;;
  x86_64) build_one x86_64 ;;
  all)    build_one arm64; build_one x86_64 ;;
  *) echo "用法: $0 <arm64|x86_64|all>" >&2; exit 1 ;;
esac

echo "==> jsrun 启动器完成：$TC/build/jsrun-android-$target"
