#!/usr/bin/env bash
# 交叉编译 ripgrep for Android（动态链接 bionic、自包含单文件可执行，带 PCRE2）。
#
# 用法:
#   ./scripts/build-ripgrep-android.sh <arch>
#     <arch> = arm64 | x86_64 | all
#
# 例:  ./scripts/build-ripgrep-android.sh x86_64
#      ./scripts/build-ripgrep-android.sh all
#
# 产物（恰好这两个路径；prepare-app-assets.sh 会把它拷成 app 的 libripgrep.so）:
#   .toolchain/build/ripgrep-android-arm64/rg
#   .toolchain/build/ripgrep-android-x86_64/rg
#
# 为什么是动态链接 + PIE，而不是像 bash 那样静态链接：
#   DSH 的 glob / grep 工具通过 `@deepseek-ai/dsh-tool-fs-search` 起 ripgrep。
#   Android 只允许从 app 的 nativeLibraryDir 执行文件，所以这个二进制会以
#   `libripgrep.so` 的名义随 jniLibs 打包，再由 app 软链到 `<files>/bin/rg` 执行
#   （必须是「普通可执行文件」，不是需要 dlopen 的共享库）。Rust 的 android
#   target 默认就产出 PIE（ET_DYN + INTERP=/system/bin/linker64）且只 NEEDED
#   bionic 系统库，正好符合要求。**不要**照抄 build-bash-android.sh 里的
#   `-C target-feature=+crt-static`：那会去掉 INTERP，验收标准明确要求
#   INTERP=/system/bin/linker64。
#
# ---------------------------------------------------------------------------
# 网络前提：github.com / static.rust-lang.org / static.crates.io /
# index.crates.io 在本机全部不可达。本脚本只用下面这些可达镜像：
#   rustup dist : https://mirrors.ustc.edu.cn/rust-static   (首选，能装指定版本)
#                 https://mirrors.tuna.tsinghua.edu.cn/rustup (兜底，只有 stable)
#   crates 索引 : https://mirrors.ustc.edu.cn/crates.io-index (sparse)
#                 https://rsproxy.cn/index                    (sparse，兜底)
#   crate 包体  : 由上面索引的 config.json `dl` 字段给出，两个镜像都可达
# ---------------------------------------------------------------------------
# Android/bionic + 受限网络的坑（都已在本脚本里处理）:
#
# 0) Rust 未安装。脚本自己把 rustup + 工具链装进 .toolchain/rust/（RUSTUP_HOME /
#    CARGO_HOME 都指到工作区内），不污染 ~/.cargo、~/.rustup，工作区保持自包含。
#    rustup-init 从镜像的 `rustup/archive/<版本>/` 取，**带 sha256 校验**
#    （见 RUSTUP_INIT_SHA256），所以重跑不会因为镜像悄悄升级而改变结果。
#
# 1) 指定版本的工具链只能从**中科大**镜像装。清华的 `rustup/dist/` 下只有
#    `channel-rust-stable.toml`，`dist/channel-rust-1.98.1.toml` 是 404；
#    中科大两个都有。所以 RUST_DIST_MIRRORS 把中科大排第一。
#
# 2) crates.io 不可达，必须做 source replacement。但**不能用清华的
#    crates.io-index**：它的 config.json 里 `dl` 仍然指向 `static.crates.io/crates`，
#    cargo 拿到包体 URL 之后照样下载失败。中科大和 rsproxy 的 config.json 指向
#    各自的镜像地址，才真正可用。脚本会先探测索引可用性再写 config.toml。
#    注意 config.toml 写在 $CARGO_HOME 下；因为 CARGO_HOME 被我们改写，
#    `~/.cargo/config.toml` 完全不会被读到，不会和宿主环境互相干扰。
#
# 3) **ripgrep 本体不在镜像的稀疏索引里**（`ri/pe/ripgrep` 404；`ba/te/bat`
#    同样 404），所以 `cargo install ripgrep` 这条路走不通。改为直接从镜像的
#    包体接口下载 `ripgrep-<ver>.crate` 解包，把它当作「本地根包」构建 ——
#    cargo 不需要根包出现在 registry 索引里，只有它的依赖需要。实测 15.2.0 的
#    Cargo.lock 里 54 个包**全部**能在镜像稀疏索引中找到。
#
# 4) 带连字符的环境变量在 bash 里根本 export 不出去：
#       export CC_x86_64-linux-android=...   ->  not a valid identifier
#    而 cc-rs 查 CC 的顺序是 `CC_<target>` 然后 `CC_<target 下划线化>`，所以统一
#    用下划线形式 `CC_aarch64_linux_android` / `AR_aarch64_linux_android`。
#    （CARGO_TARGET_<TRIPLE>_LINKER 本来就是下划线，不受影响。）
#
# 5) 不给 CC 一定失败：TARGET 里含 "android" 时 cc-rs 会自己拼一个
#    `x86_64-linux-android-clang`（**没有 API 级别后缀**），NDK 里不存在这个
#    文件名，直接报 `ToolNotFound: failed to find tool "x86_64-linux-android-clang"`。
#    必须显式指定带 API 级别的 wrapper（...-android26-clang）。
#
# 6) **PCRE2 必须强制走 vendored 静态编译**。pcre2-sys 的 build.rs 第一步就是
#    `pkg_config::probe_library("libpcre2-8")`，宿主机装了 libpcre2-dev 时它会
#    探测**成功**并直接返回，于是链接阶段去要宿主的 x86_64 libpcre2-8（交叉链接
#    失败，或者更糟：静默链上宿主库）。设 `PCRE2_SYS_STATIC=1` 才会去编译
#    crate 里 vendored 的 PCRE2 C 源码，用我们的 NDK clang。
#
# 7) PCRE2 的 JIT 在 aarch64-linux-android 上被上游**硬编码关闭**：
#    pcre2-sys 的 `enable_jit()` 里有一行
#        if target == "aarch64-linux-android" { return; }   // "does not build"
#    x86_64-linux-android 没有被排除，所以 JIT 是开的。这只影响性能，不影响
#    `-P` 的功能语义：设备上 `rg --version` 分别显示
#        arm64 : PCRE2 10.45 is available (JIT is unavailable)
#        x86_64: PCRE2 10.45 is available (JIT is available)
#
# 8) 发布包里自带 Cargo.lock，且实测 cargo 不会改写它，所以加 `--locked`
#    锁死依赖版本（配合上面的 sha256 校验，整条链路可复现）。
#
# 9) release profile 里上游带 `debug = 1`（方便 cargo install 调试），不 strip
#    有 37MB。用 NDK 的 `llvm-strip --strip-all` 之后 arm64 ~5.3MB、x86_64 ~5.9MB
#    （x86_64 更大是因为多了 PCRE2 JIT 的 sljit 代码）。
#
# 10) 产物自检只做静态检查（宿主上跑不了目标二进制）：机器类型、INTERP、
#     NEEDED 白名单、无 RPATH/RUNPATH、PCRE2 字符串存在。真正的功能验收
#     （--version / --files / --json / -P / 退出码 0/1/2）要在设备上跑。
# ---------------------------------------------------------------------------
set -euo pipefail

