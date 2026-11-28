package moe.aks.matter

import android.app.Activity
import android.view.View
import android.widget.FrameLayout
import android.window.BackEvent
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class HomePredictiveBackTest {
    @Test
    fun progressUsesNativeViewAndResetRestoresIt() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get()
        activity.setContentView(FrameLayout(activity))
        val content = activity.findViewById<View>(android.R.id.content)
        val oldElevation = content.elevation
        val oldClip = content.clipToOutline
        val back = HomePredictiveBack(activity)
        back.callback.onBackStarted(BackEvent(0f, 200f, 0f, BackEvent.EDGE_LEFT))
        back.callback.onBackProgressed(BackEvent(100f, 200f, .5f, BackEvent.EDGE_LEFT))
        assertTrue(content.translationX > 0)
        assertTrue(content.scaleX < 1)
        assertEquals(1f, content.alpha)
        assertTrue(content.clipToOutline)
        back.reset()
        assertEquals(0f, content.translationX)
        assertEquals(1f, content.scaleX)
        assertEquals(oldElevation, content.elevation)
        assertEquals(oldClip, content.clipToOutline)
        controller.pause().stop().destroy()
    }
    @Test
    fun previewTracksFingerProgressWithoutFrontLoadedEasing() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get()
        activity.setContentView(FrameLayout(activity))
        val content = activity.findViewById<View>(android.R.id.content)
        val density = activity.resources.displayMetrics.density
        val back = HomePredictiveBack(activity)
        back.callback.onBackStarted(BackEvent(0f, 200f, 0f, BackEvent.EDGE_LEFT))
        for (progress in listOf(.2f, .5f)) {
            back.callback.onBackProgressed(BackEvent(100f, 200f, progress, BackEvent.EDGE_LEFT))
            val normalized = (progress - .015f) / .985f
            assertEquals(48f * density * normalized, content.translationX, .001f)
            assertEquals(1f - .07f * normalized, content.scaleX, .001f)
        }
        back.reset()
        controller.pause().stop().destroy()
    }

    @Test
    fun rightEdgeMovesInOppositeDirectionAndDisablingRestores() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get()
        activity.setContentView(FrameLayout(activity))
        val content = activity.findViewById<View>(android.R.id.content)
        val back = HomePredictiveBack(activity)
        back.setEnabled(true)
        back.callback.onBackStarted(BackEvent(300f, 200f, 0f, BackEvent.EDGE_RIGHT))
        back.callback.onBackProgressed(BackEvent(100f, 200f, .5f, BackEvent.EDGE_RIGHT))
        assertTrue(content.translationX < 0)
        back.setEnabled(false)
        assertEquals(0f, content.translationX)
        assertEquals(1f, content.scaleX)
        controller.pause().stop().destroy()
    }
}
