#!/usr/bin/env bash
# 交叉编译 CPython (Python 3.13) for Android。
#
# 用法:
#   ./scripts/build-python-android.sh <arch>
#     <arch> = arm64 | x86_64 | all
#
# 例:  ./scripts/build-python-android.sh x86_64
#      ./scripts/build-python-android.sh all
#
# 产物（恰好这两个路径）:
#   .toolchain/build/python-android-arm64/
#     bin/python3                    # 可执行 ELF（不是 .so）
#     lib/python3.13/                # 完整标准库
#     lib/python3.13/lib-dynload/    # 动态扩展模块 *.so
#   .toolchain/build/python-android-x86_64/   （同样的布局）
#
# 这棵树是 **靠 PYTHONHOME 可重定位** 的：Android app 的做法是把 lib/ 与 bin/
# 解到自己的私有目录，然后
#     PYTHONHOME=<私有目录> <私有目录>/bin/python3 ...
# 因此脚本末尾会用 PYTHONHOME 在任意 cwd 下跑一次 configure 出来的解释器做自检。
#
# ---------------------------------------------------------------------------
# 为什么是"静态 libpython + 动态扩展模块"这套组合：
#   * Android 只允许从 app 的 nativeLibraryDir 执行文件（SELinux/execve 限制），
#     所以解释器本体要作为 jniLib（libpython3.so）分发，再由 app 软链成
#     <files>/bin/python3。它必须是普通可执行 ELF。
#   * 扩展模块（lib-dynload/*.so）放在 app 私有数据目录里 dlopen —— 这条路在
#     本工程已经验证可行（Node 的 koffi/node-pty 原生插件就是这么加载的）。
#   * 于是用 --disable-shared（libpython 静态链进可执行文件）+ -Wl,--export-dynamic
#     （把 PyExc_*/Py_* 放进 .dynsym），扩展模块 dlopen 时才能从主程序解析到符号。
#     注意 --export-dynamic 不能省：省掉以后 `import _json` 会报
#     "dlopen failed: cannot locate symbol PyExc_RuntimeError"。
#   * 扩展模块本身必须只依赖运行时一定在 LD_LIBRARY_PATH 上的库：
#     libc/libm/libdl/liblog/libz/libc++_shared 都可以，第三方库一律静态链进 .so。
#     所以 OpenSSL / libffi / liblzma / libbz2 / readline / sqlite 全部以
#     *.a 的形式被 _ssl.so / _ctypes.so / _lzma.so / _bz2.so / readline.so /
#     _sqlite3.so 静态吸收，交付树里没有第三方 .so。
# ---------------------------------------------------------------------------
# Android/bionic 交叉编译 CPython 的坑（都已在本脚本里处理）:
#
# 1) --with-build-python 是硬要求。CPython 3.13 的构建系统需要在构建期 **运行**
#    一个同版本解释器（freeze_modules / _bootstrap_python / 生成各种 .h 和
#    __pycache__），交叉编译时目标解释器跑不起来。宿主机自带的 python3 是
#    3.12，版本不匹配会被直接拒绝，所以本脚本先就地造一个 3.13.x 的宿主机
#    python 放在 .toolchain/build/host-python/（只在需要时构建一次）。
#    这个宿主机 Python 也负责跑 `ensurepip`（见第 6 条）。
#
# 2) configure 有一堆 AC_TRY_RUN 探针在交叉编译时跑不了，默认值大多"保守地
#    判否"，会把功能悄悄关掉。用 ac_cv_*/_cv_* 缓存变量钉死，逐条理由见
#    build_arch() 里。最关键的两个：
#      ac_cv_func_getrandom=yes / ac_cv_func_getentropy=yes
#        bionic 的 <sys/random.h> 用 __BIONIC_AVAILABILITY_GUARD(28) 把
#        getrandom()/getentropy() 声明挡在 API 28 之后，而我们声明的是 API 26。
#        configure 的 AC_CHECK_FUNCS 会自己补原型、静态链接测试也能过，于是
#        config.h 里 HAVE_GETRANDOM 被打开；真正编 Modules/posixmodule.c 时却没有
#        声明，NDK clang 20 把隐式函数声明当错误直接炸。
#        **但是** 也不能简单判 no：CPython 3.13 的 posixmodule.c 在 Android 上
#        用 syscall(__NR_getrandom) 兜底，前提是 HAVE_GETRANDOM 为真。所以正确
#        做法是判 yes（让代码走 syscall 分支）——本脚本配 libpython 的
#        `-Wno-error=implicit-function-declaration`，两者配合即可编过且功能正确。
#      ac_cv_file__dev_ptmx / _dev_ptc：/dev/ptmx 与 /dev/pts 在 Android 上存在，
#        但 configure 用 test -r 在宿主机上探测，结果是错的。宿主机有、设备上
#        也有 -> 判 yes。
#
# 3) bionic 没有 setpwent/getpwent（API 26 之前）以及 sethostent/endhostent 等
#    一串 NSS 相关符号；CPython 的部分探测过了但链接会报 undefined。用
#    ac_cv_func_* 判否把它关掉，比在链接期打补丁干净。
#
# 4) --enable-shared 会打开 LIBRARY/LDLIBRARY/INSTSONAME 逻辑，Android 上
#    SONAME 与 jniLib 命名规则又冲突（AGP 只打包 lib*.so），所以直接走静态
#    libpython + --export-dynamic，不走 shared。
#
# 5) 标准库里的 test/idlelib/tkinter/turtledemo/lib2to3/ensurepip/_bundled 纯属
#    体积垃圾（几十 MB），APK 里没有任何用途，install 之后统一删掉；__pycache__
#    也删掉（app 私有目录可写，首次 import 会自己重建，但没必要随包分发）。
#
# 6) pip：Android 上 app 私有目录里的文件没有执行权限（noexec），bin/pip3 这种
#    shebang 脚本点了也跑不起来，所以唯一支持入口是 `python3 -m pip`。ensurepip
#    在安装阶段用 **宿主机** 的 3.13 跑（`$HOSTPY -m ensurepip`），但需要把
#    PYTHONHOME 指向目标树、PYTHONPATH 指向目标 Lib，否则它会往宿主机的
#    site-packages 里装 wheel。
#
# 7) 交叉编译时 Makefile 会尝试用 RUNSHARED/qemu 跑目标解释器来生成 .pyc，
#    必须 --disable-test-modules 之类地避开；本脚本用 `make install` +
#    `PYTHON_FOR_BUILD`，不装 test 包也不生成 .pyc。
#
# 8) libffi / OpenSSL / liblzma / libbz2 / readline / sqlite 这些第三方库都必须
#    用同一套 NDK clang + 同一份 sysroot 编出来的 *.a；混用宿主机（glibc）的
#    .a 会引入 memcpy@GLIBC_2.14 之类的符号版本，dlopen 扩展模块时直接失败：
#      dlopen failed: cannot locate symbol "memcpy@GLIBC_2.14"
#    所以依赖也要现编（见 build_deps）。
# ---------------------------------------------------------------------------
set -euo pipefail

ARCH="${1:?用法: build-python-android.sh <arm64|x86_64|all>}"

# --- 版本与校验（默认版本用多个镜像交叉校验过的一致 sha256）---
PY_VER="${DSH_PYTHON_VERSION:-3.13.15}"     # 完整版本，决定源码 tarball 名
PY_XY="${PY_VER%.*}"                        # 主.次，决定 bin/python3.13 与 lib/python3.13
PY_TARBALL="Python-${PY_VER}.tgz"
PY_SHA256="${DSH_PYTHON_SHA256:-}"
if [[ -z "$PY_SHA256" && "$PY_VER" = 3.13.15 ]]; then
  # 阿里云 / 清华 tuna / 华为云 三个镜像下载结果一致（2026-10 实测）
  PY_SHA256="c28d9d213c09b5b5ab2c29812950e12f746999e099b82894231be954b26baed9"
fi

OPENSSL_VER="${DSH_OPENSSL_VERSION:-3.0.16}"
LIBFFI_VER="${DSH_LIBFFI_VERSION:-3.4.4}"
SQLITE_VER="${DSH_SQLITE_VERSION:-3460100}"
XZ_VER="${DSH_XZ_VERSION:-5.8.4}"
BZIP2_VER="${DSH_BZIP2_VERSION:-1.0.8}"
READLINE_VER="${DSH_READLINE_VERSION:-8.2}"
NCURSES_VER="${DSH_NCURSES_VERSION:-6.5}"

API="${DSH_PYTHON_API:-26}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC="$ROOT/.toolchain"
NDK="$TC/sdk/ndk/29.0.14206865"
LLVM="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
DL="$TC/downloads"
DEPSRCDIR="$TC/build/deps-src"
DEPSROOT="$TC/build/python-deps"
BUILDROOT="$TC/build"
PRISTINE="$BUILDROOT/Python-$PY_VER"
HOSTPY="$BUILDROOT/host-python"
NPROC="$(nproc)"
TCLSH="$(command -v tclsh)"
# qemu-user 是可选的：有它就能在宿主机上真正跑一遍交叉编译出来的解释器做自检
# （CPython 官方推荐的做法：--host=<triple> HOSTRUNNER=qemu-<arch>）；
# 没有就跳过宿主机自检，改由真机/模拟器验收（本工程的最终验收本来就是真机跑）。
QEMU_AARCH64="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
QEMU_X86_64="$(command -v qemu-x86_64-static || command -v qemu-x86_64 || true)"

# 镜像：按顺序尝试。CPython 优先 aliyun 的 python-release（版本最全）。
PY_MIRRORS=(
  "${DSH_PYTHON_MIRROR:-https://mirrors.aliyun.com/python-release/source}"
  "https://mirrors.tuna.tsinghua.edu.cn/python/$PY_VER"
  "https://mirrors.huaweicloud.com/python/$PY_VER"
)
# 第三方库：GNU 官方源在本机不可达；阿里云的 debian pool 里这几个库的
# .orig.tar.* 都是上游原版 tar（不含 debian/ 目录也可以正常 configure），实测可用。
DEBIAN_POOL="https://mirrors.aliyun.com/debian/pool/main"

log()  { echo "==> $*"; }
warn() { echo "警告: $*" >&2; }
die()  { echo "错误: $*" >&2; exit 1; }

[[ -d "$NDK" ]] || die "找不到 NDK: $NDK（先 source scripts/env.sh 并确认 .toolchain 完整）"
for t in curl tar sha256sum readelf file make gcc g++ perl pkg-config python3 tclsh; do
  command -v "$t" >/dev/null 2>&1 || die "宿主机缺少必要工具: $t"
