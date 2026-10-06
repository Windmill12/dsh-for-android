#!/usr/bin/env bash
# 交叉编译 GNU bash for Android（静态链接、自包含、单文件可执行）。
#
# 用法:
#   ./scripts/build-bash-android.sh <arch>
#     <arch> = arm64 | x86_64 | all
#
# 例:  ./scripts/build-bash-android.sh x86_64
#      ./scripts/build-bash-android.sh all
#
# 产物（恰好这两个路径；prepare-app-assets.sh 会把它拷成 app 的 libbash.so）:
#   .toolchain/build/bash-android-arm64/bash
#   .toolchain/build/bash-android-x86_64/bash
#
# 为什么静态链接：Android 只允许从 nativeLibraryDir（只读、apk 标签）执行文件，
# 所以 bash 必须以 `libbash.so` 的名义随 jniLibs 分发（见 prepare-app-assets.sh）。
# 动态链接要走 Android 的 linker + app 命名空间，静态单文件最省事，代价是体积
# 约 1.6MB。
#
# ---------------------------------------------------------------------------
# Android/bionic 交叉编译 bash 的坑（都已在本脚本里处理）:
#
# 1) bash 自带的 malloc 用 sbrk()。Android 上 sbrk 早已不可用（bionic 只留了个
#    返回 -1 的桩），必须 --without-bash-malloc 改用 bionic 的 malloc。
# 2) 交叉编译时 configure 的一堆 AC_TRY_RUN 探针跑不了，默认值大多不合适：
#    getcwd/mktime 的默认值会去编 bash 自带的替换实现，named_pipes/unusable_rtsigs
#    的默认值会让 bash 功能退化（进程替换、实时信号）。全部用 *_cv_* 缓存变量
#    钉死，逐条理由见下面注释。
# 3) 宿主机的 libtinfo/libncurses 会被误选进 TERMCAP_LIB 导致交叉链接失败，
#    强制 bash_cv_termcap_lib=gnutermcap 用 bash 自带的 lib/termcap。
#    代价是 lib/termcap/tparam.c 需要一行小补丁（见 patch_source）。
# 4) bash 的构建期工具（mksignames/mksyntax/bashversion）必须用宿主编译器编译，
#    否则交叉编译器产出 ARM 二进制、在 x86_64 主机上跑不起来 -> 显式给
#    CC_FOR_BUILD=gcc。
# 5) 静态链接要同时给 LDFLAGS=-static（进 BASE_LDFLAGS）和 --enable-static-link
#    （在 linux 上只设 STATIC_LD=-static，两者都会进最终链接行）。
#    readline 保持启用（内置版本），交互式终端 UI 需要行编辑。
# ---------------------------------------------------------------------------
set -euo pipefail

ARCH="${1:?用法: build-bash-android.sh <arm64|x86_64|all>}"

# bash 5.2 是已知可用版本；5.2.37 是 5.2 系列最后一个补丁版（2024-09）。
BASH_VER="${DSH_BASH_VERSION:-5.2.37}"
BASH_TARBALL="bash-${BASH_VER}.tar.gz"
# 下载校验：默认版本用两个可达镜像（tuna / aliyun）交叉校验过的一致哈希。
# 换版本时用 DSH_BASH_SHA256=... 覆盖；留空则跳过校验（只做 gzip 完整性检查）。
BASH_SHA256="${DSH_BASH_SHA256:-}"
if [[ -z "$BASH_SHA256" && "$BASH_VER" = 5.2.37 ]]; then
  BASH_SHA256="9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff"
fi
API="${DSH_BASH_API:-26}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC="$ROOT/.toolchain"
NDK="$TC/sdk/ndk/29.0.14206865"
LLVM="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
DL="$TC/downloads"
BUILDROOT="$TC/build"
PRISTINE="$BUILDROOT/bash-$BASH_VER"
NPROC="$(nproc)"

MIRRORS=(
  "${DSH_BASH_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/gnu/bash}"
  "https://mirrors.aliyun.com/gnu/bash"
  "https://mirrors.tuna.tsinghua.edu.cn/gnu/bash"
)

