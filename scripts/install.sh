#!/usr/bin/env bash
# 构建 debug APK 并安装到设备。
#
# 用法:
#   ./scripts/install.sh phone         # 真机（自动挑第一个非 emulator-* 的设备）
#   ./scripts/install.sh emulator      # 模拟器
#   ./scripts/install.sh all           # 两个都装
#   ./scripts/install.sh <serial>      # 指定序列号，例如 ASQSUT4726000035
#
# 前提：.toolchain 已就绪（见 README），且 app/src/main 下已经有
# jniLibs/libnode.so 与 assets/dsh-runtime.pkg（由 prepare-app-assets.sh 生成）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=env.sh
source "$ROOT/scripts/env.sh"

TARGET="${1:-phone}"

# --- 选设备 -----------------------------------------------------------------
device_for() {
  case "$1" in
    emulator) adb devices | awk '/^emulator-[0-9]+\tdevice/ {print $1; exit}' ;;
    phone)    adb devices | awk '/\tdevice$/ && $1 !~ /^emulator-/ {print $1; exit}' ;;
    *)        echo "$1" ;;
  esac
}

APK_DIR="$ROOT/app/build/outputs/apk/debug"
DIST_DIR="$ROOT/dist"

# 把产物复制到 dist/ 并留个带版本号的稳定名字 —— build/ 会被 gradle clean 掉，
# 这里才是"想留着这个 apk"该看的地方。
publish_artifacts() {
  local version
  version="$(sed -n 's/.*versionName = "\(.*\)".*/\1/p' "$ROOT/app/build.gradle.kts")"
  mkdir -p "$DIST_DIR"
  local names=()
  for abi in arm64-v8a x86_64; do
    local src="$APK_DIR/app-$abi-debug.apk" dest="$DIST_DIR/AndroidDSH-$version-$abi.apk"
    [[ -f "$src" ]] || continue
    cp -f "$src" "$dest"
    names+=("$(basename "$dest")")
  done
  ( cd "$DIST_DIR" && sha256sum "${names[@]}" > SHA256SUMS.txt )
  echo "==> 已归档到 dist/（版本 $version）"
  ( cd "$DIST_DIR" && ls -la --time-style=+%H:%M *.apk && sed 's/^/    /' SHA256SUMS.txt )
}

# --- 构建 -------------------------------------------------------------------
echo "==> 构建 :app:assembleDebug"
"$DSH_GRADLE" --offline :app:assembleDebug
publish_artifacts

install_one() {
  local serial="$1" abi="$2"
  local apk="$APK_DIR/app-$abi-debug.apk"
  [[ -f "$apk" ]] || { echo "缺 APK: $apk" >&2; return 1; }
  echo "==> 安装到 $serial ($abi)"
  adb -s "$serial" install -r -d "$apk" | tail -1
  # 开发便利：直接把"所有文件访问"授权给 debug 包，省得每次手动去系统设置里点。
  # 正式分发时这一步不存在，用户在 app 首启弹窗里自己开。
  adb -s "$serial" shell appops set com.androiddsh MANAGE_EXTERNAL_STORAGE allow 2>/dev/null \
    && echo "    已授予 MANAGE_EXTERNAL_STORAGE（工作目录 = /sdcard/Documents/DSH）"
  adb -s "$serial" shell am force-stop com.androiddsh || true
  adb -s "$serial" shell am start -n com.androiddsh/.MainActivity >/dev/null
}

verify_one() {
  local serial="$1"
  echo "==> $serial: 等待 DSH 启动…"
  local i url
  for i in $(seq 1 60); do
    # 有些 ROM（例如 Honor）会把 logcat 内容抹掉，所以进程存活也算通过
    if adb -s "$serial" shell "ps -A | grep -q '[l]ibnode'" 2>/dev/null; then
      url="$(adb -s "$serial" logcat -d -s DshServer 2>/dev/null | grep -o 'http://127\.0\.0\.1:[0-9]*' | tail -1)"
      echo "   node 进程已就绪${url:+（$url）}"
      return 0
    fi
    sleep 2
  done
  echo "   没有看到 node 进程；看 logcat -s DshServer DshWeb" >&2
  return 1
}

targets=()
case "$TARGET" in
  all) targets=("$(device_for emulator)" "$(device_for phone)") ;;
  *)   targets=("$(device_for "$TARGET")") ;;
esac

for serial in "${targets[@]}"; do
  [[ -n "$serial" ]] || { echo "找不到设备" >&2; exit 1; }
  abi="$(adb -s "$serial" shell getprop ro.product.cpu.abi | tr -d '\r')"
  case "$abi" in
    arm64-v8a) apk_abi="arm64-v8a" ;;
    x86_64)    apk_abi="x86_64" ;;
    *) echo "不支持的 ABI: $abi" >&2; exit 1 ;;
  esac
  install_one "$serial" "$apk_abi"
done

for serial in "${targets[@]}"; do
  [[ -n "$serial" ]] && verify_one "$serial" || true
done
