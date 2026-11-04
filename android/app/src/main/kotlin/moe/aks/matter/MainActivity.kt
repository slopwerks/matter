package moe.aks.matter

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine? = DownloadRuntime.engine

    override fun shouldDestroyEngineWithHost(): Boolean = !DownloadRuntime.ownsEngine(flutterEngine)

    override fun onDestroy() {
        AudioRuntime.detachHost(this)
        DownloadRuntime.detachHost(this)
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDownloadIntent(intent)
    }

    private fun handleDownloadIntent(intent: Intent?) {
        val action = intent?.action
        if (action != DownloadService.ACTION_INSTALL_UPDATE && action != DownloadService.ACTION_SHOW_UPDATE_FILE) return
        val path = intent?.getStringExtra("path") ?: return
        intent.action = null
        val result =
            object : MethodChannel.Result {
                override fun success(result: Any?) {}

                override fun notImplemented() {}

                override fun error(
                    code: String,
                    message: String?,
                    details: Any?,
                ) {
                    Toast.makeText(this@MainActivity, message ?: "无法处理更新安装包", Toast.LENGTH_LONG).show()
                }
            }
        if (action == DownloadService.ACTION_SHOW_UPDATE_FILE) requestUpdateFiles(path, result) else requestInstall(path, result)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        DownloadRuntime.attachHost(this, flutterEngine)
        AudioRuntime.attachHost(this, flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "moe.aks.matter/downloads",
        ).setMethodCallHandler { call, result ->
            if (call.method !in listOf("start", "progress", "finish")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            var retainedId: Int? = null
            try {
                val id = if (call.method == "start") nextDownloadId.incrementAndGet() else call.argument<Int>("id")!!
                val command =
                    Intent(this, DownloadService::class.java).apply {
                        action = call.method
                        putExtra("id", id)
                        putExtra("filename", call.argument<String>("filename"))
                        putExtra("received", call.argument<Number>("received")?.toLong() ?: 0L)
                        putExtra("total", call.argument<Number>("total")?.toLong() ?: 0L)
                        putExtra("status", call.argument<String>("status"))
                        putExtra("error", call.argument<String>("error"))
                        putExtra("installPath", call.argument<String>("installPath"))
                    }
                if (call.method == "start") {
                    DownloadRuntime.retain(id, flutterEngine, this)
                    retainedId = id
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4109)
                    }
                    ContextCompat.startForegroundService(this, command)
                } else {
                    startService(command)
                }
                result.success(if (call.method == "start") id else null)
            } catch (error: Exception) {
                retainedId?.let { DownloadRuntime.finish(it) }
                result.error("download_service_failed", "无法更新下载通知：${error.message}", null)
            }
        }
        handleDownloadIntent(intent)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UPDATE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk", "showInFiles" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "安装包路径无效", null)
                    } else if (call.method == "showInFiles") {
                        requestUpdateFiles(path, result)
                    } else {
                        requestInstall(path, result)
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILE_SAVE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFile" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "下载文件路径无效", null)
                    } else {
                        requestFileSave(path, result)
                    }
                }

                "openFile" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "文件路径无效", null)
                    } else {
                        requestFileOpen(path, result)
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun requestFileOpen(
        path: String,
        result: MethodChannel.Result,
    ) {
        try {
            val file = File(path).canonicalFile
            val root = File(cacheDir, "matter_open_files").canonicalFile
            require(file.isFile && file.parentFile?.parentFile == root) { "找不到待打开的文件" }
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val view =
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "text/markdown")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            startActivity(Intent.createChooser(view, "用其他应用打开"))
            result.success(true)
        } catch (error: Exception) {
            result.error("open_failed", "无法打开文件：${error.message}", null)
        }
    }

    private fun requestUpdateFiles(
        path: String,
        result: MethodChannel.Result,
    ) {
        fileSaveExecutor.execute {
            try {
                DownloadFileStore.saveUpdate(applicationContext, path)
            } catch (error: Exception) {
                runOnUiThread { result.error("save_failed", "无法保存安装包：${error.message}", null) }
                return@execute
            }
            runOnUiThread {
                try {
                    UpdateInstaller.openDownloads(this)
                    result.success(null)
                } catch (error: Exception) {
                    result.error("open_failed", "安装包已保存到下载目录，但无法打开文件管理器：${error.message}", null)
                }
            }
        }
    }

    private fun requestFileSave(
        path: String,
        result: MethodChannel.Result,
    ) {
        fileSaveExecutor.execute {
            try {
                DownloadFileStore.save(applicationContext, path)
                runOnUiThread { result.success(true) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("save_failed", "无法保存文件：${error.message}", null)
                }
            }
        }
    }

    private fun requestInstall(
        path: String,
        result: MethodChannel.Result,
    ) {
        try {
            UpdateInstaller.install(this, path)
            result.success(null)
        } catch (error: Exception) {
            result.error("install_failed", "无法打开系统安装器：${error.message}", null)
        }
    }

    companion object {
        private val fileSaveExecutor = Executors.newSingleThreadExecutor()
        private val nextDownloadId = AtomicInteger((System.currentTimeMillis() % 1_000_000_000).toInt() + 1_000_000_000)
        private const val UPDATE_CHANNEL = "moe.aks.matter/app_update"
        private const val FILE_SAVE_CHANNEL = "moe.aks.matter/file_saver"
    }
}