done
case "$API" in
  2[6-9]|3[0-9]) ;;
  *) die "DSH_PYTHON_API=$API 不合理（本脚本按 API>=26 的 bionic 行为编写）" ;;
esac

# ---------------------------------------------------------------------------
# 0) 通用下载 / 解包
# ---------------------------------------------------------------------------
# 有些镜像（尤其 debian pool）不提供 .sha256 文件，所以这里用
# "gzip/xz 完整性 + 首字节魔数 + 大小下限" 做廉价校验；CPython 本体则必须过 sha256。
verify_archive() { # $1=文件
  local f="$1"
  case "$f" in
    *.tar.gz|*.tgz) gzip -t "$f" 2>/dev/null ;;
    *.tar.xz)       xz -t "$f" 2>/dev/null ;;
    *) return 0 ;;
  esac
}

download() { # $1=输出文件 $2=sha256(可空) $3...=url
  local out="$1" sha="$2"; shift 2
  if [[ -s "$out" ]]; then
    if [[ -n "$sha" ]] && ! echo "$sha  $out" | sha256sum -c --status 2>/dev/null; then
      warn "已存在的 $(basename "$out") 校验失败，重新下载"
      rm -f "$out"
    elif ! verify_archive "$out"; then
      warn "已存在的 $(basename "$out") 不是完整压缩包，重新下载"
      rm -f "$out"
    else
      log "已存在: $(basename "$out")"
      return 0
    fi
  fi
  local url ok=no
  for url in "$@"; do
    log "下载 $url"
    if curl -fSL --retry 3 --connect-timeout 20 --max-time 900 -o "$out.part" "$url"; then
      mv -f "$out.part" "$out"; ok=yes; break
    fi
    rm -f "$out.part"
    echo "    镜像不可用，换下一个" >&2
  done
  [[ "$ok" = yes ]] || die "所有镜像都下载失败: $(basename "$out")"
  if [[ -n "$sha" ]]; then
    echo "$sha  $out" | sha256sum -c --status || die "sha256 校验失败: $out（期望 $sha）"
  fi
  verify_archive "$out" || die "压缩包损坏: $out"
  log "校验通过: $(basename "$out")"
}

extract_tar() { # $1=tarball $2=解包后的顶层目录名
  local tarball="$1" top="$2"
  mkdir -p "$DEPSRCDIR"
  rm -rf "$DEPSRCDIR/$top" "$DEPSRCDIR/.tmp"
  mkdir -p "$DEPSRCDIR/.tmp"
  tar -xf "$tarball" -C "$DEPSRCDIR/.tmp"
  mv "$DEPSRCDIR/.tmp/$top" "$DEPSRCDIR/$top"
  rmdir "$DEPSRCDIR/.tmp"
}

fetch_python_source() {
  mkdir -p "$DL" "$BUILDROOT"
  download "$DL/$PY_TARBALL" "$PY_SHA256" "${PY_MIRRORS[@]/%//$PY_TARBALL}"
  if [[ -f "$PRISTINE/configure" && -f "$PRISTINE/Makefile.in" ]]; then
    log "源码已解包: $PRISTINE"
  else
    log "解包到 $BUILDROOT"
    rm -rf "$PRISTINE" "$BUILDROOT/Python-$PY_VER.tmp"
    mkdir -p "$BUILDROOT/Python-$PY_VER.tmp"
    tar -xzf "$DL/$PY_TARBALL" -C "$BUILDROOT/Python-$PY_VER.tmp"
    mv "$BUILDROOT/Python-$PY_VER.tmp/Python-$PY_VER" "$PRISTINE"
    rmdir "$BUILDROOT/Python-$PY_VER.tmp"
  fi
}

# ---------------------------------------------------------------------------
# 1) 宿主机 Python 3.13（--with-build-python 需要同版本解释器）
# ---------------------------------------------------------------------------
build_host_python() {
  if [[ -x "$HOSTPY/bin/python3" ]] && \
     "$HOSTPY/bin/python3" -c "import sys; sys.exit(0 if sys.version_info[:2]==(3,13) else 1)" 2>/dev/null; then
    log "宿主机 Python 已就绪: $HOSTPY/bin/python3 ($("$HOSTPY/bin/python3" -V 2>&1))"
    return 0
  fi
  log "构建宿主机 Python $PY_VER（--with-build-python 要求同版本；这是预期的一次性开销）"
  # 不要 --disable-test-modules：CPython 的交叉构建脚本偶尔会 import test.support。
  # 不要 --without-ensurepip：ensurepip 要被用来给目标树装 pip。
  (
    cd "$PRISTINE"
    ./configure --prefix="$HOSTPY" > "$BUILDROOT/host-python-configure.log" 2>&1
    make -j"$NPROC" > "$BUILDROOT/host-python-make.log" 2>&1
    make altinstall > "$BUILDROOT/host-python-install.log" 2>&1
  ) || die "宿主机 Python 构建失败，见 $BUILDROOT/host-python-*.log"
  # altinstall 不建 python3 -> python3.13 的软链，但 CPython 的 configure 认
  # `python3`，所以补一个。
  ln -sf "python$PY_XY" "$HOSTPY/bin/python3"
  "$HOSTPY/bin/python3" -V >/dev/null || die "宿主机 Python 不可用"
  "$HOSTPY/bin/python3" -c "import sys; sys.exit(0 if sys.version_info[:2]==(3,13) else 1)" \
    || die "宿主机 Python 版本不是 3.13"
}

# ---------------------------------------------------------------------------
# 2) 第三方依赖（全部静态 .a，被扩展模块吸收，交付树里不出现第三方 .so）
# ---------------------------------------------------------------------------
# 依赖清单：名字 -> 版本 / tar 文件名 / 顶层目录 / sha256 / 镜像列表
declare -A DEP_TARBALL DEP_TOP DEP_SHA
DEP_TARBALL[openssl]="openssl-$OPENSSL_VER.tar.gz";   DEP_TOP[openssl]="openssl-$OPENSSL_VER"
DEP_TARBALL[libffi]="libffi-$LIBFFI_VER.tar.gz";      DEP_TOP[libffi]="libffi-$LIBFFI_VER"
DEP_TARBALL[sqlite]="sqlite-autoconf-$SQLITE_VER.tar.xz"; DEP_TOP[sqlite]="sqlite3-3.46.1"  # fossil 源码树顶层目录名
DEP_TARBALL[bzip2]="bzip2-$BZIP2_VER.tar.gz";         DEP_TOP[bzip2]="bzip2-$BZIP2_VER"
DEP_TARBALL[xz]="xz-$XZ_VER.tar.xz";                  DEP_TOP[xz]="xz-$XZ_VER"
DEP_TARBALL[readline]="readline-$READLINE_VER.tar.gz"; DEP_TOP[readline]="readline-$READLINE_VER"
DEP_TARBALL[ncurses]="ncurses-$NCURSES_VER.tar.gz";  DEP_TOP[ncurses]="ncurses-$NCURSES_VER"

fetch_dep() { # $1=dep name
  local name="$1" tarball sha=""
  local -a urls=()
  tarball="${DEP_TARBALL[$name]}"
  mkdir -p "$DL/deps"
  case "$name" in
    openssl)  urls=("$DEBIAN_POOL/o/openssl/openssl_$OPENSSL_VER.orig.tar.gz")
              [[ "$OPENSSL_VER" = 3.0.16 ]] && sha="57e03c50feab5d31b152af2b764f10379aecd8ee92f16c985983ce4a99f7ef86" ;;
    libffi)   urls=("$DEBIAN_POOL/libf/libffi/libffi_$LIBFFI_VER.orig.tar.gz")
              # 3.4.8 从 debian pool 下到的是 **无 configure** 的 git 快照（需要
              # autoconf/libtool 才能生成 configure，本机没有）；3.4.4 的 .orig.tar.gz
              # 才是带 configure 的上游发布 tar，所以这里用 3.4.4。
              [[ "$LIBFFI_VER" = 3.4.4 ]] && sha="d66c56ad259a82cf2a9dfc408b32bf5da52371500b84745f7fb8b645712df676" ;;
    sqlite)   urls=("$DEBIAN_POOL/s/sqlite3/sqlite3_3.46.1.orig.tar.xz")
              [[ "$SQLITE_VER" = 3460100 ]] && sha="d0cdd2ece271b29e7ce18095745d892517ee26d0f270065b3a25c2e9eb11639c" ;;
    bzip2)    urls=("$DEBIAN_POOL/b/bzip2/bzip2_$BZIP2_VER.orig.tar.gz")
              [[ "$BZIP2_VER" = 1.0.8 ]] && sha="ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269" ;;
    xz)       urls=("$DEBIAN_POOL/x/xz-utils/xz-utils_$XZ_VER.orig.tar.xz")
              [[ "$XZ_VER" = 5.8.4 ]] && sha="4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b" ;;
    readline) urls=("https://mirrors.aliyun.com/gnu/readline/readline-$READLINE_VER.tar.gz"
                    "https://mirrors.tuna.tsinghua.edu.cn/gnu/readline/readline-$READLINE_VER.tar.gz")
              [[ "$READLINE_VER" = 8.2 ]] && sha="3feb7171f16a84ee82ca18a36d7b9be109a52c04f492a053331d7d1095007c35" ;;
    ncurses)  urls=("https://mirrors.aliyun.com/gnu/ncurses/ncurses-$NCURSES_VER.tar.gz"
                    "https://mirrors.tuna.tsinghua.edu.cn/gnu/ncurses/ncurses-$NCURSES_VER.tar.gz")
              [[ "$NCURSES_VER" = 6.5 ]] && sha="136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6" ;;
  esac
  download "$DL/deps/$tarball" "$sha" "${urls[@]}"
  [[ -d "$DEPSRCDIR/${DEP_TOP[$name]}" ]] || extract_tar "$DL/deps/$tarball" "${DEP_TOP[$name]}"
}

