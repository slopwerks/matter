package moe.aks.matter

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Outline
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.window.BackEvent
import android.window.OnBackAnimationCallback
import android.window.OnBackInvokedDispatcher
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/** Uses only Dart-provided route PNGs; gesture frames never cross the platform channel. */
@RequiresApi(34)
internal class RouteSnapshotBack(
    private val activity: Activity,
    private val commit: (Long, MethodChannel.Result) -> Unit,
    private val decoder: Executor = Executors.newSingleThreadExecutor(),
) {
    private data class Prepared(val front: Bitmap, val back: Bitmap, val x: Float, val y: Float, val width: Int, val height: Int) {
        fun recycle() { front.recycle(); back.recycle() }
    }
    private val main = Handler(Looper.getMainLooper())
    private var generation = -1L
    private var disposed = false
    private var revision = 0L
    private var eligible = false
    private var prepared: Prepared? = null
    private var committing = false
    private var commitDispatched = false
    private var direction = 1f
    private var radius = 0f
    internal var registered = false
        private set
    internal var overlay: FrameLayout? = null
        private set
    internal var foreground: ImageView? = null
        private set
    private val density get() = activity.resources.displayMetrics.density

    internal val callback = object : OnBackAnimationCallback {
        override fun onBackStarted(event: BackEvent) {
            if (!registered || committing) return
            revision++ // A refresh started before this gesture cannot replace its pixels.
            removeOverlay()
            direction = if (event.swipeEdge == BackEvent.EDGE_RIGHT) -1f else 1f
            showOverlay()
        }
        override fun onBackProgressed(event: BackEvent) {
            if (committing || !eligible) return
            val view = foreground ?: return
            val progress = event.progress.coerceIn(0f, 1f)
            view.translationX = direction * 48f * density * progress
            view.scaleX = 1f - .07f * progress
            view.scaleY = view.scaleX
            radius = 28f * density * progress
            view.invalidateOutline()
        }
        override fun onBackCancelled() { if (!committing) removeOverlay() }
        override fun onBackInvoked() {
            if (!registered || committing || !eligible) return
            if (foreground == null) showOverlay() // Non-gesture back still uses the same fenced commit.
            val view = foreground ?: return
            committing = true
            updateRegistration()
            val token = generation
            val distance = (overlay?.width ?: view.width).coerceAtLeast(view.width) + 32f * density
            view.animate().translationX(direction * distance).scaleX(.93f).scaleY(.93f)
                .setDuration(220).setInterpolator(PathInterpolator(.2f, 0f, 0f, 1f))
                .withEndAction {
                    if (disposed || generation != token || !committing) return@withEndAction
                    commitDispatched = true
                    val reply = object : MethodChannel.Result {
                        override fun success(result: Any?) { main.post { if (result != true) failCommit(token) } }
                        override fun error(code: String, message: String?, details: Any?) { main.post { failCommit(token) } }
                        override fun notImplemented() { main.post { failCommit(token) } }
                    }
                    try { commit(token, reply) } catch (_: Exception) { failCommit(token) }
                }.start()
        }
    }

    fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in listOf("prepare", "refresh", "setActive", "clear", "finish")) {
            result.notImplemented()
            return
        }
        val args = call.arguments as? Map<*, *> ?: run { result.success(false); return }
        val tokenValue = args["generation"]
        val token = when (tokenValue) { is Int -> tokenValue.toLong(); is Long -> tokenValue; else -> null }
        if (disposed || token == null || token < 0) { result.success(false); return }
        when (call.method) {
            "prepare" -> prepare(token, args, result)
            "refresh" -> prepare(token, args, result, refresh = true)
            "setActive" -> {
                if (token != generation || args["eligible"] !is Boolean) { result.success(false); return }
                eligible = args["eligible"] == true && prepared != null
                if (!eligible) revision++
                // Once Dart is popping, finish owns lifetime so no unrendered frame leaks through.
                if (!eligible && !commitDispatched) { committing = false; removeOverlay() }
                updateRegistration()
                result.success(eligible == args["eligible"])
            }
            "clear" -> {
                if (token < generation) { result.success(false); return }
                generation = token
                release()
                result.success(true)
            }
            "finish" -> {
                if (token != generation || !committing) { result.success(false); return }
                release()
                result.success(true)
            }
        }
    }

    private fun prepare(token: Long, args: Map<*, *>, result: MethodChannel.Result, refresh: Boolean = false) {
        // Refreshes retain the installed generation, including its commit identity.
        if (refresh) {
            if (token != generation || prepared == null || overlay != null || committing) {
                result.success(false); return
            }
        } else if (token <= generation) { result.success(false); return }
        val front = args["foreground"] as? ByteArray
        val back = args["background"] as? ByteArray
        val rect = listOf("x", "y", "width", "height").map { (args[it] as? Number)?.toDouble() }
        if (front == null || back == null || rect.any { it == null || !it.isFinite() } ||
            rect[2]!! < 1 || rect[3]!! < 1 || rect.any { kotlin.math.abs(it!!) > Int.MAX_VALUE / 2 }) {
            result.success(false); return
        }
        if (refresh) {
            revision++
        } else {
            generation = token
            release()
        }
        val decodeRevision = revision
        decoder.execute {
            var foregroundBitmap: Bitmap? = null
            var backgroundBitmap: Bitmap? = null
            try {
                foregroundBitmap = BitmapFactory.decodeByteArray(front, 0, front.size)
                backgroundBitmap = BitmapFactory.decodeByteArray(back, 0, back.size)
            } catch (_: Exception) {
                // Invalid PNGs cannot enable interception.
            }
            val decodedFront = foregroundBitmap
            val decodedBack = backgroundBitmap
            main.post {
                if (disposed || generation != token || revision != decodeRevision ||
                    (refresh && (overlay != null || committing)) || decodedFront == null || decodedBack == null) {
                    decodedFront?.recycle(); decodedBack?.recycle()
                    result.success(false)
                } else {
                    prepared?.recycle()
                    prepared = Prepared(decodedFront, decodedBack, rect[0]!!.toFloat(), rect[1]!!.toFloat(),
                        rect[2]!!.roundToInt(), rect[3]!!.roundToInt())
                    result.success(true)
                }
            }
        }
    }

    private fun updateRegistration() {
        val enabled = !disposed && eligible && prepared != null
        if (registered == enabled) return
        if (enabled) activity.onBackInvokedDispatcher.registerOnBackInvokedCallback(
            OnBackInvokedDispatcher.PRIORITY_OVERLAY, callback)
        else activity.onBackInvokedDispatcher.unregisterOnBackInvokedCallback(callback)
        registered = enabled
    }

    private fun showOverlay() {
        val snapshots = prepared ?: return
        val content = activity.findViewById<ViewGroup>(android.R.id.content) ?: return
        val layer = FrameLayout(activity).apply {
            isClickable = true // Absorb touches without modifying the live Flutter view's state.
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            clipChildren = false
            clipToPadding = false
        }
        fun image(bitmap: Bitmap) = ImageView(activity).apply {
            scaleType = ImageView.ScaleType.FIT_XY
            setImageBitmap(bitmap)
            layoutParams = FrameLayout.LayoutParams(snapshots.width, snapshots.height).apply {
                leftMargin = snapshots.x.roundToInt(); topMargin = snapshots.y.roundToInt()
            }
        }
        layer.addView(image(snapshots.back))
        radius = 0f
        foreground = image(snapshots.front).apply {
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) {
                    outline.setRoundRect(0, 0, view.width, view.height, radius)
                }
            }
            clipToOutline = true
        }
        layer.addView(foreground)
        overlay = layer
        content.addView(layer, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    private fun removeOverlay() {
        foreground?.animate()?.cancel()
        overlay?.let { layer ->
            (layer.parent as? ViewGroup)?.removeView(layer)
            for (index in 0 until layer.childCount) (layer.getChildAt(index) as? ImageView)?.setImageDrawable(null)
            layer.removeAllViews()
        }
        foreground = null
        overlay = null
    }

    private fun failCommit(token: Long) {
        if (!disposed && generation == token && committing) release()
    }

    private fun release() {
        revision++
        eligible = false
        committing = false
        commitDispatched = false
        updateRegistration()
        removeOverlay() // Clear every drawable reference before recycling its backing bitmap.
        prepared?.recycle()
        prepared = null
    }

    fun dispose() {
        disposed = true
        release()
        // Let queued decode jobs report false and recycle on main; never strand a channel result.
        (decoder as? java.util.concurrent.ExecutorService)?.shutdown()
    }
}