ARCH="${1:?用法: build-ripgrep-android.sh <arm64|x86_64|all>}"

# ripgrep 15.2.0：edition 2024，要求 rust >= 1.85。官方与 Termux 同版本。
RG_VER="${DSH_RG_VERSION:-15.2.0}"
RG_CRATE="ripgrep-${RG_VER}.crate"
# 15.2.0 的包体哈希已经用三个镜像（中科大 / 阿里云 / rsproxy）交叉校验一致。
# 换版本时用 DSH_RG_SHA256=... 覆盖；留空则跳过校验（只做 gzip 完整性检查）。
RG_SHA256="${DSH_RG_SHA256:-}"
if [[ -z "$RG_SHA256" && "$RG_VER" = 15.2.0 ]]; then
  RG_SHA256="a30750b6d0743bfdd2656ebbaf4555aa278c43144b84bc389bcbfa399485ec71"
fi

# 工具链版本固定，保证可复现（1.98.1 是本脚本实测通过的版本）。
RUST_VER="${DSH_RG_RUST_VERSION:-1.98.1}"
# rustup-init 也从镜像 archive 取固定版本；1.29.x 之前的 1.28.2 足够装 1.98.1。
RUSTUP_VER="${DSH_RG_RUSTUP_VERSION:-1.28.2}"
RUSTUP_INIT_SHA256="${DSH_RG_RUSTUP_INIT_SHA256:-}"
if [[ -z "$RUSTUP_INIT_SHA256" && "$RUSTUP_VER" = 1.28.2 ]]; then
  RUSTUP_INIT_SHA256="20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c"
fi

API="${DSH_RG_API:-26}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC="$ROOT/.toolchain"
NDK="$TC/sdk/ndk/29.0.14206865"
LLVM="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
DL="$TC/downloads"
BUILDROOT="$TC/build"
SRC="$BUILDROOT/ripgrep-$RG_VER"

