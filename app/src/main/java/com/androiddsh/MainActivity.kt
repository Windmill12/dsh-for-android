package com.androiddsh

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

class MainActivity : ComponentActivity() {

    /**
     * 每次 onResume 自增，用来让 Compose 重新读一遍存储权限。
     * 用户去系统设置里开"所有文件访问"再回来，走的就是这条路。
     */
    private val resumeTick = mutableIntStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        askRuntimePermissions()
        setContent {
            MaterialTheme {
                Surface { DshRoot(this, resumeTick.intValue) }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        resumeTick.intValue++
        // 权限变了 → 工作目录会变（公开目录 ↔ 私有兜底），正在跑的进程要重启。
        // 只比较权限位，不碰文件系统，避免在主线程上做磁盘 I/O。
        val used = DshServer.currentAllFilesAccess ?: return
        if (used != DshRuntime(this).hasAllFilesAccess()) {
            DshServer.stop()
            DshServerService.start(this)
        }
    }

    /**
     * Android 13+ 需要显式授权才能显示前台服务的那条常驻通知。
     * API 29 及以下还需要 WRITE_EXTERNAL_STORAGE 才能写公开目录
     * （API 30+ 改用"所有文件访问"，只能在系统设置里开，见设置页的按钮）。
     */
    private fun askRuntimePermissions() {
        val wanted = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R &&
                checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
            }
        }
        if (wanted.isNotEmpty()) requestPermissions(wanted.toTypedArray(), 100)
    }
}

/** 打开"所有文件访问"的系统设置页；个别 ROM 没有 app 专属页，退回总列表。 */
private fun openAllFilesAccessSettings(context: Context) {
    val app = Intent(
        android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
        Uri.parse("package:${context.packageName}"),
    )
    runCatching { context.startActivity(app) }.onFailure {
        runCatching {
            context.startActivity(Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }
}

/** SharedPreferences 键：是否使用宽屏布局（见 applyViewportWidth）。 */
private const val KEY_WIDE_LAYOUT = "wideLayout"

@Composable
private fun DshRoot(activity: ComponentActivity, resumeTick: Int) {
    val context = activity
    val state by DshServer.state.collectAsState()
    val log by DshServer.log.collectAsState()

    var showSettings by remember { mutableStateOf(false) }
    val prefs = remember { context.getSharedPreferences("android-dsh", Context.MODE_PRIVATE) }
    // 宽屏/手机视图的选择要记住：DSH 是桌面排版，很多人会一直用宽屏
    var desktopLayout by remember { mutableStateOf(prefs.getBoolean(KEY_WIDE_LAYOUT, false)) }
    var storagePromptDismissed by remember {
        mutableStateOf(prefs.getBoolean("storagePromptDismissed", false))
    }
    // resumeTick 变化时重新采样权限（用户可能刚从系统设置里回来）
    val runtime = remember(resumeTick) { DshRuntime(context) }
    val hasAllFiles = remember(resumeTick) { runtime.hasAllFilesAccess() }

    // 运行时准备 + 拉进程全部交给前台 Service（它同时负责保活），
    // Activity 只观察状态，避免旋转/重建时重复解压。
    LaunchedEffect(Unit) { DshServerService.start(context) }

    when {
        showSettings -> SettingsScreen(
            context = context,
            state = state,
            log = log,
            hasAllFilesAccess = hasAllFiles,
            onDone = { showSettings = false },
        )

        state is DshState.Ready -> WebScreen(
            url = (state as DshState.Ready).url,
            desktopLayout = desktopLayout,
            onToggleDesktop = {
                desktopLayout = !desktopLayout
                prefs.edit().putBoolean(KEY_WIDE_LAYOUT, desktopLayout).apply()
            },
            onOpenSettings = { showSettings = true },
        )

        else -> StatusScreen(
            state = state,
            log = log,
            onRetry = {
                DshServer.stop()
                DshServerService.start(context)
            },
            onOpenSettings = { showSettings = true },
        )
    }

    // 首装提示去开"所有文件访问"：不授权也能用（退回私有目录），所以不拦着启动
    if (!hasAllFiles && !storagePromptDismissed) {
        StorageAccessDialog(
            onGrant = {
                storagePromptDismissed = true
                prefs.edit().putBoolean("storagePromptDismissed", true).apply()
                openAllFilesAccessSettings(context)
            },
            onSkip = {
                storagePromptDismissed = true
                prefs.edit().putBoolean("storagePromptDismissed", true).apply()
            },
        )
    }
}

@Composable
private fun StorageAccessDialog(onGrant: () -> Unit, onSkip: () -> Unit) {
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onSkip,
        title = { Text("让文件能被直接访问") },
        text = {
            Text(
                "DSH 默认把工作目录放在 /sdcard/Documents/DSH，这样文件管理器、USB、"
                    + "云盘同步都能直接看到 agent 产出的文件。\n\n"
                    + "这需要「所有文件访问」权限（内嵌的 node / bash 子进程只能用真实"
                    + "文件路径，用不了系统的文件选择器）。不授权也能用，只是工作目录会"
                    + "退回 app 私有目录 Android/data/com.androiddsh/files/workspace。",
                fontSize = 13.sp,
            )
        },
        confirmButton = { Button(onClick = onGrant) { Text("去授权") } },
        dismissButton = { TextButton(onClick = onSkip) { Text("先用私有目录") } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WebScreen(
    url: String,
    desktopLayout: Boolean,
    onToggleDesktop: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    var webViewRef by remember { mutableStateOf<android.webkit.WebView?>(null) }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("DSH", fontSize = 16.sp) },
                actions = {
                    // 手机屏幕窄，只留三个最常用的动作；"在浏览器打开"挪到设置页
                    TextButton(onClick = onToggleDesktop) {
                        Text(if (desktopLayout) "手机" else "宽屏", fontSize = 13.sp)
                    }
                    TextButton(onClick = { webViewRef?.reload() }) { Text("刷新", fontSize = 13.sp) }
                    TextButton(onClick = onOpenSettings) { Text("设置", fontSize = 13.sp) }
                },
            )
        },
    ) { padding ->
        // imePadding：API 35+ 强制 edge-to-edge 之后，窗口不再被输入法顶起来，
        // 不自己补这块内边距的话软键盘会盖住 DSH 的输入框。
        Box(Modifier.padding(padding).imePadding()) {
            DshWebView(
                url = url,
                desktopLayout = desktopLayout,
                onWebViewCreated = { webViewRef = it },
            )
        }
    }
}