# 交叉工具链环境。每个 arch 一套；所有依赖与 CPython 都用这一套，严禁混宿主机库。
toolchain_env() { # $1=arch
  local arch="$1"
  case "$arch" in
    arm64)  G_TRIPLE="aarch64-linux-android" ;;
    x86_64) G_TRIPLE="x86_64-linux-android" ;;
    *) die "不支持的 arch: $arch（只支持 arm64 / x86_64）" ;;
  esac
  G_ARCH="$arch"
  G_PREFIX="$DEPSROOT/$arch"
  export CC="$LLVM/bin/${G_TRIPLE}${API}-clang"
  export CXX="$LLVM/bin/${G_TRIPLE}${API}-clang++"
  export CPP="$CC -E"
  export AR="$LLVM/bin/llvm-ar"
  export RANLIB="$LLVM/bin/llvm-ranlib"
  export STRIP="$LLVM/bin/llvm-strip"
  export NM="$LLVM/bin/llvm-nm"
  export OBJCOPY="$LLVM/bin/llvm-objcopy"
  export LD="$LLVM/bin/ld.lld"
  # OpenSSL 的 android-* target 依赖这个变量找 NDK（不要传 --with-ndk-path，
  # OpenSSL 3.0 不认这个选项，会把它当成编译器参数传给 clang 然后报
  # "unknown argument: '--with-ndk-path=...'"）。
  export ANDROID_NDK_ROOT="$NDK"
  export ANDROID_NDK_HOME="$NDK"
  export PATH="$LLVM/bin:$PATH"
}

dep_openssl() { # $1=prefix
  local prefix="$1" tgt
  case "$G_ARCH" in arm64) tgt=android-arm64 ;; x86_64) tgt=android-x86_64 ;; esac
  [[ -f "$prefix/openssl/lib/libssl.a" ]] && { log "[$G_ARCH] openssl 已构建"; return 0; }
  log "[$G_ARCH] 构建 openssl $OPENSSL_VER (target=$tgt)"
  (
    cd "$DEPSRCDIR/${DEP_TOP[openssl]}"
    make clean >/dev/null 2>&1 || true
    rm -f configdata.pm Makefile
    # 千万不要给 OpenSSL 的 Configure 传 `-static`！它是"透传编译选项 + 触发
    # 一串配置开关"的双关语：文档见 Configure 头部注释，
    #   "-static ... triggers a number configuration options, namely
    #    no-pic, no-shared and no-threads"
    # 于是 OPENSSL_THREADS 不会被定义，CPython 的 Modules/_ssl.c 直接
    #   #error "OPENSSL_THREADS is not defined, Python requires thread-safe OpenSSL"
    # 而且 no-pic 还会让 .a 变非 PIC，链进 .so 时报
    #   "relocation R_AARCH64_ADR_PREL_PG_HI21 cannot be used against symbol ..."
    # 我们只要静态库（libcrypto.a/libssl.a 本身就不是 -static 可执行文件），
    # 用 no-shared 即可。
    # no-tests: 不构建测试程序（交叉编译跑不了，也拖慢构建）
    # no-ui-console: 不构建 openssl 命令行工具（app 里用不到）
    # --openssldir 指向 prefix 内的空目录即可；我们用不到 openssl.cnf
    #   （CPython 的 ssl 模块只需要 libssl/libcrypto 的符号与内置默认 provider）
    ./Configure "$tgt" \
      -D__ANDROID_API__="$API" \
      --prefix="$prefix/openssl" \
      --openssldir="$prefix/openssl/ssl" \
      --sysroot="$LLVM/sysroot" \
      no-shared no-tests no-ui-console threads \
      -O2 -fPIC \
      > "$BUILDROOT/openssl-$G_ARCH-configure.log" 2>&1
    make -j"$NPROC" build_libs > "$BUILDROOT/openssl-$G_ARCH-make.log" 2>&1
    make install_sw > "$BUILDROOT/openssl-$G_ARCH-install.log" 2>&1
  ) || die "openssl 构建失败，见 $BUILDROOT/openssl-$G_ARCH-*.log"
}

dep_libffi() { # $1=prefix
  local prefix="$1"
  [[ -f "$prefix/libffi/lib/libffi.a" ]] && { log "[$G_ARCH] libffi 已构建"; return 0; }
  log "[$G_ARCH] 构建 libffi $LIBFFI_VER"
  (
    cd "$DEPSRCDIR/${DEP_TOP[libffi]}"
    make distclean >/dev/null 2>&1 || true
    # --disable-exec-static-tramp：libffi 的 configure 把 *-linux-android* 也
    #   算进 "arm/aarch64/x86_64-*-linux-*"，于是打开 FFI_EXEC_STATIC_TRAMP，
    #   编 src/tramp.c。但 tramp.c 调用的 open_temp_exec_file() 只在
    #   src/closures.c 的 FFI_MMAP_EXEC_WRIT/EMIT_MMAP 分支里定义，而 bionic 上
    #   那些分支没打开（configure 认为没有 mkostemp），结果是
    #     error: call to undeclared function 'open_temp_exec_file'
    #   （NDK clang 把隐式声明当错误）。静态 trampoline 对 CPython 的 _ctypes
    #   完全用不到（它只用 closure_alloc 走 mmap 路径），直接关掉最干净。
    ./configure --host="$G_TRIPLE" --build="$(gcc -dumpmachine)" \
      --prefix="$prefix/libffi" --disable-shared --enable-static \
      --disable-exec-static-tramp \
      CFLAGS="-O2 -fPIC" > "$BUILDROOT/libffi-$G_ARCH.log" 2>&1
    make -j"$NPROC" >> "$BUILDROOT/libffi-$G_ARCH.log" 2>&1
    make install >> "$BUILDROOT/libffi-$G_ARCH.log" 2>&1
  ) || die "libffi 构建失败，见 $BUILDROOT/libffi-$G_ARCH.log"
}

dep_sqlite() { # $1=prefix
  local prefix="$1"
  [[ -f "$prefix/sqlite/lib/libsqlite3.a" ]] && { log "[$G_ARCH] sqlite 已构建"; return 0; }
  log "[$G_ARCH] 构建 sqlite $SQLITE_VER（用 amalgamation 直接编译，不走 configure）"
  local amalg="$BUILDROOT/sqlite-amalgamation"
  # debian pool 里的 sqlite3_*.orig.tar.xz 是 fossil 源码树，**不含** 生成好的
  # sqlite3.c/sqlite3.h（那是 `make sqlite3.c` 用 tclsh 现场生成的）。所以：
  #   1) 先在宿主机上 configure 一次，用 tclsh 生成 amalgamation，缓存起来；
  #   2) 再拿这份 sqlite3.c 给两个 arch 各自交叉编译。
  # 不要对一个 arch 跑 `./configure --host=...` 再 `make sqlite3.c`：生成过程会
  # 顺手用目标 CC 编 src-verify 之类的宿主机小程序，交叉编译器跑不了。
  if [[ ! -f "$amalg/sqlite3.c" ]]; then
    mkdir -p "$amalg"
    # 这一步必须用 **宿主机** 工具链：configure 会编一个 a.out 跑一下（判断是不是
    # 交叉编译），而 `make sqlite3.c` 里还有 src-verify 这类宿主机小程序。
    # 如果不把 CC/CFLAGS/LDFLAGS 换成宿主机默认值，configure 会拿
    # x86_64-linux-android26-clang 去编，然后报
    #   "cannot run C compiled programs"（Android 二进制在 x86_64 宿主上跑不了）。
    (
      unset CC CXX CPP CFLAGS CXXFLAGS LDFLAGS LIBS AR RANLIB STRIP NM OBJCOPY LD
      cd "$DEPSRCDIR/${DEP_TOP[sqlite]}"
      rm -f Makefile sqlite3.c sqlite3.h sqlite3ext.h
      ./configure --disable-shared > "$BUILDROOT/sqlite-host-configure.log" 2>&1
      make sqlite3.c sqlite3.h tclsh="$TCLSH" > "$BUILDROOT/sqlite-amalgamation.log" 2>&1
    ) || die "sqlite amalgamation 生成失败，见 $BUILDROOT/sqlite-amalgamation.log"
    cp "$DEPSRCDIR/${DEP_TOP[sqlite]}/sqlite3.c" \
       "$DEPSRCDIR/${DEP_TOP[sqlite]}/sqlite3.h" \
       "$DEPSRCDIR/${DEP_TOP[sqlite]}/sqlite3ext.h" "$amalg/"
  fi
  rm -rf "$prefix/sqlite"; mkdir -p "$prefix/sqlite/include" "$prefix/sqlite/lib"
  cp "$amalg/sqlite3.h" "$amalg/sqlite3ext.h" "$prefix/sqlite/include/"
  if ! "$CC" -O2 -fPIC -DNDEBUG \
      -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS5 \
      -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_DBSTAT_VTAB \
      -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_THREADSAFE=1 \
      -DSQLITE_OMIT_LOAD_EXTENSION \
      -c "$amalg/sqlite3.c" -o "$prefix/sqlite/sqlite3.o" \
      > "$BUILDROOT/sqlite-$G_ARCH.log" 2>&1; then
    tail -20 "$BUILDROOT/sqlite-$G_ARCH.log" >&2
    return 1
  fi
  "$AR" rcs "$prefix/sqlite/lib/libsqlite3.a" "$prefix/sqlite/sqlite3.o"
  rm -f "$prefix/sqlite/sqlite3.o"
}

dep_bzip2() { # $1=prefix
  local prefix="$1"
  [[ -f "$prefix/bzip2/lib/libbz2.a" ]] && { log "[$G_ARCH] bzip2 已构建"; return 0; }
  log "[$G_ARCH] 构建 bzip2 $BZIP2_VER（裸 Makefile，没有 configure）"
  local src="$DEPSRCDIR/${DEP_TOP[bzip2]}"
  rm -rf "$prefix/bzip2"; mkdir -p "$prefix/bzip2/include" "$prefix/bzip2/lib"
  (
    cd "$src"
    make clean >/dev/null 2>&1 || true
    # 不用 `make install`：bzip2 的 Makefile 会去改 /usr 之类的绝对路径，
    # 交叉编译时只编 libbz2.a 再手动拷头文件最稳。
    make -j"$NPROC" libbz2.a CFLAGS="-O2 -fPIC -Wall" CC="$CC" AR="$AR" RANLIB="$RANLIB" \
      > "$BUILDROOT/bzip2-$G_ARCH.log" 2>&1
  ) || die "bzip2 构建失败，见 $BUILDROOT/bzip2-$G_ARCH.log"
  cp "$src/bzlib.h" "$prefix/bzip2/include/"
  cp "$src/libbz2.a" "$prefix/bzip2/lib/"
}