# Rust 工具链落盘在工作区内（.toolchain 已 gitignore），不动 ~/.cargo、~/.rustup。
export RUSTUP_HOME="$TC/rust/rustup"
export CARGO_HOME="$TC/rust/cargo"
# 防止外层环境把工具链选择透进来。
unset RUSTUP_TOOLCHAIN || true

NPROC="$(nproc)"

RUST_DIST_MIRRORS=(
  "${DSH_RG_RUST_DIST_MIRROR:-https://mirrors.ustc.edu.cn/rust-static}"
  "https://mirrors.tuna.tsinghua.edu.cn/rustup"
)
# sparse 索引镜像（不带 sparse+ 前缀，探测用；写 config 时再加）。
INDEX_MIRRORS=(
  "${DSH_RG_INDEX_MIRROR:-https://mirrors.ustc.edu.cn/crates.io-index}"
  "https://rsproxy.cn/index"
)
# crate 包体镜像（按 {base}/{name}/{version}/download 拼）。
CRATE_MIRRORS=(
  "${DSH_RG_CRATE_MIRROR:-https://mirrors.ustc.edu.cn/crates.io/api/v1/crates}"
  "https://mirrors.aliyun.com/crates/api/v1/crates"
  "https://rsproxy.cn/api/v1/crates"
)

log() { echo "==> $*"; }
die() { echo "错误: $*" >&2; exit 1; }

[[ -d "$NDK" ]] || die "找不到 NDK: $NDK（先 source scripts/env.sh 并确认 .toolchain 完整）"
[[ -x "$LLVM/bin/llvm-strip" ]] || die "找不到 NDK LLVM 工具链: $LLVM/bin"
[[ -x "$LLVM/bin/aarch64-linux-android${API}-clang" ]] || die "找不到 NDK wrapper: aarch64-linux-android${API}-clang"
[[ -x "$LLVM/bin/x86_64-linux-android${API}-clang" ]] || die "找不到 NDK wrapper: x86_64-linux-android${API}-clang"
for t in curl tar sha256sum readelf file strings python3; do
  command -v "$t" >/dev/null 2>&1 || die "宿主机缺少必要工具: $t"
done

# ===========================================================================
# 1) Rust 工具链（rustup + 指定版本 + 两个 android target）
# ===========================================================================
rust_ready() {
  local rc="$CARGO_HOME/bin/rustc" targets
  [[ -x "$rc" ]] || return 1
  "$rc" -V 2>/dev/null | grep -q "^rustc $RUST_VER " || return 1
  targets="$("$CARGO_HOME/bin/rustup" target list --installed 2>/dev/null || true)"
  grep -qx 'aarch64-linux-android' <<<"$targets" || return 1
  grep -qx 'x86_64-linux-android' <<<"$targets" || return 1
  return 0
}

fetch_rustup_init() {
  local dest="$DL/rustup-init-$RUSTUP_VER" url ok=no
  if [[ -x "$dest" ]]; then
    log "已存在 rustup-init: $dest"
    return 0
  fi
  mkdir -p "$DL"
  for base in "${RUST_DIST_MIRRORS[@]}"; do
    url="$base/rustup/archive/$RUSTUP_VER/x86_64-unknown-linux-gnu/rustup-init"
    log "下载 $url"
    if curl -fSL --retry 3 --connect-timeout 20 --max-time 300 -o "$dest.part" "$url"; then
      mv -f "$dest.part" "$dest"
      chmod +x "$dest"
      ok=yes
      break
    fi
    rm -f "$dest.part"
    echo "    镜像不可用，换下一个" >&2
  done
  [[ "$ok" = yes ]] || die "所有镜像都下载不到 rustup-init $RUSTUP_VER: ${RUST_DIST_MIRRORS[*]}"
  if [[ -n "$RUSTUP_INIT_SHA256" ]]; then
    echo "$RUSTUP_INIT_SHA256  $dest" | sha256sum -c --status \
      || die "rustup-init 校验失败: $dest（期望 sha256=$RUSTUP_INIT_SHA256）"
  fi
  log "rustup-init 校验通过"
}

install_rust() {
  local init ok=no
  fetch_rustup_init
  init="$DL/rustup-init-$RUSTUP_VER"

  # 这两个变量必须在调 rustup-init **之前**导出，否则它会写 ~/.rustup、~/.cargo。
  mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"
  for base in "${RUST_DIST_MIRRORS[@]}"; do
    log "用 $base 安装 rust $RUST_VER + aarch64/x86_64-linux-android"
    if RUSTUP_DIST_SERVER="$base" RUSTUP_UPDATE_ROOT="$base/rustup" \
       "$init" -y --no-modify-path --profile minimal \
         --default-toolchain "$RUST_VER" \
         -t aarch64-linux-android -t x86_64-linux-android; then
      ok=yes
      break
    fi
    echo "    该镜像装不了 $RUST_VER（清华只有 stable），换下一个" >&2
  done
  [[ "$ok" = yes ]] || die "所有镜像都装不了 rust $RUST_VER: ${RUST_DIST_MIRRORS[*]}"
  rust_ready || die "rust 安装后自检失败（rustc $RUST_VER / android targets）"
}

