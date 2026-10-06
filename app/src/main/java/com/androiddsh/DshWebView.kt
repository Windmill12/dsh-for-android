package com.androiddsh

import android.annotation.SuppressLint
import android.app.Activity
import android.app.DownloadManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import org.json.JSONObject
import java.io.File

/**
 * DSH 原生 Web 界面的容器。
 *
 * 这里刻意不做任何"移动端改写"——加载的就是 `dsh web` 自己吐出来的
 * `http://127.0.0.1:<port>/?token=…`。那一跳会 303 到 `./` 并种下绑定
 * authority 的会话 cookie，所以必须原样用带 token 的 URL 打开，不能只填根地址。
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun DshWebView(
    url: String,
    desktopLayout: Boolean,
    modifier: Modifier = Modifier,
    onWebViewCreated: (WebView) -> Unit = {},
) {
    val context = LocalContext.current
    var webView by remember { mutableStateOf<WebView?>(null) }
    var progress by remember { mutableIntStateOf(100) }
    var filePathCallback by remember { mutableStateOf<ValueCallback<Array<Uri>>?>(null) }

    val fileChooser = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val callback = filePathCallback
        filePathCallback = null
        if (callback == null) return@rememberLauncherForActivityResult
        val data = result.data
        val uris = when {
            result.resultCode != Activity.RESULT_OK || data == null -> null
            data.clipData != null -> (0 until data.clipData!!.itemCount)
                .map { data.clipData!!.getItemAt(it).uri }.toTypedArray()
            data.data != null -> arrayOf(data.data!!)
            else -> null
        }
        callback.onReceiveValue(uris)
    }

    BackHandler(enabled = webView?.canGoBack() == true) { webView?.goBack() }

    Box(modifier.fillMaxSize()) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                WebView(ctx).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.databaseEnabled = true
                    // useWideViewPort 必须开着：宽屏模式要靠 <meta viewport> 把
                    // **布局视口** 真正加宽（见 applyViewportWidth）。代价是这台
                    // WebView 上 vh / dvh 会全部解析成 0px —— 所以下面那段
                    // VIEWPORT_SHIM_JS 的像素高度兜底是必需项，不是可选优化。
                    //
                    // loadWithOverviewMode 必须开着：它就是"把内容整体缩放到屏幕
                    // 宽度"的那一步。宽屏模式正是靠它 —— 布局视口设成 720，再由它
                    // 算出 initial-scale = 视口宽/720 缩下来。手机模式下 meta 是
                    // width=device-width，内容本来就正好铺满，这一项等于空转，
                    // 所以两种模式可以共用一个常量，不必来回切 WebSettings。
                    settings.useWideViewPort = true
                    settings.loadWithOverviewMode = true
                    settings.setSupportZoom(true)
                    settings.builtInZoomControls = false
                    settings.displayZoomControls = false
                    settings.mediaPlaybackRequiresUserGesture = false
                    settings.cacheMode = WebSettings.LOAD_DEFAULT

                    CookieManager.getInstance().setAcceptCookie(true)
                    CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)

                    // 本地回环上的页面：debug 构建下允许 chrome://inspect 调试
                    if (BuildConfig.DEBUG) WebView.setWebContentsDebuggingEnabled(true)

                    addJavascriptInterface(DownloadBridge(ctx), "AndroidDsh")

                    webViewClient = object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(
                            view: WebView,
                            request: WebResourceRequest,
                        ): Boolean {
                            val uri = request.url
                            if (uri.host == "127.0.0.1" || uri.host == "localhost") return false
                            // 外链交给系统浏览器，别在 agent 的界面里迷路
                            if (request.isForMainFrame) {
                                runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, uri)) }
                                return true
                            }
                            return false
                        }

                        override fun onPageCommitVisible(view: WebView, url: String?) {
                            super.onPageCommitVisible(view, url)
                            // 尽早装上，减少"先塌后修"的闪烁
                            runCatching { view.evaluateJavascript(VIEWPORT_SHIM_JS, null) }
                        }

                        override fun onPageFinished(view: WebView, url: String?) {
                            super.onPageFinished(view, url)
                            // 先钉住视口高度，再套用户选的缩放
                            runCatching { view.evaluateJavascript(VIEWPORT_SHIM_JS, null) }
                            applyViewportWidth(view, desktopLayout)
                        }

                        override fun onReceivedError(
                            view: WebView,
                            request: WebResourceRequest,
                            err: WebResourceError,
                        ) {
                            if (request.isForMainFrame) {
                                Log.w("DshWeb", "页面加载失败: ${err.description} ${request.url}")
                            }
                        }
                    }

                    webChromeClient = object : WebChromeClient() {
                        override fun onProgressChanged(view: WebView, newProgress: Int) {
                            progress = newProgress
                        }

                        override fun onConsoleMessage(msg: android.webkit.ConsoleMessage): Boolean {
                            Log.d(
                                "DshWeb",
                                "[${msg.messageLevel()}] ${msg.message()} @${msg.lineNumber()}",
                            )
                            return true
                        }

                        override fun onShowFileChooser(
                            view: WebView,
                            callback: ValueCallback<Array<Uri>>,
                            params: FileChooserParams,
                        ): Boolean {
                            filePathCallback?.onReceiveValue(null)
                            filePathCallback = callback
                            return runCatching { fileChooser.launch(params.createIntent()); true }
                                .getOrElse {
                                    filePathCallback = null
                                    false
                                }
                        }
                    }

                    setDownloadListener { downloadUrl, _, disposition, mimeType, _ ->
                        enqueueDownload(ctx, this, downloadUrl, disposition, mimeType)
                    }

                    loadUrl(url)
                    webView = this
                    onWebViewCreated(this)
                }
            },
            update = { view ->
                // 切换宽屏排版后立即生效，不必重新加载（避免丢掉滚动位置）
                if (view.url != null) {
                    runCatching { view.evaluateJavascript(VIEWPORT_SHIM_JS, null) }
                    applyViewportWidth(view, desktopLayout)
                }
            },
        )

        if (progress in 1..99) {
            LinearProgressIndicator(
                progress = { progress / 100f },
                modifier = Modifier.align(Alignment.TopCenter).fillMaxWidth(),
            )
        }
    }
}

/** 宽屏模式下使用的布局视口宽度（CSS px）。 */
private const val WIDE_LAYOUT_WIDTH = 720

