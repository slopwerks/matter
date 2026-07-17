package moe.aks.matter

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pendingInstallResult: MethodChannel.Result? = null
    private var pendingApkPath: String? = null
    private var pendingFileSaveResult: MethodChannel.Result? = null
    private var pendingFileSaveSource: File? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UPDATE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "安装包路径无效", null)
                    } else {
                        requestInstall(path, result)
                    }
                }
                else -> result.notImplemented()
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
                else -> result.notImplemented()
            }
        }
    }

    private fun requestInstall(path: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            if (pendingInstallResult != null) {
                result.error("install_in_progress", "已有安装请求正在处理", null)
                return
            }
            pendingInstallResult = result
            pendingApkPath = path
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            )
            startActivityForResult(intent, INSTALL_PERMISSION_REQUEST)
            return
        }

        launchPackageInstaller(path, result)
    }

    @Deprecated("Deprecated by Android; retained for the package-install permission flow")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            INSTALL_PERMISSION_REQUEST -> {
                val result = pendingInstallResult
                val path = pendingApkPath
                pendingInstallResult = null
                pendingApkPath = null
                if (result == null || path == null) return

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    !packageManager.canRequestPackageInstalls()
                ) {
                    result.error("install_permission_denied", "未授予安装未知应用权限", null)
                    return
                }
                launchPackageInstaller(path, result)
            }
            FILE_SAVE_REQUEST -> finishFileSave(resultCode, data)
        }
    }

    private fun requestFileSave(path: String, result: MethodChannel.Result) {
        if (pendingFileSaveResult != null) {
            result.error("save_in_progress", "已有文件保存请求正在处理", null)
            return
        }
        try {
            val source = File(path).canonicalFile
            val downloadDirectory = File(cacheDir, "matter_downloads").canonicalFile
            if (!source.isFile || source.parentFile?.parentFile != downloadDirectory) {
                result.error("invalid_file", "找不到待保存的下载文件", null)
                return
            }
            pendingFileSaveResult = result
            pendingFileSaveSource = source
            startActivityForResult(
                Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/octet-stream"
                    putExtra(Intent.EXTRA_TITLE, source.name)
                },
                FILE_SAVE_REQUEST,
            )
        } catch (error: Exception) {
            pendingFileSaveResult = null
            pendingFileSaveSource = null
            result.error("save_failed", "无法创建保存文件：${error.message}", null)
        }
    }

    private fun finishFileSave(resultCode: Int, data: Intent?) {
        val result = pendingFileSaveResult
        val source = pendingFileSaveSource
        pendingFileSaveResult = null
        pendingFileSaveSource = null
        if (result == null || source == null) return
        val destination = data?.data
        if (resultCode != RESULT_OK || destination == null) {
            result.success(false)
            return
        }
        try {
            contentResolver.openOutputStream(destination)?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("无法打开保存位置")
            result.success(true)
        } catch (error: Exception) {
            result.error("save_failed", "无法保存文件：${error.message}", null)
        }
    }

    private fun launchPackageInstaller(path: String, result: MethodChannel.Result) {
        try {
            val apkFile = File(path).canonicalFile
            val updateDirectory = File(cacheDir, "updates").canonicalFile
            if (!apkFile.isFile || apkFile.parentFile != updateDirectory) {
                result.error("invalid_apk", "找不到已下载的安装包", null)
                return
            }

            val apkUri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                apkFile,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(apkUri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            result.success(null)
        } catch (error: Exception) {
            result.error("install_failed", "无法打开系统安装器：${error.message}", null)
        }
    }

    companion object {
        private const val UPDATE_CHANNEL = "moe.aks.matter/app_update"
        private const val FILE_SAVE_CHANNEL = "moe.aks.matter/file_saver"
        private const val INSTALL_PERMISSION_REQUEST = 4107
        private const val FILE_SAVE_REQUEST = 4108
    }
}
