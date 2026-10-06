package com.androiddsh

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

/** DSH 后台服务的状态机。 */
sealed interface DshState {
    /** 还没启动 */
    data object Idle : DshState

    /** 正在解压 / 准备运行时 */
    data class Preparing(val message: String) : DshState

    /** 进程已拉起，等它打印出带 token 的 URL */
    data object Starting : DshState

    /** 服务已就绪，[url] 是带认证 token 的入口地址 */
    data class Ready(val url: String) : DshState

    /** 启动失败或进程中途退出 */
    data class Failed(val message: String) : DshState
}

/**
 * `dsh --profile web` 子进程的生命周期管理。
 *
 * 单例：Activity（WebView）和前台 Service（保活）读同一份状态，避免 IPC。
 * 状态用 [StateFlow] 暴露给 Compose。
 *
 * 这里承载的是 **DSH 原生的 Web 界面** —— 和桌面端 `dsh web` 完全同一个前端，
 * 而不是另写一套 Android UI。
 */
object DshServer {

    private const val TAG = "DshServer"

    /** `dsh web: http://127.0.0.1:7300/?token=…` */
    private val URL_LINE = Regex("""dsh web:\s*(http://\S+)""")

    /** 从启动到打印 URL 的容忍上限。首次解压已单独计时，这里只管进程本身。 */
    private const val START_TIMEOUT_MS = 180_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _state = MutableStateFlow<DshState>(DshState.Idle)
    val state: StateFlow<DshState> = _state.asStateFlow()

    private val _log = MutableStateFlow("")
    val log: StateFlow<String> = _log.asStateFlow()

    private val starting = AtomicBoolean(false)

    @Volatile
    private var process: Process? = null

    @Volatile
    private var runtime: DshRuntime? = null

    /** 当前进程使用的工作目录；权限变化后用它判断要不要重启。 */
    @Volatile
    var currentWorkspace: File? = null
        private set

    /** 启动当前进程时是否已拿到"所有文件访问" —— 权限一变就得换目录重启。 */
    @Volatile
    var currentAllFilesAccess: Boolean? = null
        private set

    private var readerJob: Job? = null
    private var watchdogJob: Job? = null

    /** 已经跑起来且拿到 URL 就不再重复拉起 */
    fun isRunning(): Boolean = process?.isAlive == true && _state.value is DshState.Ready

    /**
     * 拉起服务。幂等：已在运行、或已在启动流程里，直接返回。
     *
     * @param context 用于取 [DshRuntime]
     * @param apiKey DeepSeek 凭证；空串表示依赖已有的配置
     */
    fun start(context: Context, apiKey: String) {
        if (isRunning() || !starting.compareAndSet(false, true)) return
        val rt = DshRuntime(context.applicationContext)
        runtime = rt
        scope.launch {
            try {
                prepareAndLaunch(rt, apiKey)
            } catch (t: Throwable) {
                Log.e(TAG, "启动失败", t)
                _state.value = DshState.Failed(t.message ?: t.javaClass.simpleName)
            } finally {
                starting.set(false)
            }
        }
    }

    private suspend fun prepareAndLaunch(rt: DshRuntime, apiKey: String) {
        if (!rt.isReady()) {
            _state.value = DshState.Preparing("准备运行时…")
            withContext(Dispatchers.IO) {
                rt.ensureExtracted { msg -> _state.value = DshState.Preparing(msg) }
            }
        }

        val node = rt.nodeBinary
        if (!node.isFile) {
            _state.value = DshState.Failed("找不到内嵌的 Node 运行时：${node.absolutePath}")
            return
        }
        // 每次安装 APK 后 nativeLibraryDir 都会变，所以这一步每次启动都要做
        rt.ensureExecShims()

        // 工作目录在这里定下来：拿到"所有文件访问"就是 /sdcard/Documents/DSH，
        // 否则退回 app 私有外部目录。DSH 用 process.cwd() 作新会话的默认
        // workspaceRoot，所以这一步直接决定 agent 在哪里干活。
        val workspace = rt.workspaceDir()
        currentWorkspace = workspace
        currentAllFilesAccess = rt.hasAllFilesAccess()

        killProcess()
        val port = rt.pickPort()
        rt.logFile.delete()
        appendLog("== ${timestamp()} 启动 ${rt.webCommand(port).joinToString(" ")}")
        appendLog("== HOME=${rt.homeDir}")
        appendLog("== workspace=${workspace.absolutePath} (allFilesAccess=${rt.hasAllFilesAccess()})")

        _state.value = DshState.Starting

        // 继承 app 进程的环境再覆盖：Android 的 bionic / 原生模块会读一些
        // 系统变量，清空环境比留着更容易踩坑。
        val builder = ProcessBuilder(rt.webCommand(port))
            .directory(workspace)
            .redirectErrorStream(true)
        builder.environment().putAll(rt.childEnvironment(apiKey, workspace))

        val proc = try {
            builder.start()
        } catch (t: Throwable) {
            _state.value = DshState.Failed("无法启动 DSH 进程：${t.message}")
            return
        }
        process = proc
        pumpOutput(proc, rt)
        armWatchdog(proc, rt)
    }