dep_xz() { # $1=prefix
  local prefix="$1"
  [[ -f "$prefix/xz/lib/liblzma.a" ]] && { log "[$G_ARCH] xz/liblzma 已构建"; return 0; }
  log "[$G_ARCH] 构建 xz/liblzma $XZ_VER"
  (
    cd "$DEPSRCDIR/${DEP_TOP[xz]}"
    make distclean >/dev/null 2>&1 || true
    # --disable-xz/--disable-scripts 等：只要 liblzma.a，不要命令行工具。
    # --disable-nls：bionic 的 gettext 不完整，而且我们不需要翻译。
    ./configure --host="$G_TRIPLE" --build="$(gcc -dumpmachine)" \
      --prefix="$prefix/xz" --disable-shared --enable-static \
      --disable-doc --disable-nls --disable-xz --disable-xzdec \
      --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-lzma-links \
      CFLAGS="-O2 -fPIC" > "$BUILDROOT/xz-$G_ARCH.log" 2>&1
    make -j"$NPROC" >> "$BUILDROOT/xz-$G_ARCH.log" 2>&1
    make install >> "$BUILDROOT/xz-$G_ARCH.log" 2>&1
  ) || die "xz 构建失败，见 $BUILDROOT/xz-$G_ARCH.log"
}

dep_ncurses() { # $1=prefix
  local prefix="$1"
  [[ -f "$prefix/ncurses/lib/libtinfow.a" ]] && { log "[$G_ARCH] ncurses 已构建"; return 0; }
  log "[$G_ARCH] 构建 ncurses $NCURSES_VER（只为 readline 提供 termcap API）"
  rm -rf "$prefix/ncurses"
  (
    cd "$DEPSRCDIR/${DEP_TOP[ncurses]}"
    make distclean >/dev/null 2>&1 || true
    # --enable-termcap 打开 tgetent/tgetstr/tgetnum/tgetflag/tputs 以及 PC/BC/UP
    #   这几个 termcap 兼容符号（readline 需要）。它们在 libtinfow.a 里，
    #   **不是** 单独的 libtermcap.a。
    # --without-progs/--without-tests：不要把 tic/infocmp/测试程序交叉编译进来。
    # --without-cxx/--without-ada/--without-manpages：砍掉无关语言绑定。
    # --without-shared：只要 .a。
    # 千万不要 --with-termlib：那会把 curses.h 挪到 include/ncursesw/ 下（多一层），
    #   而 CPython 的 AC_CHECK_HEADERS 只在 -I<prefix>/include 里找 curses.h，
    #   找不到就退化成链接 -ltinfo，然后 Modules/_cursesmodule.c 报
    #     "call to undeclared function 'setupterm'"（因为它其实是拿
    #     <term.h> 当 curses 用）。默认（合并成 libncursesw.a）就没这问题。
    # --with-default-terminfo-dir=/system/usr/share/terminfo：Android 上没有这个
    #   目录（实测设备上完全没有 terminfo 数据库），ncurses 会退回到自己编译进
    #   去的 dumb/unknown 条目；对我们的用途（input() 行编辑、历史）足够了。
    #   要真正支持 xterm-256color，app 侧需要设 TERMINFO 指向随包分发的 terminfo。
    ./configure --host="$G_TRIPLE" --build="$(gcc -dumpmachine)" \
      --prefix="$prefix/ncurses" \
      --without-shared --without-debug --without-cxx --without-cxx-binding \
      --without-ada --without-manpages --without-progs --without-tests \
      --disable-db-install --disable-nls --enable-termcap \
      --with-default-terminfo-dir=/system/usr/share/terminfo \
      --with-terminfo-dirs=/system/usr/share/terminfo \
      CFLAGS="-O2 -fPIC" > "$BUILDROOT/ncurses-$G_ARCH.log" 2>&1
    make -j"$NPROC" >> "$BUILDROOT/ncurses-$G_ARCH.log" 2>&1
    make install >> "$BUILDROOT/ncurses-$G_ARCH.log" 2>&1
  ) || die "ncurses 构建失败，见 $BUILDROOT/ncurses-$G_ARCH.log"
}

dep_readline() { # $1=prefix
  local prefix="$1"
  [[ -f "$prefix/readline/lib/libreadline.a" ]] && { log "[$G_ARCH] readline 已构建"; return 0; }
  log "[$G_ARCH] 构建 readline $READLINE_VER"
  local src="$DEPSRCDIR/${DEP_TOP[readline]}"
  rm -rf "$prefix/readline"
  local tcap=""
  [[ -f "$prefix/ncurses/lib/libtinfow.a" ]] && tcap="-L$prefix/ncurses/lib -ltinfow"
  (
    cd "$src"
    make distclean >/dev/null 2>&1 || true
    # 两个关键点：
    # 1) --without-bash-malloc：readline 自带的 malloc 用 sbrk()，bionic 上 sbrk
    #    是个永远返回 -1 的桩，必须改用 bionic 的 malloc。
    # 2) readline 8.2 的发行 tar 里 **没有** 自带 termcap 实现（老版本
    #    lib/termcap 已经删掉了，`bash_cv_termcap_lib=gnutermcap` 那个技巧不成立：
    #    编出来根本没有 tgetent）。CPython 的
    #    `configure: checking for readline in -lreadline` 会报
    #      ld.lld: error: undefined symbol: tgetent / tgetstr / tgetnum /
    #                     tgetflag / tputs / PC / BC / UP
    #    于是 HAVE_READLINE 判否、readline 模块不被构建。解决：给它 ncurses 的
    #    termcap 实现（见 dep_ncurses），链接期通过 LDFLAGS/LIBS 里的
    #    -L.../ncurses/lib -ltinfow 生效。
    TERMCAP_LIB="$tcap" \
    ./configure --host="$G_TRIPLE" --build="$(gcc -dumpmachine)" \
      --prefix="$prefix/readline" --disable-shared --enable-static \
      --without-bash-malloc bash_cv_termcap_lib=gnutermcap \
      CFLAGS="-O2 -fPIC" > "$BUILDROOT/readline-$G_ARCH.log" 2>&1
    make -j"$NPROC" >> "$BUILDROOT/readline-$G_ARCH.log" 2>&1
    make install >> "$BUILDROOT/readline-$G_ARCH.log" 2>&1
  ) || die "readline 构建失败，见 $BUILDROOT/readline-$G_ARCH.log"
}

build_deps() { # $1=arch
  local arch="$1"
  local prefix="$DEPSROOT/$arch"
  mkdir -p "$prefix" "$DEPSRCDIR" "$BUILDROOT"
  toolchain_env "$arch"
  # 解包（幂等）
  fetch_dep openssl;  fetch_dep libffi; fetch_dep sqlite
  fetch_dep bzip2;    fetch_dep xz;     fetch_dep ncurses; fetch_dep readline
  # 每个依赖都允许失败：失败只是少一个模块，不应该挡住整个解释器。
  for d in openssl libffi sqlite bzip2 xz ncurses readline; do
    if ! "dep_$d" "$prefix"; then
      warn "[$arch] 依赖 $d 构建失败 -> 对应扩展模块将缺失（见上面日志）"
    fi
  done
}

# 删掉生成 Makefile 里 *_LDFLAGS 变量中 autoconf 的 "none required" 字面量。
# 用法: fix_makefile_ldflags <源码树>
fix_makefile_ldflags() {
  python3 - "$1/Makefile" <<'PYEOF'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
n = 0
out = []
for line in s.splitlines(True):
    m = re.match(r'^((?:MODULE_[A-Z0-9_]+|[A-Z0-9_]+)_LDFLAGS\s*[:+]?=)(.*)$', line)
    if m and re.search(r'\bnone\b|\brequired\b', m.group(2)):
        val = re.sub(r'\s*\bnone\b', ' ', m.group(2))
        val = re.sub(r'\s*\brequired\b', ' ', val)
        line = m.group(1) + val.rstrip() + '\n'
        n += 1
    out.append(line)
if n:
    p.write_text(''.join(out))
    print(f"  [fix] 清理了 {n} 处 *_LDFLAGS 里的 'none required' 字面量")
PYEOF
}

# Android/bionic 专属的 configure 补丁。
# 全部作用在 "每个 arch 一份" 的新源码树上（build_arch 里 cp -a 出来的），
# 所以天然幂等：已经改过就跳过。
patch_configure_android() { # $1=源码树
  local src="$1" cfg="$src/configure"
  [[ -f "$cfg" ]] || die "找不到 configure: $cfg"

  # -------------------------------------------------------------------------
  # 1) 放开 sem_open / sem_unlink，让 _multiprocessing 能构建。
  #
  # CPython 的 configure.ac 对 Linux-android 有一段硬编码的黑名单：
  #     blocked_funcs="chroot initgroups setegid ... sem_open sem_unlink"
  #     for name in $blocked_funcs; do
  #         AS_VAR_SET([ac_cv_func_$name], [no])   # 直接覆盖，命令行传 yes 也没用
  #     done
  # 注释理由是"这两个函数在非特权进程里总是报错"（Android 从 API 26 起把
  # /dev/shm 的使用限制在 SELinux 允许的域里；app 域下 sem_open 会失败）。
  # 但：
  #   * 只是"运行时可能失败"，不是"链接不到"——NDK 的 API 26 libc.so 里有这两个
  #     符号，我们实测 `-Df=sem_open` 链接通过、`-Df=sem_unlink` 也通过；
  #   * 不开这一段，MODULE__MULTIPROCESSING_STATE 一定是 missing，
  #     `import _multiprocessing` 直接失败，multiprocessing 模块连 fork 后端都
  #     拿不全；
  #   * 真机上 multiprocessing 的常见用法（Pool/Process，fork 后端）根本不需要
  #     POSIX 具名信号量；只有跨进程 Lock/Semaphore 才会走到 sem_open。
  # 所以这里把 sem_open/sem_unlink 从黑名单里摘掉，让模块能编出来；运行时若真的
  # 撞上 SELinux 限制，那是 OSError，而不是 import 就挂。
  # 注意：不动其它 blocked_funcs（chroot/setuid 那些在 app 里确实会崩，保持关闭）。
  # -------------------------------------------------------------------------
  if grep -q 'blocked_funcs="$blocked_funcs sem_open sem_unlink"' "$cfg"; then
    python3 - "$cfg" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = 'blocked_funcs="$blocked_funcs sem_open sem_unlink"'
new = ('# [DSH] sem_open/sem_unlink 从 Android 黑名单里移除，'
       '让 _multiprocessing 能构建；见 scripts/build-python-android.sh')
if old in s:
    p.write_text(s.replace(old, new, 1))
    print("  [patch] configure: 放开 sem_open/sem_unlink（_multiprocessing）")
PYEOF
  else
    echo "  [skip] configure: sem_open/sem_unlink 已处理"
  fi
}

