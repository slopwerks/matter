package moe.aks.matter

import android.app.Activity
import android.graphics.Color
import android.graphics.Outline
import android.os.Build
import android.view.View
import android.view.ViewOutlineProvider
import android.view.animation.DecelerateInterpolator
import android.view.animation.PathInterpolator
import android.window.BackEvent
import android.window.OnBackAnimationCallback
import android.window.OnBackInvokedDispatcher
import androidx.annotation.RequiresApi

/** Root-only View animation matching ProcessManager's predictive home return. */
@RequiresApi(34)
internal class HomePredictiveBack(private val activity: Activity) {
    private var registered = false
    private var foreground: View? = null
    private var direction = 1f
    private var radius = 0f
    private var invoked = false
    private var oldElevation = 0f
    private var oldTranslationZ = 0f
    private var oldAmbient = Color.BLACK
    private var oldSpot = Color.BLACK
    private var oldOutline: ViewOutlineProvider? = null
    private var oldClip = false
    private val density get() = activity.resources.displayMetrics.density
    private val outline = object : ViewOutlineProvider() {
        override fun getOutline(view: View, result: Outline) {
            result.setRoundRect(0, 0, view.width, view.height, radius)
        }
    }
    internal val callback = object : OnBackAnimationCallback {
        override fun onBackStarted(event: BackEvent) {
            reset()
            invoked = false
            direction = if (event.swipeEdge == BackEvent.EDGE_RIGHT) -1f else 1f
        }
        override fun onBackProgressed(event: BackEvent) {
            if (invoked) return
            val progress = event.progress.coerceIn(0f, 1f)
            if (foreground == null && progress > .015f) prepare()
            val view = foreground ?: return
            val normalized = ((progress - .015f) / .985f).coerceIn(0f, 1f)
            view.translationX = direction * 48f * density * normalized
            view.scaleX = 1f - .07f * normalized
            view.scaleY = view.scaleX
            radius = 28f * density * normalized
            view.invalidateOutline()
        }
        override fun onBackCancelled() {
            val view = foreground ?: return
            view.animate().translationX(0f).scaleX(1f).scaleY(1f)
                .setDuration(220).setInterpolator(DecelerateInterpolator())
                .withEndAction { reset() }.start()
        }
        override fun onBackInvoked() {
            if (invoked) return
            invoked = true
            val view = foreground
            if (view == null) {
                activity.finish()
                return
            }
            val distance = maxOf(view.width, activity.resources.displayMetrics.widthPixels) + 32f * density
            view.animate().translationX(direction * distance).scaleX(.93f).scaleY(.93f)
                .setDuration(220).setInterpolator(PathInterpolator(.2f, 0f, 0f, 1f))
                .withEndAction {
                    // Do not reset before finish: that flashes a fullscreen frame.
                    activity.finish()
                    foreground = null
                }.start()
        }
    }

    fun setEnabled(enabled: Boolean) {
        if (enabled == registered) return
        if (enabled) {
            activity.onBackInvokedDispatcher.registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback)
        } else {
            activity.onBackInvokedDispatcher.unregisterOnBackInvokedCallback(callback)
            reset()
        }
        registered = enabled
    }

    private fun prepare() {
        val view = activity.findViewById<View>(android.R.id.content) ?: return
        foreground = view
        view.animate().cancel()
        oldElevation = view.elevation
        oldTranslationZ = view.translationZ
        oldAmbient = view.outlineAmbientShadowColor
        oldSpot = view.outlineSpotShadowColor
        oldOutline = view.outlineProvider
        oldClip = view.clipToOutline
        view.elevation = 18f * density
        view.translationZ = 5f * density
        view.outlineAmbientShadowColor = Color.argb(220, 0, 0, 0)
        view.outlineSpotShadowColor = Color.argb(220, 0, 0, 0)
        radius = 2f * density
        view.outlineProvider = outline
        view.clipToOutline = true
    }

    fun reset() {
        val view = foreground ?: return
        view.animate().cancel()
        view.translationX = 0f
        view.scaleX = 1f
        view.scaleY = 1f
        view.elevation = oldElevation
        view.translationZ = oldTranslationZ
        view.outlineAmbientShadowColor = oldAmbient
        view.outlineSpotShadowColor = oldSpot
        view.outlineProvider = oldOutline
        view.clipToOutline = oldClip
        foreground = null
    }

    fun dispose() {
        setEnabled(false)
        reset()
    }
}