log() { echo "==> $*"; }
die() { echo "错误: $*" >&2; exit 1; }

[[ -d "$NDK" ]] || die "找不到 NDK: $NDK（先 source scripts/env.sh 并确认 .toolchain 完整）"
[[ -x "$LLVM/bin/llvm-strip" ]] || die "找不到 NDK LLVM 工具链: $LLVM/bin"
for t in curl tar sha256sum readelf file make; do
  command -v "$t" >/dev/null 2>&1 || die "宿主机缺少必要工具: $t"
done

# ---------------------------------------------------------------------------
# 1) 下载（已存在且校验通过则跳过） + 解包（只做一次，两个 arch 共用）
# ---------------------------------------------------------------------------
sha_ok() {   # $1=文件；BASH_SHA256 为空时退化为 gzip 完整性检查
  if [[ -n "$BASH_SHA256" ]]; then
    echo "$BASH_SHA256  $1" | sha256sum -c --status 2>/dev/null
  else
    gzip -t "$1" 2>/dev/null
  fi
}

fetch_source() {
  mkdir -p "$DL" "$BUILDROOT"
  local tgz="$DL/$BASH_TARBALL"

  if [[ -f "$tgz" ]] && sha_ok "$tgz"; then
    log "已存在校验通过的源码包: $tgz"
  else
    rm -f "$tgz"
    local url ok=no
    for url in "${MIRRORS[@]}"; do
      log "下载 $url/$BASH_TARBALL"
      if curl -fSL --retry 3 --connect-timeout 20 -o "$tgz.part" "$url/$BASH_TARBALL"; then
        mv -f "$tgz.part" "$tgz"
        ok=yes
        break
      fi
      rm -f "$tgz.part"
      echo "    镜像不可用，换下一个" >&2
    done
    [[ "$ok" = yes ]] || die "所有镜像都下载失败: ${MIRRORS[*]}"
    sha_ok "$tgz" || die "源码包校验失败: $tgz（期望 sha256=$BASH_SHA256）"
    log "源码包校验通过"
  fi

  if [[ -f "$PRISTINE/configure" && -f "$PRISTINE/Makefile.in" ]]; then
    log "源码已解包: $PRISTINE"
  else
    log "解包到 $BUILDROOT"
    rm -rf "$PRISTINE" "$BUILDROOT/bash-$BASH_VER.tmp"
    mkdir -p "$BUILDROOT/bash-$BASH_VER.tmp"
    tar -xzf "$tgz" -C "$BUILDROOT/bash-$BASH_VER.tmp"
    mv "$BUILDROOT/bash-$BASH_VER.tmp/bash-$BASH_VER" "$PRISTINE"
    rmdir "$BUILDROOT/bash-$BASH_VER.tmp"
  fi
}

# ---------------------------------------------------------------------------
# 2) 单个 arch 的 configure + make + install/strip
# ---------------------------------------------------------------------------

# bionic 适配补丁。作用在"每个 arch 一份"的新拷贝上，所以天然幂等。
patch_source() {
  local src="$1"

  # lib/termcap/tparam.c 在内存耗尽分支里调用 write()，但这个文件只包含了
  # <config.h>/<stdlib.h>/<string.h>/"ltcap.h"。glibc 下 write 通过间接包含可见，
  # bionic 下不可见，而 NDK clang 20 把隐式函数声明当错误：
  #   error: call to undeclared function 'write'
  # 只有用 bash 自带 lib/termcap（我们强制 bash_cv_termcap_lib=gnutermcap）时才会
  # 编到这个文件，所以补一行 <unistd.h> 即可，不动其它任何代码。
  local tp="$src/lib/termcap/tparam.c"
  if [[ -f "$tp" ]] && ! grep -q '#include <unistd.h>' "$tp"; then
    sed -i 's|^#include "ltcap.h"|#include <unistd.h>\n#include "ltcap.h"|' "$tp"
    echo "  [patch] lib/termcap/tparam.c: 补 #include <unistd.h>"
  else
    echo "  [skip] lib/termcap/tparam.c 已处理"
  fi
}

