#!/usr/bin/env bash
# 第 1 步：下载并解压 JDK 21 与 Android cmdline-tools 到 .toolchain/。
#
# 注意：本机到 github.com / services.gradle.org 直连超时，因此 JDK 走清华 TUNA 的
# Adoptium 镜像，Android 官方仓库（dl.google.com）可直连。
#
# 用法:  ./scripts/bootstrap-toolchain.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC="$ROOT/.toolchain"
DL="$TC/downloads"

# https://mirrors.tuna.tsinghua.edu.cn/Adoptium/21/jdk/x64/linux/
JDK_URL="https://mirrors.tuna.tsinghua.edu.cn/Adoptium/21/jdk/x64/linux/OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz"
# 最新版可查 https://dl.google.com/android/repository/repository2-3.xml
CLT_URL="https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip"

mkdir -p "$DL" "$TC/jdk" "$TC/sdk/cmdline-tools"

echo "[1/2] JDK 21 (Temurin 21.0.12.1+1, TUNA 镜像) ..."
curl -fL --no-progress-meter --retry 5 --retry-delay 2 -C - \
  -o "$DL/jdk21.tar.gz" "$JDK_URL" \
  -w "      %{size_download} bytes @ %{speed_download} B/s\n"
rm -rf "$TC/jdk"; mkdir -p "$TC/jdk"
tar -xzf "$DL/jdk21.tar.gz" -C "$TC/jdk" --strip-components=1
"$TC/jdk/bin/javac" -version

echo "[2/2] Android cmdline-tools (dl.google.com) ..."
curl -fL --no-progress-meter --retry 5 --retry-delay 2 -C - \
  -o "$DL/cmdline-tools.zip" "$CLT_URL" \
  -w "      %{size_download} bytes @ %{speed_download} B/s\n"
rm -rf "$TC/tmp-clt" "$TC/sdk/cmdline-tools/latest"
mkdir -p "$TC/tmp-clt"
unzip -q "$DL/cmdline-tools.zip" -d "$TC/tmp-clt"
mv "$TC/tmp-clt/cmdline-tools" "$TC/sdk/cmdline-tools/latest"
rm -rf "$TC/tmp-clt"

echo "完成。接着运行 ./scripts/install-sdk-packages.sh"
