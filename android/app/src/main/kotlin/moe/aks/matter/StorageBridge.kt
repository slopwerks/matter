package moe.aks.matter

import android.app.Activity
import android.app.usage.StorageStatsManager
import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.graphics.Bitmap
import java.io.ByteArrayOutputStream
import android.net.Uri
import android.os.Environment
import android.os.Process
import android.os.StatFs
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** Storage accounting runs off the UI thread. The SAF permission belongs to
 * the user-selected download tree and survives process restarts. */
internal class StorageBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private var pendingDirectory: MethodChannel.Result? = null

    init {
        MethodChannel(messenger, "moe.aks.matter/storage").setMethodCallHandler { call, result ->
            when (call.method) {
                "usage" -> {
                    executor.execute {
                        try {
                            val volume = StatFs(activity.filesDir.path)
                            val values =
                                mutableMapOf<String, Any>(
                                    "cacheRoots" to listOfNotNull(activity.cacheDir, activity.externalCacheDir).map { it.path },
                                    "dataRoots" to
                                        listOfNotNull(
                                            File(activity.applicationInfo.dataDir),
                                            activity.getExternalFilesDir(null),
                                        ).map { it.path },
                                    "freeBytes" to volume.availableBytes,
                                    "volumeBytes" to volume.totalBytes,
                                )
                            try {
                                val manager = activity.getSystemService(Context.STORAGE_STATS_SERVICE) as StorageStatsManager
                                val storage = activity.getSystemService(Context.STORAGE_SERVICE) as StorageManager
                                val stats =
                                    manager.queryStatsForPackage(
                                        storage.getUuidForPath(activity.filesDir),
                                        activity.packageName,
                                        Process.myUserHandle(),
                                    )
                                values["dataBytes"] = stats.dataBytes
                                values["cacheBytes"] = stats.cacheBytes
                                values["appBytes"] = stats.appBytes
                            } catch (_: Exception) {
                                // Directory accounting remains available when the
                                // device does not expose per-package statistics.
                            }
                            activity.runOnUiThread { result.success(values) }
                        } catch (error: Exception) {
                            activity.runOnUiThread { result.error("usage_failed", error.message, null) }
                        }
                    }
                }

                "videoThumbnail" -> {
                    val path = call.argument<String>("path")
                    executor.execute {
                        try {
                            val file = File(requireNotNull(path)).canonicalFile
                            val roots = listOfNotNull(File(activity.applicationInfo.dataDir), activity.externalCacheDir, activity.getExternalFilesDir(null))
                            require(file.isFile && roots.any { file.path.startsWith(it.canonicalPath + File.separator) }) { "本地文件不可用" }
                            val retriever = MediaMetadataRetriever()
                            val bytes = try {
                                retriever.setDataSource(file.path)
                                val frame = retriever.getScaledFrameAtTime(-1, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 320, 320)
                                try {
                                    frame?.let { bitmap -> ByteArrayOutputStream().use { output -> bitmap.compress(Bitmap.CompressFormat.JPEG, 82, output); output.toByteArray() } }
                                } finally { frame?.recycle() }
                            } finally { retriever.release() }
                            activity.runOnUiThread { result.success(bytes) }
                        } catch (error: Exception) {
                            activity.runOnUiThread { result.error("thumbnail_failed", "无法读取本地视频封面", null) }
                        }
                    }
                }

                "chooseDirectory" -> {
                    if (pendingDirectory != null) {
                        result.error("picker_busy", "已有目录选择正在进行", null)
                    } else {
                        pendingDirectory = result
                        try {
                            activity.startActivityForResult(
                                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                    addFlags(
                                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
                                    )
                                },
                                DIRECTORY_REQUEST,
                            )
                        } catch (error: Exception) {
                            pendingDirectory = null
                            result.error("picker_failed", error.message, null)
                        }
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    fun onActivityResult(
        request: Int,
        code: Int,
        data: Intent?,
    ): Boolean {
        if (request != DIRECTORY_REQUEST) return false
        val result = pendingDirectory ?: return true
        pendingDirectory = null
        val uri = data?.data
        if (code != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            activity.contentResolver.takePersistableUriPermission(uri, flags)
            result.success(mapOf("path" to uri.toString(), "label" to DocumentsContract.getTreeDocumentId(uri)))
        } catch (error: Exception) {
            result.error("directory_permission", "无法保留目录权限：${error.message}", null)
        }
        return true
    }

    companion object {
        const val DIRECTORY_REQUEST = 4120
        private val executor = Executors.newSingleThreadExecutor()

        fun saveToTree(
            context: Context,
            source: File,
            directory: String,
            mime: String,
        ): Uri {
            val tree = Uri.parse(directory)
            require(tree.scheme == "content" && DocumentsContract.isTreeUri(tree)) { "保存目录无效，请重新选择" }
            val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            val resolver = context.contentResolver
            val target = DocumentsContract.createDocument(resolver, parent, mime, source.name) ?: error("无法创建文件")
            try {
                resolver.openOutputStream(target, "w")?.use { output -> source.inputStream().use { it.copyTo(output) } }
                    ?: error("无法写入保存目录")
                return target
            } catch (error: Exception) {
                DocumentsContract.deleteDocument(resolver, target)
                throw error
            }
        }
    }
}