build_arch() {
  local arch="$1" triple out src
  case "$arch" in
    arm64)  triple="aarch64-linux-android" ;;
    x86_64) triple="x86_64-linux-android" ;;
    *) die "不支持的 arch: $arch（只支持 arm64 / x86_64）" ;;
  esac

  out="$BUILDROOT/bash-android-$arch"          # 交付目录：$out/bash
  src="$BUILDROOT/bash-$BASH_VER-$arch"        # 每个 arch 一份独立源码树（原地构建）

  log "[$arch] 准备独立源码树 $src"
  rm -rf "$src"
  cp -a "$PRISTINE" "$src"
  log "[$arch] 应用 Android/bionic 适配补丁"
  patch_source "$src"

  # --- 交叉工具链 ---
  export CC="$LLVM/bin/${triple}${API}-clang"
  export AR="$LLVM/bin/llvm-ar"
  export RANLIB="$LLVM/bin/llvm-ranlib"
  export STRIP="$LLVM/bin/llvm-strip"
  export NM="$LLVM/bin/llvm-nm"
  export OBJCOPY="$LLVM/bin/llvm-objcopy"
  # 构建期工具（mksignames 等）跑在 x86_64 宿主上，必须用宿主编译器。
  export CC_FOR_BUILD="${CC_FOR_BUILD:-gcc}"
  export CFLAGS_FOR_BUILD="-O2"
  export LDFLAGS_FOR_BUILD=""
  export LIBS_FOR_BUILD=""

  export CFLAGS="-O2"
  export LDFLAGS="-static"                      # 进 BASE_LDFLAGS，真正的静态链接
  export ac_cv_func_working_mktime=yes          # 交叉默认 no -> 会去编 lib/sh/mktime.c
  export ac_cv_func_mmap_fixed_mapped=yes       # bionic 的 MAP_FIXED 可用
  export ac_cv_func_setvbuf_reversed=no
  # bionic 的 getrandom()/getentropy() 声明被 __BIONIC_AVAILABILITY_GUARD(28) 挡住
  # （我们只声明 API 26，虽然两台测试机都是 API 36）。configure 的 AC_CHECK_FUNCS
  # 自己补了 `char getrandom();` 原型，所以静态链接测试能过，于是 config.h 里
  # HAVE_GETRANDOM/HAVE_GETENTROPY 被打开；但真正编译 lib/sh/random.c 时没有
  # <sys/random.h> 里的声明，clang 20 直接报 implicit-function-declaration 错误。
  # 关掉这两个探测，bash 会用它自带的 /dev/urandom 模拟实现，在 API 26 上同样正确。
  export ac_cv_func_getrandom=no
  export ac_cv_func_getentropy=no
  # bionic 的 faccessat() 会把 AT_EACCESS 当成非法 flag 直接返回 EINVAL
  # （内核的旧 faccessat 系统调用不支持它；glibc 是在用户态模拟的，bionic 没有）。
  # bash 的 lib/sh/eaccess.c 只要 HAVE_FACCESSAT 打开就优先走
  #   faccessat(AT_FDCWD, path, mode, AT_EACCESS)
  # 于是 test -r / test -w / test -x 在设备上一律返回假（实测：
  # access()=0 而 faccessat(...,AT_EACCESS)=-1/EINVAL）。
  # 关掉这个探测后 bash 退回 access(2)，在 bionic 上行为正确
  # （uid!=euid 时它还有 setreuid 交换的 sh_euidaccess 兜底）。
  export ac_cv_func_faccessat=no

  # --- bash 自己的 run-time 探针：交叉编译时的默认值（见 configure 里的 WARNING）---
  # 其中 getcwd/mktime 两个默认值会走 LIBOBJS 替换实现，必须纠正；
  # named_pipes / unusable_rtsigs 的默认值会让 bash 功能退化（进程替换、RT 信号），
  # 也必须纠正。
  export bash_cv_getcwd_malloc=yes              # 默认 no -> #define GETCWD_BROKEN + lib/sh/getcwd.c
  export bash_cv_func_sigsetjmp=present         # bionic 有 sigsetjmp/siglongjmp
  export bash_cv_wcwidth_broken=no
  export bash_cv_job_control_missing=present    # 有 tcgetpgrp/waitpid/TIOCSPGRP
  export bash_cv_sys_named_pipes=present        # 默认 missing -> 进程替换被关掉
  export bash_cv_must_reinstall_sighandlers=no  # bionic 的 sigaction 是 BSD 语义，无需重装
  export bash_cv_unusable_rtsigs=no             # 默认 yes -> 实时信号被当成不可用
  export bash_cv_wcontinued_broken=no
  export bash_cv_dup2_broken=no
  export bash_cv_pgrp_pipe=no
  export bash_cv_opendir_not_robust=no
  export bash_cv_func_strcoll_broken=no
  export bash_cv_printf_a_format=yes            # bionic 的 printf 支持 %a
  export bash_cv_func_snprintf=yes
  export bash_cv_func_vsnprintf=yes
  # Android 上 /dev/fd、/dev/stdin 都是 -> /proc/self/fd 的符号链接（两代真机/模拟器均已确认）。
  export bash_cv_dev_fd=standard
  export bash_cv_dev_stdin=present
  # 绝不使用宿主机上的 libtinfo/libncurses：强制用 bash 自带的 lib/termcap。
  export bash_cv_termcap_lib=gnutermcap

  log "[$arch] configure (host=$triple, API=$API, prefix=/, 静态链接)"
  (
    cd "$src"
    ./configure \
      --host="$triple" \
      --prefix=/ \
      --without-bash-malloc \
      --disable-nls \
      --enable-static-link \
      --enable-readline \
      --enable-process-substitution \
      --enable-net-redirections \
      --enable-progcomp \
      --enable-history \
      --disable-profiling \
      --with-installed-readline=no
  )

  log "[$arch] make -j$NPROC"
  make -C "$src" -j"$NPROC"

  log "[$arch] make install (DESTDIR=$out/stage) + strip"
  rm -rf "$out"
  mkdir -p "$out"
  make -C "$src" install DESTDIR="$out/stage" >/dev/null

  install -m 0755 "$out/stage/bin/bash" "$out/bash"
  "$STRIP" --strip-all "$out/bash"

  # --- 自检：必须是静态 ELF、没有 NEEDED、没有程序解释器 ---
  local machine needed interp
  machine="$(readelf -h "$out/bash" | awk -F: '/Machine:/ {gsub(/^ +/,"",$2); print $2}')"
  needed="$(readelf -d "$out/bash" 2>/dev/null | grep -c NEEDED || true)"
  interp="$(readelf -lW "$out/bash" | grep -c 'INTERP' || true)"
  echo "    Machine=$machine  NEEDED=$needed  INTERP=$interp"
  [[ "$needed" = 0 ]] || die "$out/bash 不是静态链接（有 NEEDED 项）"
  [[ "$interp" = 0 ]] || die "$out/bash 带有程序解释器（不是静态可执行）"
  case "$arch" in
    arm64)  [[ "$machine" = "AArch64" ]] || die "$out/bash 架构不对: $machine" ;;
    x86_64) [[ "$machine" = "Advanced Micro Devices X86-64" ]] || die "$out/bash 架构不对: $machine" ;;
  esac

  # 交付目录里只保留 bash 本体（安装树 stage/ 用完即删）。
  rm -rf "$out/stage"

  echo
  echo "==> 产物: $out/bash"
  ls -l "$out/bash"
  file "$out/bash" || true
  echo
}

case "$ARCH" in
  all)     fetch_source; build_arch arm64; build_arch x86_64 ;;
  arm64|x86_64) fetch_source; build_arch "$ARCH" ;;
  *) die "不支持的 arch: $ARCH（只支持 arm64 / x86_64 / all）" ;;
esac

log "完成"