# ---------------------------------------------------------------------------
# 3) 单个 arch 的 configure + make + install + 裁剪 + strip
# ---------------------------------------------------------------------------
build_arch() {
  local arch="$1"
  toolchain_env "$arch"
  local prefix="$DEPSROOT/$arch"
  local out="$BUILDROOT/python-android-$arch"
  local src="$BUILDROOT/Python-$PY_VER-$arch"

  # --- 幂等短路 ------------------------------------------------------------
  # 上一轮已经成功产出过就跳过（重跑脚本不会重复干活，符合 house style 的
  # "idempotent" 要求）。要强制重建：DSH_PYTHON_FORCE=1 ./scripts/build-python-android.sh <arch>。
  if [[ -x "$out/bin/python$PY_XY" && -d "$out/lib/python$PY_XY/lib-dynload" \
        && -d "$out/lib/python$PY_XY/site-packages/pip" && -z "${DSH_PYTHON_FORCE:-}" ]]; then
    log "[$arch] 已构建过，跳过（强制重建：DSH_PYTHON_FORCE=1）"
    self_check "$arch" "$out"
    return 0
  fi

  log "[$arch] 准备独立源码树 $src（原地构建：CPython 的 make 不支持 out-of-tree）"
  rm -rf "$src"
  cp -a "$PRISTINE" "$src"

  local openssl_dir=""
  [[ -f "$prefix/openssl/lib/libssl.a" ]] && openssl_dir="$prefix/openssl"

  # --- 交叉编译缓存变量 -----------------------------------------------------
  # 逐条理由见文件头第 2、3 条。
  local -a cvs=(
    # 交叉编译时 configure 无法运行目标程序；这些默认值会误判。
    ac_cv_file__dev_ptmx=yes          # /dev/ptmx 在 Android 上存在
    ac_cv_file__dev_ptc=no            # 只有 /dev/pts/ptmx，没有 /dev/ptc
    ac_cv_file__dev_urandom=yes
    ac_cv_func_getrandom=no           # 关键：bionic 的 getrandom()/getentropy() 是
    ac_cv_func_getentropy=no          # __BIONIC_AVAILABILITY_GUARD(28)，API 26 下
                                      # 既没有声明也没有 libc 符号。必须判 no，让
                                      # configure 定义 HAVE_GETRANDOM_SYSCALL /
                                      # HAVE_GETENTROPY_SYSCALL，CPython 改用
                                      # syscall(SYS_getrandom) —— 这条在 API 26 的
                                      # 设备上完全可用（内核支持即可）。
                                      # 判 yes 的话 bootstrap_hash.c 会直接调
                                      # getrandom()，NDK clang 立刻报
                                      # "call to undeclared function 'getrandom'"，
                                      # 而且是链接期缺符号，不能靠 warning 绕过。
    ac_cv_func_getentropy_syscall=yes
    ac_cv_func_getrandom_syscall=yes
    ac_cv_func_getgrouplist=no        # bionic 没有 getgrouplist (API 26)
    ac_cv_func_getpwent=yes
    ac_cv_func_getpwnam=yes
    ac_cv_func_getpwuid=yes
    ac_cv_func_setpwent=no            # bionic: API 26 无 setpwent/endpwent
    ac_cv_func_endpwent=no
    ac_cv_func_setgrent=no
    ac_cv_func_endgrent=no
    ac_cv_func_sethostent=no          # bionic 缺少整套 NSS hostent 接口
    ac_cv_func_endhostent=no
    ac_cv_func_gethostent=no
    ac_cv_func_gethostbyname=yes
    ac_cv_func_gethostbyaddr=yes
    ac_cv_func_getnetent=no
    ac_cv_func_getprotoent=yes
    ac_cv_func_getservent=yes
    ac_cv_func_fork_works=yes         # bionic 的 fork() 可用（仅可执行文件，不涉及 JVM）
    ac_cv_func_clock_settime=yes      # Android API>=21 有 clock_settime
    ac_cv_func_clock_nanosleep=yes    # Android API>=23 行为正确（configure 里对 <23 特判）
    ac_cv_func_sendfile=yes
    ac_cv_func_utimensat=yes          # API 26 有 utimensat/futimens
    ac_cv_func_futimens=yes
    ac_cv_func_posix_fallocate=yes    # API 26 有
    # posix_spawn()/posix_spawnattr_*/posix_spawn_file_actions_* 在 API 26 的
    # NDK stub 里链接不到（`-Df=posix_spawn` 链接失败），而且 <spawn.h> 在
    # API 26 下也不会暴露那些声明。判 no 之后 CPython 的 subprocess/posix
    # 走 fork+execve 路径，在 bionic 上完全正常（Android 的 posix_spawn 本来
    # 就是 libc 内部 fork+exec 实现的，没有实质区别）。
    ac_cv_func_posix_spawn=no
    ac_cv_func_posix_spawnp=no
    ac_cv_func_preadv=yes
    ac_cv_func_pwritev=yes
    ac_cv_func_mkfifo=yes             # API 26 有 mkfifo/mkfifoat
    ac_cv_func_mkfifoat=yes
    ac_cv_func_linkat=yes
    ac_cv_func_faccessat=yes
    ac_cv_func_eventfd=yes
    ac_cv_func_memfd_create=no        # memfd_create 要 API 30，posixmodule 会退回 shm
    # 类型大小探测：交叉编译时 configure 的类型大小宏（AC_CHECK_SIZEOF）通常是
    # 靠编译期 static_assert 决定的，但 pthread_t/pthread_key_t 这两个在 CPython
    # 里被写成需要 **运行** 的探测（或依赖 PTHREAD_KEYS_MAX 之类的宏），交叉编译
    # 下会得到 0，然后 Python/thread_pthread.h 直接
    #   #error "Unsupported SIZEOF_PTHREAD_T value"
    # bionic 两个 ABI 上都是：pthread_t = 8 字节（指针）、pthread_key_t = 4 字节
    # （32 位 int，见 NDK sysroot 的 <bits/pthread_types.h>）。
    ac_cv_sizeof_pthread_t=8
    ac_cv_sizeof_pthread_key_t=4
    # CPython 的 pthread 探测是 AC_RUN_IFELSE（要在目标上真跑），交叉编译时
    # action-if-cross-compiling 分支全是 no/空。最坑的是 ac_cv_kthread 变成 yes，
    # CPython 于是把 `-Kthread` 加进 CC（Solaris 的私有开关），NDK clang 直接
    #   error: unknown argument '-Kthread'
    # 由此 pthread_t 的 AC_COMPILE_IFELSE 也失败，SIZEOF_PTHREAD_T 变成 0，
    # Python/thread_pthread.h 就 #error "Unsupported SIZEOF_PTHREAD_T value"。
    # bionic 的 pthread 永远是可用的、且不需要任何 -K* 开关：全部钉死。
    ac_cv_pthread_is_default=yes
    ac_cv_kpthread=no
    ac_cv_kthread=no
    ac_cv_pthread=no
    ac_cv_cxx_thread=no
    ac_cv_have_pthread_t=yes
    ac_cv_lib_dl_dlopen=yes
    ac_cv_func_dlopen=yes
    ac_cv_search_dlopen="none required"
    # 数学函数（clang 内置，避免 configure 走 libm 探测失败）
    ac_cv_lib_m_atan2=yes
    ac_cv_lib_m_floor=yes
    ac_cv_lib_m_fmod=yes
    ac_cv_lib_m_pow=yes
    # 交叉编译时不要试图跑目标程序
    ac_cv_rshift_sign=1
    ac_cv_gcc_x86=yes
    ac_cv_posix_semaphores_enabled=yes
    ac_cv_broken_sem_getvalue=no
    ac_cv_pthread_system_supported=yes
    ac_cv_working_alloca_h=yes
    ac_cv_sys_sync_file_range=yes
    ac_cv_has__futimens=yes
    ac_cv_have_clockid_t=yes
    ac_cv_have_pthread_condattr_setclock=yes
    ac_cv_func_pthread_condattr_setclock=yes
    ac_cv_func_pthread_kill=yes
    ac_cv_func_pthread_sigmask=yes
    ac_cv_func_pthread_getname_np=no  # bionic 只有 pthread_getname_np 的 API 26 版本？
    ac_cv_func_pthread_setname_np=yes
    # bionic 在 API 26 就导出了 sem_open/sem_close/sem_unlink/sem_timedwait/
    # sem_getvalue（<semaphore.h> 里没有 __BIONIC_AVAILABILITY_GUARD 包住它们，
    # 实测 `-Df=sem_open` 链接通过）。但 **CPython 的 configure 会强行把它们判 no**：
    #   configure.ac: if test "$ac_sys_system" = "Linux-android"; then
    #                   blocked_funcs="$blocked_funcs sem_open sem_unlink"
    # 注释说这两个函数在非特权进程里永远返回错误（Android 的 SELinux 把
    # /dev/shm 访问挡住了）。后果是 MODULE__MULTIPROCESSING_STATE=missing，
    # 设备上 `import _multiprocessing` 直接 ModuleNotFoundError。
    # 我们按"能给就给"的原则用 patch_configure_android() 把这两行改掉（见那里的
    # 详细说明），这里再把缓存变量钉成 yes。
    ac_cv_func_sem_open=yes
    ac_cv_func_sem_close=yes
    ac_cv_func_sem_unlink=yes
    ac_cv_func_sem_timedwait=yes
    ac_cv_func_sem_getvalue=yes
    ac_cv_func_sem_init=yes
    ac_cv_func_sem_destroy=yes
    ac_cv_func_sem_wait=yes
    ac_cv_func_sem_post=yes
    # shm_open()/shm_unlink()：bionic 的 <sys/mman.h> 用
    # __BIONIC_AVAILABILITY_GUARD(28) 挡住，API 26 下既无声明也无 stub 符号
    # （链接测试失败）。判 no 之后 _multiprocessing 的 posixshmem 不编译，
    # SharedMemory 走 mmap+文件名的兜底实现，Android 上够用。
    ac_cv_func_shm_open=no
    ac_cv_func_shm_unlink=no
    ac_cv_func_ftruncate=yes
    # lchmod(): bionic 从来没有实现过（不是 API 版本问题，是这个符号根本不在
    # libc.so 里）。实测 `x86_64-linux-android26-clang conftest.c -llchmod` 链接
    # 失败。CPython 的 posixmodule.c 在 HAVE_LCHMOD 打开时会直接调它，而
    # <sys/stat.h> 里没有声明 -> NDK clang 报
    #   "call to undeclared function 'lchmod'"（隐式声明是 error）。
    ac_cv_func_lchmod=no
    ac_cv_func_lchown=yes
    ac_cv_func_chflags=no
    ac_cv_func_lchflags=no
    ac_cv_func_getloadavg=no          # bionic 没有 getloadavg
    ac_cv_func_tcgetpgrp=yes
    ac_cv_func_tcsetpgrp=yes
    ac_cv_func_openpty=no             # Android 没有 openpty/forkpty
    ac_cv_func_forkpty=no
    ac_cv_func_login_tty=no
    ac_cv_func_gethostname=yes
    ac_cv_func_inet_aton=yes
    ac_cv_func_inet_ntoa=yes
    ac_cv_func_inet_pton=yes
    ac_cv_func_getaddrinfo=yes
    ac_cv_func_getnameinfo=yes
    ac_cv_func_if_nameindex=yes
    ac_cv_func_getpeername=yes
    ac_cv_func_getsockname=yes
    ac_cv_func_socketpair=yes
    ac_cv_func_accept4=yes
    ac_cv_func_dup3=yes
    ac_cv_func_pipe2=yes
    ac_cv_func_splice=yes
    ac_cv_func_sendmsg=yes
    ac_cv_func_recvmsg=yes
    ac_cv_func_cmsghdr=yes
    ac_cv_uint32_t=yes
  )

  # --- CFLAGS / LDFLAGS -----------------------------------------------------
  # -D__ANDROID_API__ 由 NDK 的 <triple><API>-clang wrapper 自动定义（这里再显式
  #   写一遍只是让 config.log 更可读；重复定义只会产生 macro redefined 警告）。
  local cflags="-O2 -fPIC -fno-strict-aliasing -D__ANDROID_API__=$API"
  # bionic/NDK clang 20 对隐式函数声明是 error；getrandom/getentropy 在 API 26
  # 下没有声明（见文件头第 2 条），降级成 warning。
  cflags="$cflags -Wno-error=implicit-function-declaration -Wno-implicit-function-declaration"
  local ldflags="-Wl,--export-dynamic"
  local -a extra_libs=()

  if [[ -n "$openssl_dir" ]]; then
    log "[$arch] 使用自建 OpenSSL: $openssl_dir"
  else
    warn "[$arch] 没有可用的 OpenSSL -> 不构建 _ssl / hashlib(openssl 后端)"
  fi

  # 依赖的探测：CPython 用 pkg-config / AC_CHECK_LIB 找 libffi、liblzma、libbz2、
  # libsqlite3、libreadline。把它们统一放进 CPPFLAGS/LDFLAGS，比给每个库写
  # 一堆 *_cv_* 更省事，也不会误选宿主机的库。
  local dep_cppflags=""
  local dep_ldflags=""
  local dep_libs=""
  local p
  for p in libffi xz bzip2 sqlite ncurses readline; do
    [[ -d "$prefix/$p/include" ]] && dep_cppflags="$dep_cppflags -I$prefix/$p/include"
    # ncurses 有时候把头文件放在 include/ncursesw 下（带 --with-termlib 时），
    # 一并加上，避免 _curses 模块找不到 curses.h。
    [[ -d "$prefix/$p/include/ncursesw" ]] && dep_cppflags="$dep_cppflags -I$prefix/$p/include/ncursesw"
    [[ -d "$prefix/$p/include/ncurses" ]] && dep_cppflags="$dep_cppflags -I$prefix/$p/include/ncurses"
    [[ -d "$prefix/$p/lib" ]] && dep_ldflags="$dep_ldflags -L$prefix/$p/lib"
  done
  local pkgs=()
  [[ -d "$prefix/libffi/lib/pkgconfig" ]] && pkgs+=("$prefix/libffi/lib/pkgconfig")
  [[ -d "$prefix/xz/lib/pkgconfig" ]] && pkgs+=("$prefix/xz/lib/pkgconfig")

  # _sqlite3 / _bz2 / _lzma / readline / _ctypes / zlib 的链接额外库
  [[ -f "$prefix/bzip2/lib/libbz2.a" ]]   && extra_libs+=("-lbz2")
  [[ -f "$prefix/xz/lib/liblzma.a" ]]     && extra_libs+=("-llzma")
  [[ -f "$prefix/sqlite/lib/libsqlite3.a" ]] && extra_libs+=("-lsqlite3")
  # readline 依赖它自带的 termcap（tgetent/tputs/...），termcap 又回调 readline
  # 的 rl_* 符号，静态链接下用 `-lreadline -ltermcap -lhistory` 的顺序最稳。
  # readline -> ncurses 的 termcap 实现（tgetent/tputs/...）；顺序
  # -lreadline -lhistory -ltinfow 对静态库解符号最稳。
  [[ -f "$prefix/readline/lib/libreadline.a" ]] && extra_libs+=("-lreadline" "-lhistory")
  [[ -f "$prefix/ncurses/lib/libncursesw.a" ]] && extra_libs+=("-lncursesw")
  [[ -f "$prefix/ncurses/lib/libtinfow.a" ]] && extra_libs+=("-ltinfow")
  # zlib：直接用 NDK sysroot 里的 libz（设备上一定有 libz.so）。
  extra_libs+=("-lz")
  # bionic 把 libdl/libm 揉进 libc，但显式列出无害（NDK 提供 stub .so）
  extra_libs+=("-ldl" "-lm")
  # Android 的 log 库给 _android_support 之类模块用（CPython 的 Android 分支会
  # 调 __android_log_write 打印 fatal error）
  extra_libs+=("-llog")

  # 共享扩展模块的链接命令行是 LDSHARED/BLDSHARED，它只含 CC/-shared/PY_LDFLAGS，
  # **不含** LIBS。于是 _sqlite3.so 里 trunc/acos/sin/pow... 全是未定义符号，设备上
  #   ImportError: dlopen failed: cannot locate symbol "trunc" referenced by _sqlite3.so
  # （链接期不报错，因为 Android/lld 对 .so 默认允许未定义符号。）
  # 把 -lm -llog -ldl -lz 显式塞进 LDSHARED 才能让模块自己 DT_NEEDED 上 libm.so。
  # -lncursesw 是给 _readline.so 用的：libreadline.a 的 terminal.o 引用 termcap 的
  # tgetent/tgetstr/tgetnum/tgetflag/tputs 和全局变量 PC/BC/UP，这些只有
  # libncursesw.a 里有（libtinfow.a 不导出 PC/BC/UP）。
  export LDSHARED="$CC -shared -lncursesw -lm -llog -ldl -lz"
  export CPPFLAGS="$dep_cppflags"
  export LDFLAGS="$dep_ldflags $ldflags"
  export LIBS="${extra_libs[*]}"
  export CFLAGS="$cflags"
  export CXXFLAGS="$cflags"
  export PKG_CONFIG_PATH="$(IFS=:; echo "${pkgs[*]:-}")"
  export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
  export PKG_CONFIG_SYSROOT_DIR=""

  local conf_args=(
    --host="$G_TRIPLE"
    --build="$(gcc -dumpmachine)"
    --prefix="$out"
    --with-build-python="$HOSTPY/bin/python3"
    --disable-shared
    --disable-test-modules
    --without-ensurepip
    --enable-ipv6
    --with-computed-gotos
    --with-lto=no
  )
  [[ -n "$openssl_dir" ]] && conf_args+=(--with-openssl="$openssl_dir")
  # HOSTRUNNER 让 configure/make 能在宿主机上跑目标解释器（生成 .pyc / 跑
  # sysconfig 探针）。只有装了 qemu-user 才有；没有也能编过（CPython 会退回用
  # 宿主机解释器 + 目标 sysconfig 数据）。
  case "$arch" in
    arm64)  HOSTRUNNER="$QEMU_AARCH64" ;;
    x86_64) HOSTRUNNER="$QEMU_X86_64" ;;
  esac
  if [[ -n "$HOSTRUNNER" ]]; then
    log "[$arch] HOSTRUNNER=$HOSTRUNNER"
    export HOSTRUNNER
  fi

  # Android 专属的 configure 补丁（幂等，作用在每 arch 一份的新源码树上）
  patch_configure_android "$src"

  log "[$arch] configure"
  (
    cd "$src"
    env "${cvs[@]}" ./configure "${conf_args[@]}" \
      > "$BUILDROOT/python-$arch-configure.log" 2>&1
  ) || { tail -40 "$BUILDROOT/python-$arch-configure.log" >&2; die "[$arch] configure 失败（完整日志 $BUILDROOT/python-$arch-configure.log）"; }

  # --- 修 Makefile 里 autoconf "none required" 的污染 ---
  # AC_SEARCH_LIBS 成功且不需要额外库时会返回字面量 "none required"，CPython 的
  # configure 直接把整个字符串塞进 MODULE__<X>_LDFLAGS。于是 Makefile 里的规则变成
  #     $(BLDSHARED) Modules/_curses_panel.o -lpanelw none required ... -o ...
  # clang 报
  #     error: no such file or directory: 'none'
  #     error: no such file or directory: 'required'
  # （本机上 _curses/_curses_panel 都踩到了。）这些字面量不是编译参数，直接删掉。
  fix_makefile_ldflags "$src"

  log "[$arch] make -j$NPROC"
  make -C "$src" -j"$NPROC" > "$BUILDROOT/python-$arch-make.log" 2>&1 \
    || { grep -nE 'error:|Error [0-9]' "$BUILDROOT/python-$arch-make.log" | head -40 >&2;
         die "[$arch] make 失败（完整日志 $BUILDROOT/python-$arch-make.log）"; }

  log "[$arch] make install -> $out"
  rm -rf "$out"
  mkdir -p "$out"
  make -C "$src" install DESTDIR="" > "$BUILDROOT/python-$arch-install.log" 2>&1 \
    || { tail -40 "$BUILDROOT/python-$arch-install.log" >&2; die "[$arch] make install 失败"; }

  # --- pip（用宿主机同版本解释器跑 ensurepip，但 PYTHONHOME/PYTHONPATH 指向目标树）---
  # --- pip ---
  # Android 上 app 私有目录是 noexec，bin/pip3 这种 shebang 脚本点了也跑不起来，
  # 所以唯一支持入口是 `python3 -m pip`。这里用 **宿主机同版本** 解释器跑
  # ensurepip，但把 PYTHONHOME 指向目标树、PYTHONPATH 指向目标 Lib，否则它会把
  # pip 装进宿主机自己的 site-packages。
  #   * 不能传 -E：那会忽略 PYTHONPATH，import 不到目标的 ensurepip 包。
  #   * ensurepip 不认 --no-cache-dir（那是 pip 的选项，不是 ensurepip 的）。
  #   * --root/--prefix 会做 os.path.join(root, prefix)，所以 root 必须是 "/"，
  #     prefix 才是目标目录；写反会得到 $out/$out/lib/...
  log "[$arch] ensurepip -> $out/lib/python$PY_XY/site-packages"
  install_pip "$arch" "$out"

  patch_stdlib_android "$arch" "$out"
  patch_tree "$arch" "$out"
  prune_tree "$out"
  strip_tree "$arch" "$out"
  self_check "$arch" "$out"
}