/**
 * 切换布局视口宽度。
 *
 * 这里**不能**用 CSS `zoom`：zoom 对 `position:fixed` 是无效的 —— Blink 把固定
 * 定位元素的包含块算成可见视口宽度，zoom 只把结果等比缩小。DSH 的设置浮层正是
 * `position:fixed` 的 `role=dialog`，所以之前那版 zoom 实现让它在宽屏下**反而
 * 更挤**（实测内容列从 130px 缩到 81px）。
 *
 * 正确做法是改 `<meta name=viewport>`：让布局视口本身就是 720 CSS px，Chromium
 * 再整页缩放到屏幕宽度。这样固定定位元素也是 720 宽，设置页 188px 的左导航之外
 * 还能剩约 480px 给内容。
 *
 * 手机模式回到 `width=device-width`（布局视口 = WebView 的 CSS 宽度）。
 * 改完 meta 要让 vh 兜底脚本重新同步一次高度。
 */
private fun applyViewportWidth(view: WebView, desktop: Boolean) {
    val content = if (desktop) {
        "width=$WIDE_LAYOUT_WIDTH"
    } else {
        "width=device-width, initial-scale=1"
    }
    val js = """
        (function () {
          var m = document.querySelector('meta[name="viewport"]');
          if (!m) {
            m = document.createElement('meta');
            m.name = 'viewport';
            document.head.appendChild(m);
          }
          if (m.getAttribute('content') !== '$content') {
            m.setAttribute('content', '$content');
            if (window.__dshViewportShim) window.__dshViewportShim.sync();
          }
        })();
    """.trimIndent()
    runCatching { view.evaluateJavascript(js, null) }
}

/**
 * 触屏版 WebView 的 "vh = 0" 兜底。
 *
 * 现象：在 Android WebView（实测 133.0.6943.137，模拟器与真机一致）里
 * **视口单位 `vh` / `dvh` / `svh` / `lvh` 一律解析成 0px**，而 `vw` 正常、
 * `window.innerHeight` 也正常（=712）。这不是 DSH 的锅：
 *
 *     <style>html,body{height:100%}</style><div style="height:100vh">
 *
 * 这样一张空白页在该 WebView 里 html 高度同样是 0。`useWideViewPort` /
 * `loadWithOverviewMode` 全关也无效，所以只能在页面侧兜住。
 *
 * DSH 前端有 13 个文件用到 vh（欢迎弹窗的 `max-height`、下拉菜单、卡片、
 * 代码查看器、右侧面板……），其中 `html,body,#root{height:100%}` 那条会让
 * 整个界面塌成 0 —— 表现为只剩一个 fixed 的弹窗遮罩，看起来"白屏"。
 *
 * 兜底做两件事：
 *  1. 把 html / body / #root 的高度钉成 `innerHeight` 像素；
 *  2. 把所有样式表里出现的 vh 改写成 `calc(var(--dsh-vh) * n / 100)`，
 *     其中 `--dsh-vh` 由同一段脚本按 `innerHeight` 维护。
 *
 * 先探测：如果这台设备的 vh 本来是好的（未来 WebView 修了，或某些厂商 ROM），
 * 就完全不接管，保持原样。
 */
