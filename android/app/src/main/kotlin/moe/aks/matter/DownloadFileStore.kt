package moe.aks.matter

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.net.URLConnection

internal object DownloadFileStore {
    fun updateApk(
        context: Context,
        path: String,
    ): File {
        val source = File(path).canonicalFile
        val updates = File(context.cacheDir, "updates").canonicalFile
        require(source.isFile && source.parentFile == updates && source.extension == "apk") {
            "找不到已下载的安装包"
        }
        return source
    }

    fun saveUpdate(
        context: Context,
        path: String,
    ): Uri = publish(context, updateApk(context, path), "application/vnd.android.package-archive")

    fun save(
        context: Context,
        path: String,
        directory: String? = null,
    ): Uri {
        val source = File(path).canonicalFile
        val stagingDirectory = File(context.cacheDir, "matter_downloads").canonicalFile
        require(source.isFile && source.parentFile?.parentFile == stagingDirectory) {
            "找不到待保存的下载文件"
        }
        val mime = URLConnection.guessContentTypeFromName(source.name) ?: "application/octet-stream"
        return if (directory == null) publish(context, source, mime) else StorageBridge.saveToTree(context, source, directory, mime)
    }

    private fun publish(
        context: Context,
        source: File,
        mimeType: String,
    ): Uri {
        val values =
            ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, source.name)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
        val resolver = context.contentResolver
        val destination =
            resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: error("无法创建下载文件")
        try {
            resolver.openOutputStream(destination)?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            } ?: error("无法打开下载目录")
            resolver.update(
                destination,
                ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                },
                null,
                null,
            )
            return destination
        } catch (error: Exception) {
            resolver.delete(destination, null, null)
            throw error
        }
    }
}