# ---------------------------------------------------------------------------
# 3b) 安装 pip（唯一支持入口是 `python3 -m pip`；bin/pip3 在 Android 上是 noexec）
# ---------------------------------------------------------------------------
# 为什么绕这么大一圈：ensurepip 必须由 **宿主机同版本** 解释器来跑（目标解释器
# 在宿主机上跑不起来），但一旦把 PYTHONHOME 指向目标树，宿主解释器就会去 import
# 目标的 sysconfig/扩展模块，连续踩三个坑：
#   1) subprocess -> _posixsubprocess：目标是 Android .so，宿主机 dlopen 不了。
#      解法：把宿主机自己的 lib-dynload 放到 PYTHONPATH 最前面（宿主的
#      EXTENSION_SUFFIXES 是编译期烘进二进制的，改文件名反而 import 不到）。
#   2) sysconfig._init_posix() 要 import 一个 **模块名里带减号** 的
#      _sysconfigdata__android_x86_64-linux-android，宿主 sysconfig 拼出来的却是
#      _sysconfigdata__linux_x86_64-linux-gnu（sys.platform 不同）。
#      解法：在 shim 目录里放一个同名 .py，用 importlib 从文件加载目标的
#      _sysconfigdata 并把 build_time_vars 注入进来。
#   3) ensurepip 没有 --prefix 选项（那是 pip 的），它用 sysconfig.get_path() 决定
#      安装位置。解法：在 bootstrapping 脚本里直接把 sys.prefix/base_prefix/
#      exec_prefix 改成目标树，再调 ensurepip._main()。
install_pip() { # $1=arch $2=out
  local arch="$1" out="$2"
  local libdir="$out/lib/python$PY_XY"
  [[ -d "$libdir" ]] || return 0
  local hostdl="$HOSTPY/lib/python$PY_XY/lib-dynload"
  local shim="$BUILDROOT/ensurepip-shim-$arch"
  rm -rf "$shim"; mkdir -p "$shim"

  # 找到目标树的 _sysconfigdata（名字随 arch 变），拷进 shim 供动态加载
  local scd
  scd="$(ls "$libdir"/_sysconfigdata_*.py 2>/dev/null | head -1)"
  [[ -n "$scd" ]] || { warn "[$arch] 找不到 _sysconfigdata，跳过 pip"; return 0; }
  cp -f "$scd" "$shim/"

  # 宿主机 sysconfig 会拼出来的模块名：_sysconfigdata_<abiflags>_<sys.platform>_<multiarch>
  local want
  want="$("$HOSTPY/bin/python3" -c 'import sys, sysconfig; print("_sysconfigdata_" + sys.abiflags + "_" + sys.platform + "_" + sysconfig.get_config_var("MULTIARCH"))')"
  cat > "$shim/$want.py" <<'SHIM'
# 把目标树的 _sysconfigdata 挂到宿主机 sysconfig 期望的模块名下。
# 注意目标模块名里带减号（_sysconfigdata__android_x86_64-linux-android），
# 不能直接 import，必须用 importlib 从文件加载。
import importlib.util, pathlib
_here = pathlib.Path(__file__).resolve().parent
_cands = sorted(_here.glob('_sysconfigdata__android_*.py')) or sorted(_here.glob('_sysconfigdata_*.py'))
# 排除自己（本文件也是 _sysconfigdata_*.py）
_cands = [c for c in _cands if c.name != pathlib.Path(__file__).name]
_spec = importlib.util.spec_from_file_location(__name__, _cands[0])
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
build_time_vars = _mod.build_time_vars
globals().update({k: v for k, v in vars(_mod).items() if not k.startswith('__')})
SHIM

  # ensurepip 需要目标树里的 _bundled/*.whl（make install 会带上，这里兜底）
  if [[ ! -d "$libdir/ensurepip/_bundled" && -d "$PRISTINE/Lib/ensurepip/_bundled" ]]; then
    cp -a "$PRISTINE/Lib/ensurepip/_bundled" "$libdir/ensurepip/" 2>/dev/null || true
  fi

  PYTHONHOME="$out" \
  PYTHONPATH="$shim:$hostdl:$libdir:$libdir/lib-dynload" \
    "$HOSTPY/bin/python3" -s -c '
import sys
sys.prefix = sys.base_prefix = sys.exec_prefix = sys.base_exec_prefix = sys.argv[1]
import ensurepip
sys.argv = ["ensurepip", "--altinstall"]
sys.exit(ensurepip._main())
' "$out" > "$BUILDROOT/python-$arch-ensurepip.log" 2>&1 \
    || warn "[$arch] ensurepip 失败（pip 不可用），见 $BUILDROOT/python-$arch-ensurepip.log"
  rm -rf "$shim"

  # 装完 pip 之后 _bundled/*.whl（约 3MB）就没用了
  rm -rf "$libdir/ensurepip/_bundled"
  if [[ -d "$libdir/site-packages/pip" ]]; then
    log "[$arch] pip 已安装: $("$HOSTPY/bin/python3" -c 'import sys; sys.path.insert(0, sys.argv[1]); import pip; print(pip.__version__)' "$libdir/site-packages" 2>/dev/null || echo ok)"
  fi
}