# ===========================================================================
# 2) cargo 走镜像稀疏索引（crates.io 不可达）
# ===========================================================================
write_cargo_config() {
  local cand picked="" probe
  for cand in "${INDEX_MIRRORS[@]}"; do
    # 用 libc 当探针：索引里一定有它，能 200 说明这个 sparse 索引是可用的。
    if curl -fsS --connect-timeout 10 --max-time 30 -o /dev/null "$cand/li/bc/libc"; then
      picked="$cand"
      break
    fi
    echo "    稀疏索引不可用，换下一个: $cand" >&2
  done
  [[ -n "$picked" ]] || die "所有 crates 稀疏索引镜像都不可达: ${INDEX_MIRRORS[*]}"
  log "crates 稀疏索引: $picked"
  mkdir -p "$CARGO_HOME"
  cat > "$CARGO_HOME/config.toml" <<EOF
# 由 scripts/build-ripgrep-android.sh 生成：crates.io 在本机不可达，做 source
# replacement 指向可达的稀疏索引镜像。注意不能换成清华的 crates.io-index ——
# 它的 config.json 里 dl 还指向 static.crates.io，包体照样下不来。
[source.crates-io]
replace-with = "dsh-mirror"

[source.dsh-mirror]
registry = "sparse+$picked/"

[net]
retry = 5
EOF
}

# ===========================================================================
# 3) 下载 + 解包 ripgrep 源码（cargo install 走不通：索引里没有 ripgrep 本体）
# ===========================================================================
sha_ok() {   # $1=文件；RG_SHA256 为空时退化为 gzip 完整性检查
  if [[ -n "$RG_SHA256" ]]; then
    echo "$RG_SHA256  $1" | sha256sum -c --status 2>/dev/null
  else
    gzip -t "$1" 2>/dev/null
  fi
}

fetch_source() {
  mkdir -p "$DL" "$BUILDROOT"
  local tgz="$DL/$RG_CRATE" url ok=no

  if [[ -f "$tgz" ]] && sha_ok "$tgz"; then
    log "已存在校验通过的源码包: $tgz"
  else
    rm -f "$tgz"
    for url in "${CRATE_MIRRORS[@]}"; do
      log "下载 $url/ripgrep/$RG_VER/download"
      if curl -fSL --retry 3 --connect-timeout 20 --max-time 300 -o "$tgz.part" \
           "$url/ripgrep/$RG_VER/download"; then
        mv -f "$tgz.part" "$tgz"
        ok=yes
        break
      fi
      rm -f "$tgz.part"
      echo "    镜像不可用，换下一个" >&2
    done
    [[ "$ok" = yes ]] || die "所有镜像都下载失败: ${CRATE_MIRRORS[*]}"
    sha_ok "$tgz" || die "源码包校验失败: $tgz（期望 sha256=$RG_SHA256）"
    log "源码包校验通过"
  fi

  if [[ -f "$SRC/Cargo.toml" ]] && grep -q "^version = \"$RG_VER\"$" "$SRC/Cargo.toml"; then
    log "源码已解包: $SRC"
  else
    log "解包到 $SRC"
    rm -rf "$SRC" "$SRC.tmp"
    mkdir -p "$SRC.tmp"
    tar -xzf "$tgz" -C "$SRC.tmp" --strip-components=1
    mv "$SRC.tmp" "$SRC"
  fi

  # 发布包自带的 .cargo/config.toml 只针对 windows-msvc / musl 目标，对我们没用；
  # 删掉免得以后有人改 CARGO_HOME 之外的配置时被它干扰。
  rm -f "$SRC/.cargo/config.toml"
  rmdir "$SRC/.cargo" 2>/dev/null || true

  # 源码树里没有 workspace，cargo 不会去上层找 workspace 根，天然安全。
  [[ -f "$SRC/Cargo.lock" ]] || die "源码包缺少 Cargo.lock: $SRC"
}