    /** 持续读取子进程输出：写日志、解析 URL、检测退出。 */
    private fun pumpOutput(proc: Process, rt: DshRuntime) {
        readerJob?.cancel()
        readerJob = scope.launch {
            try {
                BufferedReader(InputStreamReader(proc.inputStream)).use { reader ->
                    reader.lineSequence().forEach { line ->
                        appendLog(line)
                        if (_state.value !is DshState.Ready) {
                            URL_LINE.find(line)?.groupValues?.get(1)?.let { url ->
                                Log.i(TAG, "DSH web ready: $url")
                                _state.value = DshState.Ready(url)
                            }
                        }
                    }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "读取子进程输出失败", t)
            }
            // 输出流结束 == 进程退出
            val code = runCatching { proc.waitFor() }.getOrDefault(-1)
            if (process === proc) {
                process = null
                val tail = _log.value.lines().takeLast(8).joinToString("\n")
                _state.value = DshState.Failed("DSH 进程已退出（code=$code）\n$tail")
            }
        }
    }

    /** 超过 [START_TIMEOUT_MS] 还没拿到 URL 就判定失败，避免界面永远转圈。 */
    private fun armWatchdog(proc: Process, rt: DshRuntime) {
        watchdogJob?.cancel()
        watchdogJob = scope.launch {
            var waited = 0L
            while (waited < START_TIMEOUT_MS) {
                kotlinx.coroutines.delay(1_000)
                waited += 1_000
                if (_state.value is DshState.Ready || !proc.isAlive) return@launch
            }
            if (_state.value is DshState.Starting) {
                val tail = _log.value.lines().takeLast(8).joinToString("\n")
                _state.value = DshState.Failed("等待 DSH Web 服务超时（${START_TIMEOUT_MS / 1000} 秒）\n$tail")
            }
        }
    }

    /** 停止子进程。DSH 的会话都在磁盘上，重启不丢历史。 */
    fun stop() {
        watchdogJob?.cancel()
        readerJob?.cancel()
        killProcess()
        _state.value = DshState.Idle
    }

    private fun killProcess() {
        val proc = process ?: return
        process = null
        runCatching {
            proc.destroy()
            if (!proc.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)) proc.destroyForcibly()
        }
    }

    private fun appendLog(line: String) {
        _log.value = (_log.value + line + "\n").takeLast(200_000)
        runCatching { runtime?.logFile?.appendText(line + "\n") }
    }

    private fun timestamp(): String =
        SimpleDateFormat("MM-dd HH:mm:ss", Locale.US).format(Date())

    /** 供"设置"页展示关键路径。 */
    fun paths(context: Context): List<Pair<String, String>> {
        val rt = runtime ?: DshRuntime(context.applicationContext)
        return listOf(
            "node" to rt.nodeBinary.absolutePath,
            "bash" to if (rt.bashBinary.isFile) rt.bashBinary.absolutePath else DshRuntime.SYSTEM_SH,
            "shell 入口" to rt.binDir.absolutePath,
            "DSH 入口" to rt.dshEntry.absolutePath,
            "HOME" to rt.homeDir.absolutePath,
            "工作目录" to rt.workspaceDir().absolutePath,
            "日志" to rt.logFile.absolutePath,
        )
    }
}