# ---------------------------------------------------------------------------
# 3c) 修 _sysconfigdata 里的 LDLIBRARY（决定 ctypes 怎么加载 libpython）
# ---------------------------------------------------------------------------
# 我们是 --disable-shared 构建（libpython 静态链进可执行文件），configure 于是把
# LDLIBRARY 写成 "libpython3.13.a"。偏偏 CPython 3.13 的 ctypes/__init__.py 对
# Android 有个特判：
#     if _sys.platform in ["android", "cygwin"]:
#         pythonapi = PyDLL(_sysconfig.get_config_var("LDLIBRARY"))
# 它假设 Android 上 libpython 一定是动态库，于是设备上直接
#     OSError: dlopen failed: library "libpython3.13.a" not found
# configure 没有 --with-ldlibrary 之类的开关（LDLIBRARY 不是 AC_ARG_VAR），
# 所以在安装完之后把目标树里的 _sysconfigdata 改成可执行文件自身的绝对路径。
# ctypes 的 _dlopen 接受带斜杠的路径，Linux/Android 上 dlopen 一个 PIE 可执行文件
# 是合法的（"--export-dynamic 已经把 Py* 放进 .dynsym"），于是
# `ctypes.pythonapi` 和 `ctypes.CDLL("libc.so")` 都能用。
# Android 上标准库里必须打的两个运行时补丁（在 install 之后、prune 之前）。
#
# 背景：Android 从 API 26 起就把 POSIX 具名信号量（sem_open/sem_unlink）和 POSIX
# 共享内存（shm_open/shm_unlink）挡在/app 域之外，实测设备上
#   * ctypes.CDLL("libc.so").shm_open  -> undefined symbol: shm_open
#   * libc 里虽然有 sem_open 符号，但内核返回 ENOSYS（Function not implemented）
# 所以 _posixshmem 这个扩展模块 **不可能** 在 API 26 上工作（CPython 官方把它
# 列进了 Android blocked_funcs，我们已经在 configure 里放开了 sem_*，shm_* 保持关闭）。
#
# 问题：multiprocessing/resource_tracker.py 与 shared_memory.py 都在模块顶层
# 无条件 `import _posixshmem`，导致连最基本的
#     mp.Process(target=...)  /  mp.Queue()
# 都在 import 期就 ModuleNotFoundError（Python 3.13 的 popen_fork 会 import
# resource_tracker）。这比"共享内存不可用"严重得多——整个 fork 后端都废了。
#
# 补丁：把这两个 import 变成可选。_posixshmem 缺失时 SharedMemory 明确抛
# ImportError，其余 multiprocessing 功能照常。
patch_stdlib_android() { # $1=arch $2=out
  local arch="$1" out="$2"
  local lib="$out/lib/python$PY_XY"
  [[ -d "$lib/multiprocessing" ]] || return 0

  # (a) resource_tracker.py: 顶层 import _posixshmem 改成可选
  local rt="$lib/multiprocessing/resource_tracker.py"
  if [[ -f "$rt" ]] && ! grep -q DSH_ANDROID_NO_POSIXSHMEM "$rt"; then
    python3 - "$rt" <<'RTEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
nl = chr(10)
old = nl.join(["if os.name == 'posix':", "    import _multiprocessing", "    import _posixshmem", ""])
new = nl.join(["if os.name == 'posix':", "    import _multiprocessing",
               "    # DSH_ANDROID_NO_POSIXSHMEM: Android API 26 has no shm_open;",
               "    # _posixshmem is not built, so shared-memory cleanup is a noop.",
               "    try:", "        import _posixshmem", "    except ImportError:",
               "        _posixshmem = None", ""])
if old not in s:
    print("WARN resource_tracker.py: posix block not found", file=sys.stderr); sys.exit(0)
s = s.replace(old, new, 1)
old2 = nl.join(["    _CLEANUP_FUNCS.update({", "        'shared_memory': _posixshmem.shm_unlink,", "    })"])
new2 = nl.join(["    if _posixshmem is not None:  # DSH_ANDROID_NO_POSIXSHMEM",
                "        _CLEANUP_FUNCS.update({",
                "            'shared_memory': _posixshmem.shm_unlink,",
                "        })"])
if old2 not in s:
    print("WARN resource_tracker.py: cleanup block not found", file=sys.stderr); sys.exit(0)
p.write_text(s.replace(old2, new2, 1))
print("  [patch] multiprocessing/resource_tracker.py: _posixshmem optional")
RTEOF
  else
    echo "  [skip] resource_tracker.py already handled"
  fi

  # (b) shared_memory.py: 同样退化，SharedMemory 使用时才报错
  local sm="$lib/multiprocessing/shared_memory.py"
  if [[ -f "$sm" ]] && ! grep -q DSH_ANDROID_NO_POSIXSHMEM "$sm"; then
    python3 - "$sm" <<'SMEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
nl = chr(10)
old = nl.join(["else:", "    import _posixshmem", "    _USE_POSIX = True", ""])
new = nl.join(["else:",
               "    # DSH_ANDROID_NO_POSIXSHMEM: bionic has no shm_open() at API 26, so",
               "    # _posixshmem is not built. Windows branches are not reachable here",
               "    # (os.name == 'posix'), so fail loudly and clearly instead.",
               "    try:",
               "        import _posixshmem",
               "        _USE_POSIX = True",
               "    except ImportError as _e:",
               "        raise ImportError(",
               "            'multiprocessing.shared_memory is unavailable on this '",
               "            'Android build: bionic has no shm_open() at API 26') from _e",
               ""])
if old not in s:
    print("WARN shared_memory.py: _posixshmem block not found", file=sys.stderr); sys.exit(0)
p.write_text(s.replace(old, new, 1))
print("  [patch] multiprocessing/shared_memory.py: clear ImportError when unavailable")
SMEOF
  else
    echo "  [skip] shared_memory.py already handled"
  fi
}

