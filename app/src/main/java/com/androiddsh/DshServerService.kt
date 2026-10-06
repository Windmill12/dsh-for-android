package com.androiddsh

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * 让 DSH 后台服务在 app 退到后台后继续活着。
 *
 * agent 跑一个长任务时用户很可能切出去；没有前台服务的话，进程随时可能被
 * 系统回收，正在跑的那一轮就断了。这里只负责"保活 + 显示一条通知"，
 * 进程本身仍由 [DshServer] 单例持有。
 */
class DshServerService : Service() {

    companion object {
        const val ACTION_START = "com.androiddsh.action.START"
        const val ACTION_STOP = "com.androiddsh.action.STOP"

        private const val CHANNEL_ID = "dsh-server"
        private const val NOTIFICATION_ID = 0x4453 // 'DS'

        fun start(context: Context) {
            val intent = Intent(context, DshServerService::class.java).setAction(ACTION_START)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.startService(Intent(context, DshServerService::class.java).setAction(ACTION_STOP))
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var observeJob: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        // 必须先进入前台，否则 5 秒后 ANR/崩溃
        goForeground(notification("正在准备 DSH 运行时…"))

        if (action == ACTION_STOP) {
            DshServer.stop()
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        val apiKey = SecretStore.get(this, SecretStore.KEY_API_KEY).orEmpty()
        DshServer.start(this, apiKey)
        observeState()
        return START_STICKY
    }

    /** 状态变化时刷新通知文案。onStartCommand 可能被多次调用，先取消上一个订阅。 */
    private fun observeState() {
        observeJob?.cancel()
        observeJob = scope.launch {
            DshServer.state.collectLatest { state ->
                val manager = getSystemService(NotificationManager::class.java)
                manager?.notify(NOTIFICATION_ID, notification(describe(state)))
            }
        }
    }

    private fun describe(state: DshState): String = when (state) {
        is DshState.Idle -> "未运行"
        is DshState.Preparing -> state.message
        is DshState.Starting -> "正在启动 Web 界面…"
        is DshState.Ready -> "运行中 · ${state.url.substringBefore("?")}"
        is DshState.Failed -> "启动失败：${state.message.lineSequence().first()}"
    }

    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, DshServerService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("AndroidDSH")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_notification)   // 鲸鱼剪影（系统只取 alpha 再着色）
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(
                Notification.Action.Builder(
                    android.graphics.drawable.Icon.createWithResource(
                        this, android.R.drawable.ic_menu_close_clear_cancel,
                    ),
                    "停止",
                    stop,
                ).build()
            )
            .build()
    }

    private fun goForeground(n: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "DSH 运行时", NotificationManager.IMPORTANCE_LOW).apply {
                description = "保持 DeepSeek Harness 在本机运行"
                setShowBadge(false)
            }
        )
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
