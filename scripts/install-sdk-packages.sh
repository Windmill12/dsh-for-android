#!/usr/bin/env bash
# 第 2 步：用 sdkmanager 安装 Android SDK 组件，并创建一个 x86_64 模拟器。
#
# 用法:  ./scripts/install-sdk-packages.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC="$ROOT/.toolchain"
export JAVA_HOME="$TC/jdk"
export ANDROID_HOME="$TC/sdk"
export ANDROID_SDK_ROOT="$TC/sdk"
export ANDROID_AVD_HOME="$TC/avd"
SM="$TC/sdk/cmdline-tools/latest/bin/sdkmanager"

# 组件清单（安装后约 8GB）
#   platform-tools                          adb / fastboot
#   platforms;android-36                    compileSdk 36
#   build-tools;36.1.0                      aapt2 / d8 / apksigner / zipalign
#   emulator                                QEMU 模拟器
#   ndk;29.0.14206865                       交叉编译 Node.js 用（16KB page size 需 r28+）
#   cmake;3.31.6                            native 构建
#   system-images;...;x86_64                Android 16 模拟器镜像
PACKAGES=(
  "platform-tools"
  "platforms;android-36"
  "build-tools;36.1.0"
  "emulator"
  "ndk;29.0.14206865"
  "cmake;3.31.6"
  "system-images;android-36;google_apis;x86_64"
)

echo ">>> 接受 SDK 许可协议"
yes | "$SM" --licenses >/dev/null 2>&1 || true

echo ">>> 安装组件"
"$SM" --install "${PACKAGES[@]}"

echo ">>> 创建 AVD: dsh_x86_64"
mkdir -p "$ANDROID_AVD_HOME"
if ! "$TC/sdk/emulator/emulator" -list-avds | grep -qx "dsh_x86_64"; then
  echo "no" | "$TC/sdk/cmdline-tools/latest/bin/avdmanager" create avd \
    -n "dsh_x86_64" \
    -k "system-images;android-36;google_apis;x86_64" \
    -d "pixel_7" --force
fi

echo ">>> 完成。可用 AVD:"
"$TC/sdk/emulator/emulator" -list-avds