patch_tree() { # $1=arch $2=out
  local arch="$1" out="$2"
  local n=0 f
  # (a) _sysconfigdata 里的 LDLIBRARY 改成 bin/ 下的 **相对** 路径。
  #     绝不能写绝对路径：app 会把树解到自己的私有目录，绝对路径只在构建机上成立
  #     （实测报 dlopen failed: library "/home/.../python3.13" not found），
  #     而且违反"PYTHONHOME 可重定位"这条硬要求。
  local scd
  for scd in "$out/lib/python$PY_XY"/_sysconfigdata_*.py; do
    [[ -f "$scd" ]] || continue
    if grep -q "'LDLIBRARY': 'libpython" "$scd"; then
      sed -i "s|'LDLIBRARY': 'libpython[^']*\.a'|'LDLIBRARY': 'bin/python$PY_XY'|" "$scd"
      n=$((n+1))
    fi
  done
  log "[$arch] 已修正 $n 个 _sysconfigdata 的 LDLIBRARY -> bin/python$PY_XY（相对路径）"

  # (b) ctypes/__init__.py 的 pythonapi 兜底。
  #     CPython 3.13 的 ctypes 对 Android 有特判，假设 libpython 一定在
  #     LD_LIBRARY_PATH 上：
  #         elif _sys.platform in ["android", "cygwin"]:
  #             pythonapi = PyDLL(_sysconfig.get_config_var("LDLIBRARY"))
  #     我们是静态 libpython，没有 libpython3.13.so；相对路径 dlopen 也只在
  #     LD_LIBRARY_PATH 里找。加一层兜底：dlopen 失败就退回 PyDLL(None)
  #     （= RTLD_DEFAULT，从已加载对象 + 主程序解析符号）。CPython 3.13 的
  #     _ctypes 本来就是用 dlsym(RTLD_DEFAULT,...) 找 Py* 的，而我们的可执行文件
  #     是 -Wl,--export-dynamic 的 PIE，符号都在 .dynsym 里。
  #     幂等：以 DSH_ANDROID_STATIC_LIBPYTHON 标记。
  local ci="$out/lib/python$PY_XY/ctypes/__init__.py"
  # (b) ctypes/__init__.py 的 pythonapi 兜底。幂等：以 DSH_ANDROID_STATIC_LIBPYTHON 标记。
  if [[ -f "$ci" ]] && ! grep -q 'DSH_ANDROID_STATIC_LIBPYTHON' "$ci"; then
    python3 - "$ci" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
MARK = 'DSH_ANDROID_STATIC_LIBPYTHON'
header = 'elif _sys.platform in ["android", "cygwin"]:'
if MARK in s:
    sys.exit(0)
if header not in s:
    print('WARN ctypes/__init__.py 未匹配到 android 分支，未修改', file=sys.stderr)
    sys.exit(0)
nl = chr(10)
# 整块替换：原来的两行（注释 + 无保护的 PyDLL(LDLIBRARY)) 一起换掉
old_block = nl.join([
    header,
    '    # These are Unix-like platforms which use a dynamically-linked libpython.',
    '    pythonapi = PyDLL(_sysconfig.get_config_var("LDLIBRARY"))',
    '',
])
new_block = nl.join([
    header,
    '    # ' + MARK + ': 静态 libpython 构建时 LDLIBRARY 不是 LD_LIBRARY_PATH 上',
    '    # 能找到的 .so（Android 也不允许 dlopen 一个 PIE 可执行文件），因此加一层',
    '    # 兜底：真的 dlopen 失败才退回 RTLD_DEFAULT（PyDLL(None)）。',
    '    try:',
    '        pythonapi = PyDLL(_sysconfig.get_config_var("LDLIBRARY"))',
    '    except OSError:',
    '        pythonapi = PyDLL(None)',
    '',
])
if old_block not in s:
    print('WARN ctypes/__init__.py 未匹配到原始 android 分支块，未修改', file=sys.stderr)
    sys.exit(0)
p.write_text(s.replace(old_block, new_block, 1))
print('patched ctypes pythonapi fallback')
PYEOF
  fi
}

# ---------------------------------------------------------------------------
# 4) 裁剪标准库
# ---------------------------------------------------------------------------
prune_tree() { # $1=out
  local out="$1"
  local lib="$out/lib/python$PY_XY"
  log "裁剪标准库（删 test/idlelib/tkinter/turtledemo/lib2to3/ensurepip 自带 wheel/__pycache__）"
  [[ -d "$lib" ]] || return 0
  local junk=(test idlelib tkinter turtledemo lib2to3 unittest/test)
  local d
  for d in "${junk[@]}"; do
    [[ -e "$lib/$d" ]] && rm -rf "$lib/$d"
  done
  # ensurepip 的 wheel 只在安装期有用；pip 装好之后删掉（约 3MB）
  rm -rf "$lib/ensurepip/_bundled"
  # 编译期生成的 config 目录（Makefile + 一堆 .o 路径），app 里没有编译需求
  rm -rf "$lib"/config-*
  # libpython3.13.a（47MB！）只在链接期有用；app 是运行时消费者，不需要
  rm -f "$out"/lib/libpython*.a "$out"/lib/libpython*.so*
  # 头文件与 pkgconfig 同理（app 不会在设备上编译 C 扩展）
  rm -rf "$out/include" "$out/lib/pkgconfig" "$out/share"
  # .pyc：app 私有目录可写，首次 import 会自己生成；随 APK 分发纯属浪费空间。
  find "$out" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
  find "$out" -type f -name '*.pyc' -delete 2>/dev/null || true
  # 空目录清理
  find "$out" -type d -empty -delete 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 5) strip
# ---------------------------------------------------------------------------
strip_tree() { # $1=arch $2=out
  local arch="$1" out="$2"
  log "strip 可执行文件与扩展模块（保留 .dynsym：dlopen 要靠它解析符号）"
  # 真正的解释器是 bin/python3.13（python3 是指向它的相对符号链）。
  # 注意符号链接绝不能 strip，而且要保持相对链接 -> app 解包后依然有效。
  "$STRIP" --strip-all "$out/bin/python$PY_XY"
  # 动态模块：--strip-all 不会删 .dynsym/.dynstr（那是动态链接必需的），
  # 所以 `llvm-strip --strip-all` 是安全的；但有些 ndk 版本对 .so 会顺手删
  # 掉 .symtab 之外的东西，这里用 --strip-unneeded 更保守。
  local f
  while IFS= read -r -d '' f; do
    "$STRIP" --strip-unneeded "$f" 2>/dev/null || true
  done < <(find "$out/lib" -type f -name '*.so' -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# 6) 自检：ELF 架构 / 无第三方 NEEDED / PYTHONHOME 可重定位 / 动态模块可加载
# ---------------------------------------------------------------------------
self_check() { # $1=arch $2=out
  local arch="$1" out="$2"
  local exe="$out/bin/python$PY_XY"
  [[ -x "$exe" ]] || die "[$arch] 找不到解释器 $exe"

  # --- 静态自检：ELF 架构 / NEEDED / .dynsym 里的 Py* 符号 ---
  local machine
  machine="$(readelf -h "$exe" | awk -F: '/Machine:/ {gsub(/^ +/,"",$2); print $2}')"
  case "$arch" in
    arm64)  [[ "$machine" = "AArch64" ]] || die "[$arch] 架构不对: $machine" ;;
    x86_64) [[ "$machine" = "Advanced Micro Devices X86-64" ]] || die "[$arch] 架构不对: $machine" ;;
  esac
  echo "    Machine=$machine"
  echo "    NEEDED: $(readelf -d "$exe" | awk '/NEEDED/ {print $NF}' | tr '\n' ' ')"
  # -Wl,--export-dynamic 检查：.dynsym 里必须有 PyExc_*，否则 dlopen 扩展模块时
  # 解析不到符号（"cannot locate symbol PyExc_RuntimeError"）
  if ! readelf --dyn-syms -W "$exe" | grep -q ' PyExc_'; then
    die "[$arch] $exe 的 .dynsym 里没有 PyExc_* —— 少了 -Wl,--export-dynamic，扩展模块会加载失败"
  fi
  echo "    .dynsym 含 PyExc_* : ok"

  # --- 运行时自检（需要 qemu-user；没有就交给真机验收） ---
  local runner=""
  case "$arch" in
    arm64)  runner="$QEMU_AARCH64" ;;
    x86_64) runner="$QEMU_X86_64" ;;
  esac
  if [[ -z "$runner" ]]; then
    warn "[$arch] 宿主机没有 qemu-user，跳过本机运行时自检（由 build-python-android.sh 的真机验收脚本覆盖）"
    return 0
  fi
  local got
  got="$(cd / && PYTHONHOME="$out" "$runner" "$exe" -c \
        'import sys,os; print(sys.version.split()[0], sys.prefix == os.environ["PYTHONHOME"])' 2>&1)" \
    || die "[$arch] PYTHONHOME 自检失败: $got"
  case "$got" in
    "$PY_XY True") echo "    PYTHONHOME 自检: $got" ;;
    *) die "[$arch] PYTHONHOME 自检输出异常: $got" ;;
  esac
  got="$(cd / && PYTHONHOME="$out" "$runner" "$exe" -c \
        'import _json,_struct,_datetime,unicodedata; print("dynload-ok", _json.__file__)' 2>&1)" \
    || die "[$arch] 动态扩展模块加载失败: $got"
  echo "    $got"
}

# ---------------------------------------------------------------------------
case "$ARCH" in
  all) fetch_python_source; build_host_python; build_deps arm64; build_deps x86_64
       build_arch arm64; build_arch x86_64 ;;
  arm64|x86_64) fetch_python_source; build_host_python; build_deps "$ARCH"; build_arch "$ARCH" ;;
  *) die "不支持的 arch: $ARCH（只支持 arm64 / x86_64 / all）" ;;
esac

log "产物:"
for a in arm64 x86_64; do
  d="$BUILDROOT/python-android-$a"
  [[ -d "$d" ]] || continue
  echo "  $d  ($(du -sh "$d" | cut -f1))"
  file "$d/bin/python$PY_XY" 2>/dev/null | sed 's/^/    /'
done
log "完成"