private val VIEWPORT_SHIM_JS = """
(function () {
  if (!document.body) return;   // onPageCommitVisible 可能早于 <body>；onPageFinished 会再来一次
  var shim = window.__dshViewportShim;
  if (shim) { shim.sync(); shim.patch(); return; }

  function probeBroken() {
    var el = document.createElement('div');
    el.style.cssText = 'position:absolute;left:-9999px;top:0;width:0;height:100vh';
    document.body.appendChild(el);
    var broken = el.getBoundingClientRect().height < 1;
    el.remove();
    return broken;
  }

  var patched = new WeakSet();
  // 注意 fallback 里也含 "vh"，所以改写过的值必须跳过，否则会自我嵌套
  var VH = /(-?\d*\.?\d+)(dvh|svh|lvh|vh)/g;

  function rewrite(value) {
    if (!value || value.indexOf('vh') < 0 || value.indexOf('--dsh-vh') >= 0) return value;
    return value.replace(VH, function (_, n) {
      return 'calc(var(--dsh-vh, 100vh) * ' + n + ' / 100)';
    });
  }

  function walk(rules) {
    for (var i = 0; i < rules.length; i++) {
      var rule = rules[i];
      if (rule.cssRules && rule.cssRules.length) { walk(rule.cssRules); continue; }
      var style = rule.style;
      if (!style) continue;
      for (var j = 0; j < style.length; j++) {
        var prop = style[j];
        var value = style.getPropertyValue(prop);
        var next = rewrite(value);
        if (next !== value) style.setProperty(prop, next, style.getPropertyPriority(prop));
      }
    }
  }

  function patch() {
    for (var i = 0; i < document.styleSheets.length; i++) {
      var sheet = document.styleSheets[i];
      if (patched.has(sheet)) continue;
      patched.add(sheet);
      try { if (sheet.cssRules) walk(sheet.cssRules); } catch (e) { /* 跨域表，跳过 */ }
    }
  }

  function sync() {
    var px = window.innerHeight + 'px';
    var de = document.documentElement;
    de.style.setProperty('--dsh-vh', px);
    de.style.setProperty('height', px, 'important');
    if (document.body) document.body.style.setProperty('height', px, 'important');
    var root = document.getElementById('root');
    if (root) root.style.setProperty('height', px, 'important');
  }

  // DSH 的 Web 前端没有任何宽度断点，设置浮层又是"188px 左导航 + 右内容"的
  // 固定两栏，所以在 366 CSS px 的手机模式下内容列只剩 ~130px，每个字都得
  // 竖着排。这里在窄屏下把导航改成横向标签条，内容吃满整宽。
  //
  // 选择器全部走语义/结构：`role=dialog[aria-modal]` 是稳定的，`> nav` 只有
  // 设置浮层才有（欢迎弹窗是单栏卡片，不会匹配），CSS module 的哈希类名一个
  // 都不依赖，所以升级 DSH 也不会失效。
  var NARROW_CSS = [
    '@media (max-width: 700px) {',
    '  [role="dialog"][aria-modal="true"]:has(> nav) {',
    '    flex-direction: column !important;',
    '  }',
    '  [role="dialog"][aria-modal="true"]:has(> nav) > nav {',
    '    flex: 0 0 auto !important;',
    '    width: 100% !important;',
    '    max-width: none !important;',
    '    height: auto !important;',
    '    overflow: visible !important;',
    '    border-right: 0 !important;',
    '  }',
    '  [role="dialog"][aria-modal="true"]:has(> nav) > nav > div:last-child {',
    '    flex-direction: row !important;',
    '    flex-wrap: wrap !important;',
    '    width: 100% !important;',
    '  }',
    '  [role="dialog"][aria-modal="true"]:has(> nav) > nav button {',
    '    flex: 0 0 auto !important;',
    '    width: auto !important;',
    '  }',
    '  [role="dialog"][aria-modal="true"]:has(> nav) > div {',
    '    flex: 1 1 auto !important;',
    '    width: 100% !important;',
    '    min-width: 0 !important;',
    '    min-height: 0 !important;',
    '  }',
    '}'
  ].join('\n');

  function installNarrowLayout() {
    if (document.getElementById('androiddsh-narrow-layout')) return;
    var style = document.createElement('style');
    style.id = 'androiddsh-narrow-layout';
    style.textContent = NARROW_CSS;
    document.head.appendChild(style);
  }

  var broken = probeBroken();
  window.__dshViewportShim = { sync: sync, patch: patch, broken: broken };

  installNarrowLayout();

  // --dsh-vh 无论好坏都维护：好的设备上改写没发生，这个变量没人用
  sync();
  if (!broken) return;

  console.log('androiddsh: viewport units (vh) are broken here; installing the pixel-height shim');
  patch();

  // 客户端插件的样式是运行时注入 <style> 的，得盯着 <head>
  new MutationObserver(patch).observe(document.head, { childList: true });
  // SPA 挂载 / 键盘弹出 / 旋转
  new MutationObserver(sync).observe(document.body, { childList: true });
  window.addEventListener('resize', sync);
  window.addEventListener('orientationchange', function () { setTimeout(sync, 60); });
  if (window.visualViewport) window.visualViewport.addEventListener('resize', sync);
})();
""".trimIndent()

