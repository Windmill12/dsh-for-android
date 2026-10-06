package com.androiddsh

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import org.apache.commons.compress.archivers.tar.TarArchiveEntry
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.util.zip.GZIPInputStream

/**
 * 内嵌的 Node.js + DSH 运行时。
 *
 * 运行时由三部分组成，原因是 Android 对"执行自带二进制"有特殊要求：
 *
 *  1. **Node 二进制** —— 以 `libnode.so` 的名义放进 `jniLibs`，运行时位于
 *     `applicationInfo.nativeLibraryDir`。这个目录是只读的，所以允许 `exec`；
 *     而 app 自己的可写数据目录从 Android 10 起被 W^X 策略禁止执行。
 *
 *  2. **bash** —— 同一个约束：以 `libbash.so` 的名义放进 `jniLibs`。
 *     Android 只有 `/system/bin/sh`(mksh)，没有 bash；而 DSH 的 `tool-bash`
 *     直接 `spawn("bash", ["-c", cmd])`，所以必须自带一个真 bash。
 *
 *  3. **DSH 的 JS 依赖树**（约 300MB / 240 个包）—— 以 `assets/dsh-runtime.pkg`
 *     分发，首次启动解压到 `filesDir/rt`。
 *
 * 这些 JS 依赖里含 Android 原生模块（koffi / node-pty / flock），由
 * `scripts/prepare-dsh-android.sh` 交叉编译后打进运行时包，不能直接用
 * npm 安装的版本（那些是 glibc/x86 的，bionic 上加载不了）。
 */
class DshRuntime(private val context: Context) {

    companion object {
        const val ASSET = "dsh-runtime.pkg"

        /** CPython 运行时（可选；由 scripts/prepare-app-assets.sh 生成） */
        const val PYTHON_ASSET = "python-runtime.pkg"

        /** 运行时内容变更时递增，以触发已安装设备重新解压 */
        const val RUNTIME_VERSION = 11

        private const val STAMP = ".runtime-version"

        /** 首选端口。固定端口让 WebView 的 origin 稳定，从而 localStorage 里的界面设置能保留。 */
        const val PREFERRED_PORT = 7300

        /** 候选端口数量（含首选），全部被占用时才退回由内核分配。 */
        private const val PORT_CANDIDATES = 10

        /** Android 自带的 POSIX shell；没有自带 bash 时作为降级。 */
        const val SYSTEM_SH = "/system/bin/sh"
    }

    private val nativeDir: File get() = File(context.applicationInfo.nativeLibraryDir)

    /** 可执行的 Node 二进制 */
    val nodeBinary: File get() = File(nativeDir, "libnode.so")

    /** 自带的静态 bash（以 jniLib 名义分发，才能落到可执行目录） */
    val bashBinary: File get() = File(nativeDir, "libbash.so")

    /** 自带的 ripgrep —— `glob` / `grep` 两个工具的后端 */
    val rgBinary: File get() = File(nativeDir, "libripgrep.so")

    /** 自带的 CPython 解释器（可执行文件，标准库在 [pythonHome]） */
    val pythonBinary: File get() = File(nativeDir, "libpython3.so")

    /**
     * jsrun 启动器（见 native/jsrun.c）。
     *
     * Android 的 app 私有目录禁止 exec，所以「node + JS 入口」这种命令没法制成包装
     * 脚本。启动器装成 libpnpm.so / libnpm.so，由 [ensureExecShims] 在 files/bin 里
     * 做同名符号链接 —— 符号链接指向 nativeLibraryDir，因此可执行。有些工具
     * （比如 dsh-market）就是按 PATH 找 `pnpm` 可执行文件的。
     */
    val pnpmBinary: File get() = File(nativeDir, "libpnpm.so")
    val pnpxBinary: File get() = File(nativeDir, "libpnpx.so")
    val npmBinary: File get() = File(nativeDir, "libnpm.so")

    /** CPython 的 PYTHONHOME：解压后的 `lib/python3.x/` 就在下面 */
    val pythonHome: File get() = File(context.filesDir, "python")

    /** 解压后的运行时根目录（其下有 node_modules/） */
    val runtimeDir: File get() = File(context.filesDir, "rt")

    /** DSH 的 CLI 入口 */
    val dshEntry: File get() = File(runtimeDir, "node_modules/@deepseek-ai/dsh/lib/bin.js")

