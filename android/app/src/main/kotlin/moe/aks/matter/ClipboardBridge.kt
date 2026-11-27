package moe.aks.matter

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class ClipboardBridge(activity: Activity, messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, "moe.aks.matter/clipboard").setMethodCallHandler { call, result ->
            if (call.method != "readFiles") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val manager = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val clip = manager.primaryClip
                val uris = (0 until (clip?.itemCount ?: 0)).mapNotNull { clip?.getItemAt(it)?.uri }
                    .filter { it.scheme == "content" || it.scheme == "file" }.distinct()
                executor.execute {
                    try {
                        val resolver = activity.contentResolver
                        var total = 0
                        val files = uris.map { uri ->
                            var name: String? = uri.lastPathSegment
                            if (uri.scheme == "content") resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                                if (cursor.moveToFirst()) {
                                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                                    if (nameIndex >= 0) name = cursor.getString(nameIndex)
                                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                                        require(cursor.getLong(sizeIndex) <= maxBytes - total) { "剪贴板附件超过 64MB 限制" }
                                    }
                                }
                            }
                            val bytes = resolver.openInputStream(uri)?.use { input ->
                                val output = ByteArrayOutputStream()
                                val buffer = ByteArray(8192)
                                while (true) {
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    total += count
                                    require(total <= maxBytes) { "剪贴板附件超过 64MB 限制" }
                                    output.write(buffer, 0, count)
                                }
                                output.toByteArray()
                            } ?: error("无法读取剪贴板文件")
                            mapOf(
                                "name" to (name?.substringAfterLast('/')?.substringAfterLast('\\')
                                    ?.takeIf { it.isNotBlank() } ?: "clipboard_attachment"),
                                "mime" to resolver.getType(uri),
                                "bytes" to bytes,
                            )
                        }
                        activity.runOnUiThread { result.success(files) }
                    } catch (error: Exception) {
                        activity.runOnUiThread { result.error("clipboard_read_failed", error.message, null) }
                    }
                }
            } catch (error: Exception) {
                result.error("clipboard_read_failed", error.message, null)
            }
        }
    }

    companion object {
        private const val maxBytes = 64 * 1024 * 1024
        private val executor = Executors.newSingleThreadExecutor()
    }
}