@Composable
private fun StatusScreen(
    state: DshState,
    log: String,
    onRetry: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    val failed = state as? DshState.Failed
    Column(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("AndroidDSH", style = MaterialTheme.typography.headlineSmall)

        if (failed == null) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                CircularProgressIndicator(modifier = Modifier.padding(4.dp))
                Text(
                    when (state) {
                        is DshState.Preparing -> state.message
                        is DshState.Starting -> "正在启动 DSH Web 服务…"
                        else -> "正在准备…"
                    }
                )
            }
        } else {
            Text("启动失败", color = MaterialTheme.colorScheme.error, fontSize = 16.sp)
            Text(failed.message, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onRetry) { Text("重试") }
                OutlinedButton(onClick = onOpenSettings) { Text("设置") }
            }
        }

        if (log.isNotBlank()) {
            HorizontalDivider()
            Text("运行日志", style = MaterialTheme.typography.labelLarge)
            Box(
                Modifier.fillMaxWidth().weight(1f)
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .verticalScroll(rememberScrollState())
                    .padding(8.dp)
            ) {
                Text(log, fontSize = 10.sp, fontFamily = FontFamily.Monospace, color = Color.Unspecified)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsScreen(
    context: Context,
    state: DshState,
    log: String,
    hasAllFilesAccess: Boolean,
    onDone: () -> Unit,
) {
    var apiKey by remember { mutableStateOf(SecretStore.get(context, SecretStore.KEY_API_KEY).orEmpty()) }
    var saved by remember { mutableStateOf<String?>(null) }
    val paths = remember { DshServer.paths(context) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("设置") },
                actions = { TextButton(onClick = onDone) { Text("返回") } },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "DeepSeek 凭证由 Android Keystore 加密后保存在本机，只注入到 DSH 子进程的环境变量里。",
                fontSize = 12.sp,
            )
            OutlinedTextField(
                value = apiKey,
                onValueChange = {
                    apiKey = it
                    saved = null
                },
                label = { Text("DEEPSEEK_API_KEY") },
                visualTransformation = PasswordVisualTransformation(),
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = {
                    SecretStore.put(context, SecretStore.KEY_API_KEY, apiKey.trim())
                    saved = "已保存，正在重启 DSH…"
                    DshServer.stop()
                    DshServerService.start(context)
                }) { Text("保存并重启") }

                OutlinedButton(onClick = {
                    SecretStore.put(context, SecretStore.KEY_API_KEY, "")
                    apiKey = ""
                    saved = "已清除"
                }) { Text("清除") }
            }
            saved?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.primary) }

            HorizontalDivider()
            Text("工作目录", style = MaterialTheme.typography.labelLarge)
            Text(
                if (hasAllFilesAccess) {
                    "已获得「所有文件访问」，agent 在 /sdcard/Documents/DSH 里干活，" +
                        "文件管理器 / USB 都能直接看到。"
                } else {
                    "未获得「所有文件访问」，agent 暂时在 app 私有目录里干活" +
                        "（Android/data/com.androiddsh/files/workspace）。" +
                        "授权后会自动重启到 /sdcard/Documents/DSH。"
                },
                fontSize = 12.sp,
            )
            if (!hasAllFilesAccess) {
                Button(onClick = { openAllFilesAccessSettings(context) }) { Text("去授权") }
            }
            Text("当前：${DshServer.currentWorkspace?.absolutePath ?: "（未启动）"}", fontSize = 11.sp)

            HorizontalDivider()
            Text("当前状态", style = MaterialTheme.typography.labelLarge)
            Text(describeState(state), fontSize = 12.sp)
            (state as? DshState.Ready)?.let { ready ->
                OutlinedButton(onClick = {
                    runCatching {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(ready.url)))
                    }
                }) { Text("在系统浏览器中打开") }
            }

            HorizontalDivider()
            Text("路径", style = MaterialTheme.typography.labelLarge)
            paths.forEach { (label, value) ->
                Text("$label: $value", fontSize = 11.sp, fontFamily = FontFamily.Monospace)
            }

            HorizontalDivider()
            Text("运行日志", style = MaterialTheme.typography.labelLarge)
            Text(
                log.ifBlank { "（暂无）" },
                fontSize = 10.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}

private fun describeState(state: DshState): String = when (state) {
    is DshState.Idle -> "未运行"
    is DshState.Preparing -> state.message
    is DshState.Starting -> "正在启动"
    is DshState.Ready -> "运行中 · ${state.url.substringBefore("?")}"
    is DshState.Failed -> "失败 · ${state.message.lineSequence().first()}"
}
