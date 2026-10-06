#!/usr/bin/env python3
"""为 Android 适配 DSH 里所有 `fs.link()` 调用。

背景
----
Android 的 SELinux **全局禁止非系统进程创建硬链接** —— app 私有目录同样如此，
`link(2)` 直接返回 EACCES。实测：

    /data/local/tmp/...     link FAIL: EACCES
    app 私有目录 (run-as)    ln: cannot create hard link ...: Permission denied
    rename / open("wx")     正常

DSH 有 4 处调用 link，都靠「目标已存在 → EEXIST」做独占发布的乐观并发控制
（DSH 自己也为 Windows 写了 `publishNewWin32` 分支，说明这就是已知的平台差异）。

替换策略（按语义分两类）
------------------------
A. 发布临时文件（源文件发布后无需保留）→ `open(to, "wx")` + `rename(from, to)`
   - `open(..., "wx")` 即 O_CREAT|O_EXCL，语义与 link 的碰撞检测完全一致
   - rename 同文件系统内原子，且零拷贝
B. 发布不可变别名（源文件必须保留）→ `open(to, "wx")` + 复制内容
   - link 是零拷贝共享 inode，Android 上只能退化为复制
   - 附件是内容寻址的，调用方另有 sha256 完整性校验兜底

安全性：DSH 在进入这些路径前已持有 flock 排他锁
（`@deepseek-ai/node-addon-system/flock`，本仓库已为 Android 交叉编译），
link 只是二次保险，因此占位文件的极短可见窗口不构成竞态风险。

用法
----
    python3 scripts/patch-dsh-android.py <node_modules 路径>

幂等：重复执行会检测到已打补丁并跳过。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARKER = "androidExclusiveReplace"

SESSION_REL = "@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
ATTACH_REL = "@deepseek-ai/dsh-attachment-local/lib/index.js"
FS_REL = "@deepseek-ai/dsh-fs-local/lib/index.js"


def replace_once(path: Path, old: str, new: str, what: str) -> bool:
    text = path.read_text(encoding="utf-8")
    if new in text:
        print(f"  [skip] {what}")
        return False
    if old not in text:
        print(f"  [FAIL] {what}: 未找到预期代码（DSH 版本可能已变化）", file=sys.stderr)
        return False
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"  [ok]   {what}")
    return True


# ---------------------------------------------------------------- session
# 插入点：publishCurrentExclusive 之前
SESS_ANCHOR = "async function publishCurrentExclusive(staged, currentPath, internals) {"
SESS_HELPER = '''/**
* Android 版独占发布（见 scripts/patch-dsh-android.py）。
* 非 Android 直接用 link；Android 的 SELinux 禁止 link(2)，改用 O_EXCL 占位再
* rename 覆盖：占位创建成功即抢到发布权，已存在则 EEXIST，语义与 link 一致。
*/
async function androidExclusiveReplace(from, to) {
	if (process.platform !== "android") return link(from, to);
	const handle = await open(to, "wx");
	await handle.close();
	await rename(from, to);
}
''' + SESS_ANCHOR

SESS_CALL_OLD = "\t\tawait internals.fs.link(staged, currentPath);"
SESS_CALL_NEW = "\t\tawait androidExclusiveReplace(staged, currentPath);"

SESS_TMP_OLD = "\t\t\tawait link(tmp, finalPath);"
SESS_TMP_NEW = "\t\t\tawait androidExclusiveReplace(tmp, finalPath);"

# ------------------------------------------------------------- attachment
ATT_ANCHOR = "async function publishImmutableAlias(root, source, target, sha256) {"
ATT_HELPER = '''/**
* Android 版不可变别名发布（见 scripts/patch-dsh-android.py）。
* link 是零拷贝共享 inode，Android 禁止；退化为 O_EXCL 独占创建 + 复制内容。
* 附件按内容寻址，调用方另有 sha256 校验兜底。
*/
async function androidExclusiveReplace(from, to) {
	if (process.platform !== "android") return link(from, to);
	const handle = await open(to, "wx");
	try {
		await handle.writeFile(await readFile(from));
	} finally {
		await handle.close();
	}
}
''' + ATT_ANCHOR

ATT_ALIAS_OLD = "\t\t\tawait link(source, target);"
ATT_ALIAS_NEW = "\t\t\tawait androidExclusiveReplace(source, target);"

ATT_STAGED_OLD = "\t\t\tawait link(staged.path, target);"
ATT_STAGED_NEW = "\t\t\tawait androidExclusiveReplace(staged.path, target);"


def patch_session(root: Path) -> int:
    path = root / SESSION_REL
    if not path.is_file():
        print(f"  跳过（不存在）: {SESSION_REL}")
        return 0
    print(f"适配 {SESSION_REL}")
    n = 0
    n += replace_once(
        path,
        'import { link, lstat, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, truncate } from "node:fs/promises";',
        'import { link, lstat, mkdir, mkdtemp, open, readFile, readdir, realpath, rename, rm, stat, truncate } from "node:fs/promises";',
        "引入 rename",
    )
    n += replace_once(path, SESS_ANCHOR, SESS_HELPER, "插入 androidExclusiveReplace()")
    n += replace_once(path, SESS_CALL_OLD, SESS_CALL_NEW, "publishCurrentExclusive() 改用 helper")
    n += replace_once(path, SESS_TMP_OLD, SESS_TMP_NEW, "session header 发布改用 helper")
    return n


def patch_attachment(root: Path) -> int:
    path = root / ATTACH_REL
    if not path.is_file():
        print(f"  跳过（不存在）: {ATTACH_REL}")
        return 0
    print(f"适配 {ATTACH_REL}")
    n = 0
    n += replace_once(path, ATT_ANCHOR, ATT_HELPER, "插入 androidExclusiveReplace()")
    n += replace_once(path, ATT_ALIAS_OLD, ATT_ALIAS_NEW, "publishImmutableAlias() 改用 helper")
    n += replace_once(path, ATT_STAGED_OLD, ATT_STAGED_NEW, "publishStagedObject() 改用 helper")
    return n


# --------------------------------------------------------------- fs-local
# write 工具的原子写。`writeFileAtomic` 只在 `createIfAbsent` 模式下用 link()
# 做 hard-link no-replace —— 那就是 Android 上 EACCES 的来源。
# 覆盖已有文件的分支用的是 rename()，在 Android 上本来就是好的，所以不必动。
FS_ANCHOR = "async function writeFileAtomic(absolutePath, content, mode, signal, internals = {}, createIfAbsent) {"
FS_HELPER = '''/**
* Android 版 hard-link no-replace（见 scripts/patch-dsh-android.py）。
* Android 的 SELinux 禁止非系统进程 link(2)（返回 EACCES，app 私有目录同样如此），
* 改用 O_EXCL 独占创建占位再 rename 覆盖：目标已存在则抛 EEXIST，与 link 语义一致。
*/
async function androidLinkNoReplace(from, to) {
	const handle = await open(to, "wx");
	await handle.close();
	await rename(from, to);
}
''' + FS_ANCHOR

FS_CALL_OLD = "const linkFile = internals.linkFile ?? link;"
FS_CALL_NEW = 'const linkFile = internals.linkFile ?? (platform === "android" ? androidLinkNoReplace : link);'


def patch_fs_local(root: Path) -> int:
    path = root / FS_REL
    if not path.is_file():
        print(f"  跳过（不存在）: {FS_REL}")
        return 0
    print(f"适配 {FS_REL}")
    n = 0
    n += replace_once(path, FS_ANCHOR, FS_HELPER, "插入 androidLinkNoReplace()")
    n += replace_once(path, FS_CALL_OLD, FS_CALL_NEW, "writeFileAtomic() 在 Android 上改用 helper")
    return n


# ------------------------------------------------------------- bash 路径
# `tool-bash` 的执行器把 shell 程序硬编码成 `"bash"`，靠 PATH 解析。Android 只有
# `/system/bin/sh`(mksh)，而且 mksh 不支持 pipefail / 数组 / `${v^^}` 等，agent
# 写的命令会频繁失败。本仓库用 NDK 交叉编译了一个静态 bash，但它只能从
# `nativeLibraryDir` 执行，所以是个固定绝对路径（`<nativeLibraryDir>/libbash.so`）。
#
# 替换成 `process.env.DSH_BASH_PATH ?? "bash"`：没有该变量时行为与上游完全一致。
#
# 用正则而不是逐字锚点，是因为这里踩过一次：0.1.5 → 0.2.0 时上游把
# `LocalBashExecutor.run()` 改名成了 `execute()`、`runArgv` → `executeArgv`，
# 逐字锚点直接失效。而真正稳定的只有 `["bash", "-c", …]` 这个 argv 形状本身。
BASH_ARGV_RE = re.compile(r'"bash"(\s*,\s*)"-c"')

BASH_FILES = (
    "@deepseek-ai/dsh-bash-local/lib/index.js",
    "@deepseek-ai/dsh-bash-sandbox/lib/index.js",
)


def patch_bash_path(root: Path) -> int:
    n = 0
    for rel in BASH_FILES:
        path = root / rel
        if not path.is_file():
            print(f"  跳过（不存在）: {rel}")
            continue
        text = path.read_text(encoding="utf-8")
        if "DSH_BASH_PATH" in text:
            print(f"  [skip] {rel} 的 bash 程序")
            continue
        patched, hits = BASH_ARGV_RE.subn(
            'process.env.DSH_BASH_PATH ?? "bash"\\1"-c"', text
        )
        if hits == 0:
            print(f"  [FAIL] {rel}: 没找到 [\"bash\", \"-c\", …] 形状（DSH 版本可能已变化）", file=sys.stderr)
            continue
        path.write_text(patched, encoding="utf-8")
        print(f"  [ok]   {rel} 的 bash 程序（{hits} 处）")
        n += hits
    return n


# ------------------------------------------------------- 目录选择器起始位置
# web profile 用的是 `dsh-host-directory-picker-auto`，Android 上
# `process.platform === 'android'` 会解析成 `browse`（原生选择器只在
# darwin/win32/linux 上可用），也就是网页里的服务端目录浏览器。
#
# 那个浏览器以 `os.homedir()` 作为初始目录，也是界面上「主目录」按钮的目标。
# 而 app 的 HOME 是 `/data/user/0/<pkg>/files/home` —— 要选
# `/storage/emulated/0/Documents/DSH` 得在上面点很多层。
#
# 这里让它优先读 DSH_PICKER_HOME：没设时行为与上游完全一致。
PICKER_REL = "@deepseek-ai/dsh-host-directory-picker-browse/lib/index.js"
PICKER_OLD = """	async list(path, signal) {
		const home = homedir();"""
PICKER_NEW = """	async list(path, signal) {
		const home = process.env.DSH_PICKER_HOME ?? homedir();"""


# ------------------------------------------------------------- pnpm 入口
# DSH 装插件（"添加插件" 界面、以及 `dsh plugin add`）都是把活儿交给 pnpm。
#
# Android 上有两个问题：
#   1. app 私有目录**禁止 exec**（W^X）—— 实测在 app 域里执行 `files/bin/xxx.sh`
#      会得到 `/system/bin/sh: bad interpreter: Permission denied`（exit 126）。
#      注意：用 `adb shell run-as` 测会"通过"，因为那跑在 shell 域、规则不同，
#      别被误导。所以 pnpm 的 bin 脚本没法直接当命令用。
#   2. pnpm 12 起已经是**原生二进制**（`bin/pnpm.mjs` 只是个去下载二进制的壳），
#      Android 没有对应产物；能用的只有纯 JS 的 pnpm 10.x（`bin/pnpm.cjs`）。
#
# 注意变量名是 ANDROIDDSH_ 而不是 DSH_：DSH 起子进程时会走 scrubbedParentEnv()，
# 把所有 DSH_* 前缀的变量剥掉；而这个变量要被更下层的子进程（libpnpm.so 启动器）
# 读到，所以不能带 DSH_ 前缀。
#
# 所以要把 `pnpm ...` 换成 `node <pnpm.cjs> ...`。**必须在共用的 execa 调用点上打**：
# 服务端（PluginManager 类）和 CLI（`dsh plugin`）走的是两份不同的实现
# （lib/index.js 与 lib/types/operations.js），各自有 5 处 execa；只改服务端那侧的话
# CLI 会报 "dsh: pnpm was not found"（exit 127）。这两份里的调用形状都是
#
#     execa(options.command ?? "pnpm", [ ...options.args ?? [], ...更多参数 ], { ... })
#
# 所以这里把 `execa(cmd, ARGS, ` 改写成 `execa(...androidPnpmLaunchArgs(options, ARGS), `，
# 由 helper 决定用 pnpm 还是 node+入口。ANDROIDDSH_PNPM_ENTRY 未设置时行为与上游完全一致。
PNPM_FILES = (
    "@deepseek-ai/dsh-plugin-manager/lib/index.js",
    "@deepseek-ai/dsh-plugin-manager/lib/types/operations.js",
)

PNPM_HELPER = """
/**
* AndroidDSH：ANDROIDDSH_PNPM_ENTRY 存在时改用 `node <pnpm.cjs>` 调用 pnpm。
* Android 的 app 私有目录禁止 exec，pnpm 的 bin 脚本跑不起来；见
* scripts/patch-dsh-android.py 的 patch_pnpm_entry()。未设置时行为与上游一致。
* @param options - 调用方的 { command?, args? }
* @param args - 调用点原本要传给 pnpm 的参数
* @returns execa 的 [command, args]
*/
function androidPnpmLaunchArgs(options, args) {
\tconst entry = process.env.ANDROIDDSH_PNPM_ENTRY;
\tif (entry === void 0 || entry === "") return [options.command ?? "pnpm", args];
\treturn [process.execPath, [entry, ...args]];
}
"""

# 旧的（只覆盖服务端那侧）写法，遇到就回滚，避免与新版重复
LEGACY_OLD = "...this.profile.packageManager ?? { command: this.pnpmCommand },"
LEGACY_NEW = "...androidPnpmLaunch(this.profile.packageManager, this.pnpmCommand),"

EXECA_HEAD = re.compile(r'execa\(options\.command \?\? [\'"]pnpm[\'"], \[')
HELPER_MARK = "function androidPnpmLaunchArgs("


def _match_bracket(text: str, open_index: int) -> int:
    """返回与 text[open_index]（必须是 '['）配对的 ']' 下标；跳过字符串字面量。"""
    depth = 0
    i = open_index
    quote = None
    while i < len(text):
        ch = text[i]
        if quote is not None:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = None
        elif ch in "\"'`":
            quote = ch
        elif ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError("args array is not balanced")


def _rewrite_execa(text: str):
    """把所有 execa(options.command ?? "pnpm", ARGS, …) 改写成展开 helper 的形式。"""
    out = []
    pos = 0
    hits = 0
    while True:
        m = EXECA_HEAD.search(text, pos)
        if m is None:
            out.append(text[pos:])
            break
        open_index = m.end() - 1
        close_index = _match_bracket(text, open_index)
        args = text[open_index + 1:close_index]
        out.append(text[pos:m.start()])
        out.append("execa(...androidPnpmLaunchArgs(options, [" + args + "])")
        pos = close_index + 1
        hits += 1
    return "".join(out), hits


def patch_pnpm_entry(root: Path) -> int:
    n = 0
    for rel in PNPM_FILES:
        path = root / rel
        if not path.is_file():
            print(f"  跳过（不存在）: {rel}")
            continue
        print(f"适配 {rel}")
        text = path.read_text(encoding="utf-8")

        # 回滚上一版只覆盖服务端的写法
        if LEGACY_NEW in text:
            text = text.replace(LEGACY_NEW, LEGACY_OLD)
            print("  [undo] 回滚旧的 packageManager 展开式补丁")

        if HELPER_MARK not in text:
            anchor = 'import { execa } from "execa";'
            if anchor not in text:
                anchor = "import { execa } from 'execa';"
            if anchor not in text:
                print("  [FAIL] 找不到 execa 的 import 行", file=sys.stderr)
                path.write_text(text, encoding="utf-8")
                continue
            text = text.replace(anchor, anchor + "\n" + PNPM_HELPER, 1)
            print("  [ok]   插入 androidPnpmLaunchArgs()")
            n += 1
        else:
            print("  [skip] androidPnpmLaunchArgs() 已存在")

        text, hits = _rewrite_execa(text)
        if hits == 0:
            if "androidPnpmLaunchArgs(options" in text:
                print("  [skip] pnpm 命令改写已生效")
            else:
                print('  [FAIL] 没找到 execa(options.command ?? "pnpm", …) 调用点', file=sys.stderr)
        else:
            print(f"  [ok]   pnpm 命令改用 ANDROIDDSH_PNPM_ENTRY 覆盖（{hits} 处）")
            n += hits
        path.write_text(text, encoding="utf-8")
    return n


# --------------------------------------------------- pnpm 转发 npm 的那部分
# pnpm 10.34 把一批子命令**转发给真正的 npm**（见 dist 里的 passThruToNpm：
# view / info / search / whoami / ping / version …），走的是 runNpm() → cross-spawn
# `npm`。Android 上没有 npm，于是这些命令静默 exit 1，DSH 界面上就表现成：
#   「无法获取插件信息: pnpm view exited with 1」
#
# 修法：随包发一份 npm（纯 JS，约 19MB），把 runNpm 的 `npm` 换成
# `node <npm-cli.js>`。ANDROIDDSH_NPM_ENTRY 未设置时行为与上游完全一致。
#
# 注意变量名是 ANDROIDDSH_ 而不是 DSH_：DSH 起子进程时会走 scrubbedParentEnv()，
# 把所有 DSH_* 前缀的变量剥掉，而这个变量有时候要被更下层的子进程读到。
NPM_PASSTHROUGH_REL = "pnpm/dist/pnpm.cjs"

NPM_RUN_OLD = """      const npm = npmPath ?? "npm";
      return runScriptSync(npm, args, {"""

NPM_RUN_NEW = """      const npmEntry = process.env.ANDROIDDSH_NPM_ENTRY;
      const npm = npmEntry !== void 0 && npmEntry !== "" ? process.execPath : npmPath ?? "npm";
      return runScriptSync(npm, npmEntry !== void 0 && npmEntry !== "" ? [npmEntry, ...args] : args, {"""


def patch_npm_passthrough(root: Path) -> int:
    path = root / NPM_PASSTHROUGH_REL
    if not path.is_file():
        print(f"  跳过（不存在）: {NPM_PASSTHROUGH_REL}")
        return 0
    print(f"适配 {NPM_PASSTHROUGH_REL}（pnpm → npm 转发）")
    text = path.read_text(encoding="utf-8")
    if "ANDROIDDSH_NPM_ENTRY" in text:
        print("  [skip] npm 转发改写已生效")
        return 0
    if text.count(NPM_RUN_OLD) != 1:
        print("  [FAIL] 没找到唯一的 runNpm 片段（pnpm 版本可能已变化）", file=sys.stderr)
        return 0
    path.write_text(text.replace(NPM_RUN_OLD, NPM_RUN_NEW, 1), encoding="utf-8")
    print("  [ok]   runNpm 改用 ANDROIDDSH_NPM_ENTRY 覆盖")
    return 1


# --------------------------------------------------------- 终端进程检查器
# DSH 的终端面板（右侧栏 → 新建终端）会走 `dsh-subprocess-local` 的
# `createProcessInspector()` 选平台实现：
#
#     if (platform === "linux") return new LinuxProcessInspector(arch, internals);
#     if (platform === "darwin") ...
#     if (platform === "win32") ...
#     throw new Error(`subprocess-local: terminal inspection is unsupported on platform ${platform}`);
#
# Android 不等于 "linux"，于是直接抛错，终端面板显示：
#   `终端错误: subprocess-local: terminal inspection is unsupported on platform android`
#
# `LinuxProcessInspector` 干的事就是读 /proc/<pid>/stat、/proc/<pid>/task 等，
# Android 全都有（且读自己子进程不受 SELinux 限制），arch 表里也已经有
# `arm64` / `x64` 两个键，所以让它照 linux 用就行。
#
# 文件名带哈希（runner-launch-<hash>.js），所以用 glob 找，不能写死。
TERMINAL_INSPECTOR_OLD = 'if (platform === "linux") return new LinuxProcessInspector(arch, internals);'
TERMINAL_INSPECTOR_NEW = 'if (platform === "linux" || platform === "android") return new LinuxProcessInspector(arch, internals);'


def patch_terminal_inspector(root: Path) -> int:
    pkg = root / "@deepseek-ai/dsh-subprocess-local/lib"
    if not pkg.is_dir():
        print(f"  跳过（不存在）: {pkg}")
        return 0
    print("适配 @deepseek-ai/dsh-subprocess-local（终端进程检查器）")
    n = 0
    for path in sorted(pkg.glob("runner-launch-*.js")):
        if replace_once(path, TERMINAL_INSPECTOR_OLD, TERMINAL_INSPECTOR_NEW,
                        f"{path.name} 放行 android"):
            n += 1
    return n


# ------------------------------------------------------------- ripgrep 路径
# `glob` / `grep` 两个工具的搜索后端是 ripgrep（`@deepseek-ai/dsh-tool-fs-search`）。
# 它按这个顺序找二进制：
#   1. `${process.execPath}-rg` 这个 sidecar —— **只在 `"pkg" in process` 时**才用
#      （单文件运行时专用），而且 AGP 只把 jniLibs 里的 `*.so` 打进 `lib/<abi>/`，
#      名字不以 .so 结尾的文件会被静默丢掉（已实测），所以这条路在 Android 上走不通；
#   2. `@vscode/ripgrep` 平台包 —— 只有 linux-x64 等桌面包，Android 上没有。
# 结果就是 `glob could not start its search command (ripgrep launch failed)`。
#
# 这里加一个最高优先级的 DSH_RG_PATH：没设时行为与上游完全一致。
RG_REL = "@deepseek-ai/dsh-tool-fs-search/lib/index.js"

RG_OLD = """	rgPathPromise ??= Promise.resolve().then(async () => {
		const executable = parse(process.execPath);"""

RG_NEW = """	rgPathPromise ??= Promise.resolve().then(async () => {
		if (process.env.DSH_RG_PATH) return process.env.DSH_RG_PATH;
		const executable = parse(process.execPath);"""


def patch_rg_path(root: Path) -> int:
    path = root / RG_REL
    if not path.is_file():
        print(f"  跳过（不存在）: {RG_REL}")
        return 0
    print(f"适配 {RG_REL}")
    return int(replace_once(path, RG_OLD, RG_NEW, "ripgrep 程序改用 DSH_RG_PATH 覆盖"))


def patch_picker_home(root: Path) -> int:
    path = root / PICKER_REL
    if not path.is_file():
        print(f"  跳过（不存在）: {PICKER_REL}")
        return 0
    print(f"适配 {PICKER_REL}")
    return int(replace_once(path, PICKER_OLD, PICKER_NEW, "目录选择器起始目录改用 DSH_PICKER_HOME"))


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = Path(sys.argv[1])
    if not root.is_dir():
        print(f"不是目录: {root}", file=sys.stderr)
        return 1
    if (root / SESSION_REL).is_file() and MARKER in (root / SESSION_REL).read_text(encoding="utf-8"):
        print("  [skip] session 持久化已适配 Android")

    total = (
        patch_session(root)
        + patch_attachment(root)
        + patch_fs_local(root)
        + patch_bash_path(root)
        + patch_picker_home(root)
        + patch_rg_path(root)
        + patch_pnpm_entry(root)
        + patch_terminal_inspector(root)
        + patch_npm_passthrough(root)
    )
    print(f"\n完成，共 {total} 处改动" + ("" if total else "（全部已就绪）"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