    /** 工作目录，作为 dsh 的 `$HOME`：profile、session、配置都落在这里 */
    val homeDir: File get() = File(context.filesDir, "home")

    /**
     * agent 的工作目录（DSH 的 `process.cwd()`，也就是新会话默认的 `workspaceRoot`）。
     *
     * 首选 `/sdcard/Documents/DSH`：用文件管理器、USB、云盘同步都能直接看到 agent
     * 产出的文件。这条路**必须**走 `MANAGE_EXTERNAL_STORAGE`（"所有文件访问"）：
     * SAF / MediaStore 给的是 Content URI，对内嵌的 node / bash 子进程毫无意义，
     * 只有真实文件路径才可用。
     *
     * 拿不到权限时退回 app 私有外部目录 —— 不需要任何权限，只是藏得比较深
     * （`Android/data/com.androiddsh/files/workspace`）。
     */
    fun workspaceDir(): File {
        val preferred = if (hasAllFilesAccess()) publicWorkspaceDir else privateWorkspaceDir
        if (preferred.isDirectory || preferred.mkdirs()) return preferred
        // 公开目录都建不出来（例如 Documents 被别的 app 占成只读）时兜底
        privateWorkspaceDir.mkdirs()
        return privateWorkspaceDir
    }

    /** 用户能在文件管理器里直接看到的公开目录。 */
    val publicWorkspaceDir: File
        get() = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS),
            "DSH",
        )

    /** 兜底：app 专属外部目录，零权限，但路径较深。 */
    val privateWorkspaceDir: File
        get() = File(context.getExternalFilesDir(null) ?: context.filesDir, "workspace")

    /**
     * 是否拿到了"所有文件访问"。
     *
     * - API 30+ 看 `Environment.isExternalStorageManager()`（需要在系统设置里手动开）
     * - API 29 依赖 `requestLegacyExternalStorage` + WRITE_EXTERNAL_STORAGE
     * - API 26–28 就是普通的 WRITE_EXTERNAL_STORAGE 运行时权限
     */
    fun hasAllFilesAccess(): Boolean = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> Environment.isExternalStorageManager()
        else -> context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
    }

    /** 子进程日志，出错时给用户看的 */
    val logFile: File get() = File(context.filesDir, "dsh-server.log")

    /**
     * 给 agent 的 shell 用的可执行入口目录。
     *
     * Node 和 bash 都只能从 `nativeLibraryDir` 执行（见类注释），而那个目录里的
     * 文件名是 `libnode.so` / `libbash.so` —— agent 敲 `node -v` 是找不到的。
     *
     * 办法是在 app 私有目录里放**符号链接**：SELinux 允许 app 建 symlink，
     * 而 `execve` 跟随链接后落到 nativeLibraryDir 里的真实文件上，标签是允许
     * 执行的（实测真机 `files/bin/node -v` 能跑起来）。
     *
     * 注意：每次安装 APK，nativeLibraryDir 的路径都会变（`/data/app/~~<随机>`），
     * 所以链接必须**每次启动都重建**，不能只建一次。
     */
    val binDir: File get() = File(context.filesDir, "bin")

    fun ensureExecShims() {
        binDir.mkdirs()
        symlink("node", nodeBinary)
        symlink("bash", bashBinary)
        symlink("rg", rgBinary)
        symlink("python3", pythonBinary)
        symlink("python", pythonBinary)
        symlink("python3.13", pythonBinary)
        // 真正可执行的 pnpm/npm（不只是 bash 函数），否则按 PATH 找 pnpm 的工具会失败
        if (pnpmBinary.isFile) symlink("pnpm", pnpmBinary)
        if (pnpxBinary.isFile) symlink("pnpx", pnpxBinary)
        if (npmBinary.isFile) symlink("npm", npmBinary)
        writeTerminalRc()
    }

    /**
     * 给 DSH 的终端面板准备 rc 文件。
     *
     * 终端是 `dsh-api-terminal-controller` 起的交互式 shell，默认取
     * `process.env.SHELL || userInfo().shell || "/bin/sh"`（见
     * dsh-subprocess-local 的 terminalEnvironment）。Android 上 `userInfo()` 没有
     * shell 字段，`/bin/sh` 是 mksh —— 既不好用也不会读我们的便捷命令。
     * 所以 [childEnvironment] 把 `SHELL` 指到自带的 bash，这里再写 rc：
     *   - `~/.bashrc` 给 bash（交互式）
     *   - `~/.dshrc`  给 mksh/toybox sh（交互式读 `$ENV`，childEnvironment 里设了）
     * 两份内容一样，且都只用 POSIX 语法（函数定义两边都支持）。
     *
     * 为什么用 shell 函数而不是 `files/bin/pnpm` 包装脚本：**Android 的 app 私有
     * 目录禁止 exec**。实测在 app 域里执行 `files/bin/xxx.sh` 会得到
     * `/system/bin/sh: bad interpreter: Permission denied`（exit 126）；只有指向
     * nativeLibraryDir 的符号链接能执行。所以只能把命令指到 `node <js 入口>`。
     *
     * 路径含 nativeLibraryDir，每次安装 APK 都会变，所以每次启动重写。
     */
    private fun writeTerminalRc() {
        val node = nodeBinary.absolutePath
        val pnpmEntry = File(runtimeDir, "node_modules/pnpm/bin/pnpm.cjs")
        val rc = buildString {
            appendLine("# 由 AndroidDSH 自动生成，每次启动重写，请勿手改。")
            appendLine("# app 私有目录禁止 exec，所以用函数把命令指到 node + JS 入口。")
            appendLine("export PS1='dsh:\\w\\$ '")
            // 这两个必须在这里再导出一次：DSH 起子进程时会走 scrubbedParentEnv()，
            // 它会把所有 DSH_* 变量剥掉（服务端进程里是有的，终端里的 shell 就没有了），
            // 于是终端里跑 `dsh plugin ...` 会拿不到 pnpm 入口。rc 是 bash 自己读的，
            // 在这里补上正好。
            val bashPath = File(binDir, "bash").absolutePath
            appendLine("export SHELL='$bashPath'")
            if (pnpmEntry.isFile) appendLine("export ANDROIDDSH_PNPM_ENTRY='${pnpmEntry.absolutePath}'")
            val npmEntry = File(runtimeDir, "node_modules/npm/bin/npm-cli.js")
            if (npmEntry.isFile) appendLine("export ANDROIDDSH_NPM_ENTRY='${npmEntry.absolutePath}'")
            // pnpm/npm 现在是 files/bin 里的真实可执行文件（jsrun 启动器），
            // 不再需要 shell 函数包装。
            if (dshEntry.isFile) {
                appendLine("dsh() { '$node' '$dshEntry' \"\$@\"; }")
            }
            appendLine("alias ll='ls -al'")
        }
        homeDir.mkdirs()
        for (name in listOf(".bashrc", ".dshrc")) {
            runCatching { File(homeDir, name).writeText(rc) }
        }
    }

    private fun symlink(name: String, target: File) {
        val link = File(binDir, name)
        if (!target.isFile) {
            link.delete()
            return
        }
        runCatching {
            val isLink = Files.isSymbolicLink(link.toPath())
            if (isLink && link.canonicalPath == target.canonicalPath) return
            link.delete()
            Files.createSymbolicLink(link.toPath(), target.toPath())
        }
    }

    fun isReady(): Boolean {
        val stamp = File(runtimeDir, STAMP)
        return stamp.isFile &&
            stamp.readText().trim() == RUNTIME_VERSION.toString() &&
            dshEntry.isFile
    }

    /** 首次启动时解压运行时；幂等，已解压则直接返回 */
    fun ensureExtracted(onProgress: (String) -> Unit) {
        homeDir.mkdirs()
        workspaceDir().mkdirs()
        if (isReady()) {
            onProgress("运行时已就绪")
            return
        }
        runtimeDir.deleteRecursively()
        runtimeDir.mkdirs()

        onProgress("正在解压 DSH 运行时（首次启动约需 1–2 分钟）…")
        val startedAt = System.currentTimeMillis()
        var files = 0
        context.assets.open(ASSET).use { raw ->
            GZIPInputStream(BufferedInputStream(raw, 1 shl 16)).use { gz ->
                TarArchiveInputStream(gz).use { tar -> files = extract(tar, runtimeDir, null) }
            }
        }

        files += extractPython(onProgress)

        File(runtimeDir, STAMP).writeText(RUNTIME_VERSION.toString())
        onProgress("解压完成：$files 个文件，用时 ${(System.currentTimeMillis() - startedAt) / 1000} 秒")
    }

    /**
     * 解压 CPython 运行时（可选）。
     *
     * 归档里按 ABI 分目录（`arm64-v8a/…`、`x86_64/…`），只解当前设备那一份 ——
     * 纯 Python 标准库两份内容完全一样，但 gzip 跨文件不会去重，所以拆开能让
     * APK 少十几 MB。
     */
    private fun extractPython(onProgress: (String) -> Unit): Int {
        if (!hasAsset(PYTHON_ASSET)) {
            onProgress("（未打包 Python 运行时，跳过）")
            return 0
        }
        pythonHome.deleteRecursively()
        pythonHome.mkdirs()
        val abi = Build.SUPPORTED_ABIS.firstOrNull { it == "arm64-v8a" || it == "x86_64" }
            ?: "arm64-v8a"
        var files = 0
        context.assets.open(PYTHON_ASSET).use { raw ->
            GZIPInputStream(BufferedInputStream(raw, 1 shl 16)).use { gz ->
                TarArchiveInputStream(gz).use { tar -> files = extract(tar, pythonHome, "$abi/") }
            }
        }
        return files
    }

    private fun hasAsset(name: String): Boolean =
        runCatching { context.assets.list("")?.contains(name) == true }.getOrDefault(false)

    /**
     * 把归档解到 [root]；[onlyUnder] 非空时只处理该前缀下的条目（并去掉前缀）。
     * 返回写出的文件数。
     */
    private fun extract(tar: TarArchiveInputStream, root: File, onlyUnder: String?): Int {
        val rootPath = root.canonicalPath + File.separator
        var count = 0
        var entry: TarArchiveEntry? = tar.nextEntry
        while (entry != null) {
            val name = entry.name.removePrefix("./")
            if (onlyUnder != null && !name.startsWith(onlyUnder)) {
                entry = tar.nextEntry
                continue
            }
            val relative = if (onlyUnder != null) name.removePrefix(onlyUnder) else name
            if (relative.isEmpty()) {
                entry = tar.nextEntry
                continue
            }
            val target = File(root, relative)
            // 防目录穿越
            require(target.canonicalPath.startsWith(rootPath)) {
                "归档条目越界：${entry.name}"
            }
            when {
                entry.isDirectory -> target.mkdirs()

                entry.isSymbolicLink -> {
                    // node_modules/.bin 里全是符号链接。Android 的 SELinux 通常不允许
                    // app 创建 symlink，但 dsh 不依赖 .bin（它用 package.json 的 bin 字段
                    // 解析入口），所以失败就跳过，不视为错误。
                    target.parentFile?.mkdirs()
                    runCatching { Files.createSymbolicLink(target.toPath(), File(entry.linkName).toPath()) }
                }

                else -> {
                    target.parentFile?.mkdirs()
                    FileOutputStream(target).use { out -> tar.copyTo(out, 1 shl 16) }
                    // 保留可执行位（原生模块 .node 用得到）
                    if (entry.mode and 0b001_000_000 != 0) target.setExecutable(true, false)
                    count++
                }
            }
            entry = tar.nextEntry
        }
        return count
    }

    /**
     * 子进程环境变量。
     *
     * - `LD_LIBRARY_PATH` 指向 nativeLibraryDir 是必需的：Node 二进制依赖
     *   `libc++_shared.so`，而它和 libnode.so 放在同一个目录里。
     * - `PATH` 里放了 [binDir]，这样 agent 在 bash 里敲 `node` / `bash` 能找到。
     * - `DSH_PERMISSION_MODE=danger-full-access` 是 Android 上唯一可用的档位：
     *   另外两档要求 bubblewrap / Landlock，Android 内核上都没有。DSH 自己用
     *   这个变量同时决定 sandbox 模式与 approval 策略（见 dsh-base 的
     *   `sandbox-policy` / `approval` 两行），所以设它一个就够了。
     * - `DSH_BASH_PATH` 由 `scripts/patch-dsh-android.py` 打进去的那两行读取；
     *   它把 `tool-bash` 里硬编码的 `"bash"` 换成绝对路径，不依赖 PATH 查找。
     * - `DSH_PICKER_HOME` 是同一脚本给目录选择器（Android 上解析成网页版目录
     *   浏览器）设的起始目录，也是界面上「主目录」按钮的目标。不设的话它从
     *   `$HOME` 开始，用户要选 `/sdcard/Documents/DSH` 得点很多层。
     */
    fun childEnvironment(apiKey: String, workspace: File): Map<String, String> = buildMap {
        put("LD_LIBRARY_PATH", nativeDir.absolutePath)
        put("HOME", homeDir.absolutePath)
        put("TMPDIR", context.cacheDir.absolutePath)
        put(
            "PATH",
            listOf(binDir.absolutePath, nativeDir.absolutePath, "/system/bin", "/system/xbin")
                .joinToString(":"),
        )
        put("LANG", "en_US.UTF-8")
        put("DSH_PERMISSION_MODE", "danger-full-access")
        put("DSH_BASH_PATH", if (bashBinary.isFile) bashBinary.absolutePath else SYSTEM_SH)
        put("DSH_PICKER_HOME", workspace.absolutePath)
        // 终端面板的默认 shell：不设的话是 /bin/sh(mksh)，既不读 ~/.bashrc，
        // 语法也比 bash 弱得多（见 writeTerminalRc）。
        put("SHELL", if (File(binDir, "bash").exists()) File(binDir, "bash").absolutePath else SYSTEM_SH)
        // mksh / toybox sh 的交互式 rc 由 $ENV 指定
        put("ENV", File(homeDir, ".dshrc").absolutePath)
        // 装插件走 pnpm。Android 上 pnpm 的 bin 脚本没法直接执行（见 writeTerminalRc），
        // 所以让 dsh-plugin-manager 用 `node <pnpm.cjs>` 代替 `pnpm`
        // （patch-dsh-android.py 的 patch_pnpm_entry）。
        // 变量名用 ANDROIDDSH_ 而不是 DSH_：DSH 起子进程时会走 scrubbedParentEnv()，
        // 把 DSH_* 前缀全剥掉，而这个变量要能被更下层的子进程（jsrun 启动器、
        // dsh-market 起的 pnpm）读到。
        val pnpmEntry = File(runtimeDir, "node_modules/pnpm/bin/pnpm.cjs")
        if (pnpmEntry.isFile) put("ANDROIDDSH_PNPM_ENTRY", pnpmEntry.absolutePath)
        // pnpm 10.34 把 view/search/whoami 等子命令转发给真正的 npm，这里给它指路
        val npmEntry = File(runtimeDir, "node_modules/npm/bin/npm-cli.js")
        if (npmEntry.isFile) put("ANDROIDDSH_NPM_ENTRY", npmEntry.absolutePath)
        // 只在真的打进去了才设：设成不存在的路径会直接让 glob/grep 报错
        if (rgBinary.isFile) put("DSH_RG_PATH", rgBinary.absolutePath)
        if (File(pythonHome, "lib").isDirectory) put("PYTHONHOME", pythonHome.absolutePath)
        if (apiKey.isNotBlank()) put("DEEPSEEK_API_KEY", apiKey)
    }

    /** 在候选端口里挑一个空闲的；全被占用时返回 0，让内核分配。 */
    fun pickPort(): Int {
        for (port in PREFERRED_PORT until PREFERRED_PORT + PORT_CANDIDATES) {
            try {
                java.net.ServerSocket(port).use { return port }
            } catch (_: Exception) {
                // 端口占用，试下一个
            }
        }
        return 0
    }

    /**
     * 构造运行 `dsh --profile web` 的命令行。
     *
     * `--expose-internals` 不是可选的：web profile 会挂载 HMR 插件，它在
     * `node-addon-require-builtin` / loader 里硬性要求 Node 的 internal 模块，
     * 缺少该 flag 时启动直接失败：
     *   `failed to apply loader entry (@deepseek-ai/cordis-plugin-hmr):
     *    --expose-internals is required for HMR service`
     *
     * `--no-open` 阻止它去拉起系统默认浏览器（Android 上没有可用实现，且
     * 界面就在本 app 的 WebView 里）。
     */
    fun webCommand(port: Int): List<String> = listOf(
        nodeBinary.absolutePath,
        "--expose-internals",
        dshEntry.absolutePath,
        "--profile", "web",
        "--no-open",
        "--port", port.toString(),
    )
}