/**
 * 触发一次下载。
 *
 * `present` 产出的文件、`/export` 的会话导出在页面里都是 `blob:` URL：
 * WebView 的 DownloadListener 拿不到内容，只能回到页面里把 blob 读成
 * base64，再通过 [DownloadBridge] 交给原生落盘。
 */
private fun enqueueDownload(
    context: Context,
    view: WebView,
    url: String,
    contentDisposition: String,
    mimeType: String,
) {
    if (url.startsWith("blob:")) {
        val name = contentDisposition.substringAfter("filename=", "").trim('"', ' ')
            .ifBlank { "dsh-download" }
        val script = """
            (function () {
              fetch(${JSONObject.quote(url)})
                .then(function (r) { return r.blob(); })
                .then(function (b) {
                  var fr = new FileReader();
                  fr.onload = function () {
                    var s = String(fr.result);
                    AndroidDsh.save(${JSONObject.quote(name)}, b.type || ${JSONObject.quote(mimeType)}, s.substring(s.indexOf(',') + 1));
                  };
                  fr.readAsDataURL(b);
                })
                .catch(function (e) { console.error('dsh download failed: ' + e); });
            })();
        """.trimIndent()
        runCatching { view.evaluateJavascript(script, null) }
        return
    }

    val name = contentDisposition.substringAfter("filename=", "").trim('"', ' ')
        .ifBlank { "dsh-download" }
    val request = DownloadManager.Request(Uri.parse(url))
        .setMimeType(mimeType)
        .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
        .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name)
    runCatching {
        (context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager).enqueue(request)
        Toast.makeText(context, "已加入下载队列", Toast.LENGTH_SHORT).show()
    }.onFailure { Toast.makeText(context, "下载失败：${it.message}", Toast.LENGTH_LONG).show() }
}

/** 页面侧读出的 blob 内容在这里落盘。 */
private class DownloadBridge(private val context: Context) {

    @JavascriptInterface
    fun save(name: String, mimeType: String, base64: String) {
        runCatching {
            val bytes = Base64.decode(base64, Base64.DEFAULT)
            val safeName = name.ifBlank { "dsh-download" }.replace('/', '_')
            val where = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                saveToMediaStore(safeName, mimeType, bytes)
            } else {
                saveToAppDir(safeName, bytes)
            }
            Toast.makeText(context, "已保存到 $where", Toast.LENGTH_LONG).show()
        }.onFailure {
            Log.e("DshWeb", "保存下载失败", it)
            Toast.makeText(context, "保存失败：${it.message}", Toast.LENGTH_LONG).show()
        }
    }

    private fun saveToMediaStore(name: String, mime: String, bytes: ByteArray): String {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime.ifBlank { "application/octet-stream" })
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("无法创建下载条目")
        resolver.openOutputStream(uri)!!.use { it.write(bytes) }
        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return "下载/$name"
    }

    private fun saveToAppDir(name: String, bytes: ByteArray): String {
        val dir = File(context.getExternalFilesDir(null), "downloads").apply { mkdirs() }
        val file = File(dir, name)
        file.writeBytes(bytes)
        return file.absolutePath
    }
}
