package moe.aks.matter

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/** Audio and downloads retain independent leases on the same Flutter engine. */
internal object AudioRuntime {
    private const val AUDIO_LEASE = -1
    private var host = WeakReference<FlutterActivity>(null)
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var retained = false
    var generation: Long = 0
        private set

    fun attachHost(
        activity: FlutterActivity,
        candidate: FlutterEngine,
    ) {
        host = WeakReference(activity)
        engine = candidate
        val application = activity.applicationContext
        channel =
            MethodChannel(candidate.dartExecutor.binaryMessenger, "moe.aks.matter/audio").also { methods ->
                methods.setMethodCallHandler { call, result ->
                    try {
                        when (call.method) {
                            "waveform", "cancelWaveform" -> {
                                AudioWaveformDecoder.handle(call, application, result)
                            }

                            "update" -> {
                                val title = call.argument<String>("title")
                                generation = call.argument<Number>("generation")?.toLong() ?: 0
                                if (title == null) {
                                    application.stopService(Intent(application, AudioPlaybackService::class.java))
                                } else {
                                    retain()
                                    val command =
                                        Intent(application, AudioPlaybackService::class.java).apply {
                                            action = "update"
                                            putExtra("title", title)
                                            putExtra("generation", generation)
                                            putExtra("playing", call.argument<Boolean>("playing") ?: false)
                                            putExtra("loading", call.argument<Boolean>("loading") ?: false)
                                            putExtra("positionMs", call.argument<Number>("positionMs")?.toLong() ?: 0)
                                            putExtra("durationMs", call.argument<Number>("durationMs")?.toLong() ?: 0)
                                            putExtra("speed", call.argument<Number>("speed")?.toFloat() ?: 1f)
                                            putExtra("hasNext", call.argument<Boolean>("hasNext") ?: false)
                                            putExtra("hasPrevious", call.argument<Boolean>("hasPrevious") ?: false)
                                        }
                                    ContextCompat.startForegroundService(application, command)
                                }
                                result.success(null)
                            }

                            "release" -> {
                                if (call.argument<Number>("generation")?.toLong() == generation) release()
                                result.success(null)
                            }

                            "stop" -> {
                                application.stopService(Intent(application, AudioPlaybackService::class.java))
                                release()
                                result.success(null)
                            }

                            else -> {
                                result.notImplemented()
                            }
                        }
                    } catch (error: Exception) {
                        command("pause")
                        result.error("audio_service_failed", "无法启动后台音频播放", null)
                    }
                }
            }
    }

    private fun retain() {
        if (retained) return
        val activity = host.get() ?: error("Audio must start from a visible application")
        val candidate = engine ?: error("No audio engine")
        DownloadRuntime.retain(AUDIO_LEASE, candidate, activity)
        retained = true
        if (Build.VERSION.SDK_INT >= 33 &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4110)
        }
    }

    fun detachHost(activity: FlutterActivity) {
        if (host.get() === activity) host.clear()
    }

    fun command(
        action: String,
        positionMs: Long? = null,
    ) {
        val arguments = mutableMapOf<String, Any>("generation" to generation)
        if (positionMs != null) arguments["positionMs"] = positionMs
        channel?.invokeMethod(action, arguments)
    }

    private fun release() {
        if (!retained) return
        retained = false
        DownloadRuntime.finish(AUDIO_LEASE)
    }
}