# ===========================================================================
# 4) 单个 arch 的交叉编译 + strip + 静态自检
# ===========================================================================
build_arch() {
  local arch="$1" triple out cc ar ua
  case "$arch" in
    arm64)  triple="aarch64-linux-android" ;;
    x86_64) triple="x86_64-linux-android" ;;
    *) die "不支持的 arch: $arch（只支持 arm64 / x86_64）" ;;
  esac

  out="$BUILDROOT/ripgrep-android-$arch"       # 交付目录：$out/rg
  cc="$LLVM/bin/${triple}${API}-clang"
  ar="$LLVM/bin/llvm-ar"
  ua="${triple//-/_}"                          # cc-rs 的下划线形式，见头部坑 4

  # --- 目标（Android）C 工具链：pcre2-sys 要用它编 vendored 的 PCRE2 ---
  export "CC_$ua=$cc"
  export "AR_$ua=$ar"
  # --- Rust 的链接器：用 NDK wrapper，它会带上 --target/sysroot/-pie ---
  local upper="${triple^^}"; upper="${upper//-/_}"
  export "CARGO_TARGET_${upper}_LINKER=$cc"
  # --- 强制 pcre2-sys 编 vendored 源码而不是链宿主 libpcre2-8，见头部坑 6 ---
  export PCRE2_SYS_STATIC=1

  # 发布包的 [profile.release] 带 debug = 1，这里保持上游默认，最后统一 strip。
  local -a cargo_args=(build --release --locked --target "$triple" --features pcre2 -j"$NPROC")

  log "[$arch] cargo ${cargo_args[*]}"
  log "[$arch]   CC_$ua = $cc"
  log "[$arch]   链接器 = $cc"
  (
    cd "$SRC"
    # shellcheck disable=SC2086
    "${CARGO_HOME}/bin/cargo" "${cargo_args[@]}"
  )

  local built="$SRC/target/$triple/release/rg"
  [[ -f "$built" ]] || die "[$arch] 没找到构建产物: $built"

  log "[$arch] 安装 + strip 到 $out/rg"
  rm -rf "$out"
  mkdir -p "$out"
  install -m 0755 "$built" "$out/rg"
  "$LLVM/bin/llvm-strip" --strip-all "$out/rg"

  # --- 自检 1：ELF 机器类型 ---
  local machine
  machine="$(readelf -h "$out/rg" | awk -F: '/Machine:/ {gsub(/^ +/,"",$2); print $2}')"
  case "$arch" in
    arm64)  [[ "$machine" = "AArch64" ]] || die "$out/rg 架构不对: $machine" ;;
    x86_64) [[ "$machine" = "Advanced Micro Devices X86-64" ]] || die "$out/rg 架构不对: $machine" ;;
  esac

  # --- 自检 2：必须有 INTERP 且是 /system/bin/linker64 ---
  local interp
  interp="$(readelf -lW "$out/rg" | awk '/Requesting program interpreter/ {gsub(/[\[\]]/,"",$NF); print $NF}')"
  [[ "$interp" = "/system/bin/linker64" ]] || die "$out/rg 的 INTERP 不对: '${interp}'（期望 /system/bin/linker64）"

  # --- 自检 3：NEEDED 只能是 bionic 系统库；不能有 RPATH/RUNPATH ---
  local needed bad
  needed="$(readelf -d "$out/rg" | awk -F'[][]' '/NEEDED/ {print $2}' | sort -u)"
  echo "    NEEDED: $(echo "$needed" | tr '\n' ' ')"
  bad="$(echo "$needed" | grep -vEx 'libc\.so|libdl\.so|libm\.so|liblog\.so' || true)"
  [[ -z "$bad" ]] || die "$out/rg 依赖了系统库之外的东西: $bad"
  if readelf -d "$out/rg" | grep -qE 'RPATH|RUNPATH'; then
    die "$out/rg 带 RPATH/RUNPATH（不能指向 app 私有路径）"
  fi

  # --- 自检 4：PCRE2 确实编进去了（功能验收在设备上做）---
  strings -a "$out/rg" | grep -q 'PCRE2 ' \
    || die "$out/rg 里没有 PCRE2 痕迹，--features pcre2 可能没生效"

  echo
  echo "==> 产物: $out/rg"
  ls -l "$out/rg"
  file "$out/rg" || true
  echo "    Machine=$machine  INTERP=$interp"
  echo
}

case "$ARCH" in
  all)          rust_ready || install_rust; write_cargo_config; fetch_source; build_arch arm64; build_arch x86_64 ;;
  arm64|x86_64) rust_ready || install_rust; write_cargo_config; fetch_source; build_arch "$ARCH" ;;
  *) die "不支持的 arch: $ARCH（只支持 arm64 / x86_64 / all）" ;;
esac

log "完成"
