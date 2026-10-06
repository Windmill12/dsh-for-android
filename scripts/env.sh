#!/usr/bin/env bash
# AndroidDSH 本地工具链环境入口。
# 用法:  source scripts/env.sh
#
# 全部工具都装在工作区的 .toolchain/ 下（已加入 .gitignore），不依赖系统包管理器。

_DSH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export DSH_ROOT="$_DSH_ROOT"
export DSH_TOOLCHAIN="$_DSH_ROOT/.toolchain"

# --- JDK 21 (Temurin) ---
export JAVA_HOME="$DSH_TOOLCHAIN/jdk"

# --- Android SDK / NDK ---
export ANDROID_HOME="$DSH_TOOLCHAIN/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"

# --- AVD 与 Gradle 缓存也放工作区，保持自包含 ---
export ANDROID_AVD_HOME="$DSH_TOOLCHAIN/avd"
export GRADLE_USER_HOME="$DSH_TOOLCHAIN/gradle-home"

# --- 本项目使用的独立 Gradle 发行版 ---
export DSH_GRADLE="$DSH_TOOLCHAIN/gradle-dist/gradle-8.14.3/bin/gradle"

case ":$PATH:" in
  *":$JAVA_HOME/bin:"*) ;;
  *) PATH="$JAVA_HOME/bin:$PATH" ;;
esac
PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/emulator:$DSH_TOOLCHAIN/gradle-dist/gradle-8.14.3/bin:$PATH"
export PATH

# --- 国内镜像（GitHub / Maven Central / Gradle 官方源在本机不可达）---
export DSH_MAVEN_MIRROR_PUBLIC="https://maven.aliyun.com/repository/public"
export DSH_MAVEN_MIRROR_GOOGLE="https://maven.aliyun.com/repository/google"
export DSH_NPM_REGISTRY="https://registry.npmmirror.com"
