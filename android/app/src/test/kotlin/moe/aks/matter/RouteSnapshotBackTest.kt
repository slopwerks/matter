package moe.aks.matter

import android.app.Activity
import android.graphics.Bitmap
import android.os.Looper
import android.view.View
import android.widget.FrameLayout
import android.window.BackEvent
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.time.Duration
import java.util.concurrent.Executor
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class RouteSnapshotBackTest {
    private class Reply : MethodChannel.Result {
        var value: Any? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { fail(message) }
        override fun notImplemented() { fail("Unexpected unknown method") }
    }
    private class Fixture(queued: Boolean = false) {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get().apply { setContentView(FrameLayout(this)) }
        val content = activity.findViewById<FrameLayout>(android.R.id.content)
        val tasks = mutableListOf<Runnable>()
        var commits = 0
        var committedGeneration: Long? = null
        var commitReply: MethodChannel.Result? = null
        val frames = mutableListOf<RouteSnapshotBack.Frame?>()
        val captureFailures = mutableListOf<Long>()
        val back = RouteSnapshotBack(activity, { generation, result ->
            commits++; committedGeneration = generation; commitReply = result
        }, Executor { if (queued) tasks.add(it) else it.run() },
            frameGetter = { if (frames.isEmpty()) null else frames.removeAt(0) },
            onCaptureFailed = { captureFailures.add(it) })
        init { content.layout(0, 0, 400, 800) }
        fun call(method: String, generation: Int, extra: Map<String, Any> = emptyMap()): Reply {
            val reply = Reply()
            back.handleCall(MethodCall(method, extra + ("generation" to generation)), reply)
            shadowOf(Looper.getMainLooper()).idle()
            return reply
        }
        fun capture(): Long? {
            val reply = Reply()
            back.handleCall(MethodCall("captureBackground", null), reply)
            return reply.value as? Long
        }
        fun arm(generation: Int, backgroundToken: Long) = call("arm", generation,
            mapOf("backgroundToken" to backgroundToken))
        fun frame(x: Int = 8, y: Int = 16): RouteSnapshotBack.Frame =
            RouteSnapshotBack.Frame(Bitmap.createBitmap(40, 60, Bitmap.Config.ARGB_8888), x, y, 200, 300)
        fun prepare(generation: Int) = call("prepare", generation, pngArgs())
        fun activate(generation: Int) = call("setActive", generation, mapOf("eligible" to true))
        fun start(edge: Int = BackEvent.EDGE_LEFT) {
            back.callback.onBackStarted(BackEvent(0f, 100f, 0f, edge))
            content.measure(View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY))
            content.layout(0, 0, 400, 800)
        }
        fun close() { back.dispose(); controller.pause().stop().destroy() }
    }

    @Test fun captureAndArmAreSynchronousAndNeverQueueDecode() {
        val f = Fixture(queued = true)
        val background = f.frame()
        f.frames.add(background)
        val token = f.capture()!!
        assertEquals(true, f.arm(7, token).value)
        assertTrue(f.back.registered)
        assertNull(f.back.foreground)
        assertNull(f.back.overlay)
        assertTrue(f.tasks.isEmpty())
        assertFalse(background.bitmap.isRecycled)
        f.close()
        assertTrue(background.bitmap.isRecycled)
    }

    @Test fun armedGestureCapturesFreshForegroundAndCancelThenCommitRetainsToken() {
        val f = Fixture(queued = true)
        val background = f.frame()
        val first = f.frame(20, 30)
        val second = f.frame(24, 36)
        f.frames.addAll(listOf(background, first, second))
        val token = f.capture()!!
        f.arm(9, token)
        f.start()
        val front = f.back.foreground!!
        assertSame(first.bitmap, (front.drawable as android.graphics.drawable.BitmapDrawable).bitmap)
        assertEquals(20, (front.layoutParams as FrameLayout.LayoutParams).leftMargin)
        f.back.callback.onBackProgressed(BackEvent(0f, 100f, .5f, BackEvent.EDGE_LEFT))
        assertEquals(24f * f.activity.resources.displayMetrics.density, front.translationX, .001f)
        f.back.callback.onBackCancelled()
        assertNull(front.drawable)
        assertTrue(first.bitmap.isRecycled)
        assertFalse(background.bitmap.isRecycled)
        assertTrue(f.back.registered)
        f.start(BackEvent.EDGE_RIGHT)
        assertSame(second.bitmap, (f.back.foreground!!.drawable as android.graphics.drawable.BitmapDrawable).bitmap)
        f.back.callback.onBackInvoked()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(500))
        assertEquals(1, f.commits)
        assertEquals(9L, f.committedGeneration)
        assertEquals(false, f.call("finish", 8).value)
        assertEquals(true, f.call("finish", 9).value)
        assertTrue(background.bitmap.isRecycled)
        assertTrue(second.bitmap.isRecycled)
        assertTrue(f.tasks.isEmpty())
        f.close() // Repeated cleanup cannot recycle an owned bitmap twice.
    }

    @Test fun invokedWithoutStartCapturesForegroundAndMissingFrameNeverCommits() {
        val f = Fixture()
        val background = f.frame()
        f.frames.add(background)
        f.arm(1, f.capture()!!)
        f.back.callback.onBackInvoked()
        assertTrue(f.back.captureFailed)
        assertEquals(listOf(1L), f.captureFailures)
        assertNull(f.back.overlay)
        assertEquals(0, f.commits)
        assertFalse(background.bitmap.isRecycled)
        val front = f.frame()
        f.frames.add(front)
        f.back.callback.onBackInvoked()
        assertFalse(f.back.captureFailed)
        assertNotNull(f.back.foreground)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(500))
        assertEquals(1L, f.committedGeneration)
        f.close()
        assertTrue(front.bitmap.isRecycled)
        assertTrue(background.bitmap.isRecycled)
    }

    @Test fun staleBackgroundTokensAndGenerationsCannotReplaceArmedRoute() {
        val f = Fixture(queued = true)
        val old = f.frame()
        val current = f.frame()
        f.frames.addAll(listOf(old, current))
        val stale = f.capture()!!
        val valid = f.capture()!!
        assertTrue(valid > stale)
        assertTrue(old.bitmap.isRecycled)
        assertEquals(false, f.arm(1, stale).value)
        assertEquals(true, f.arm(2, valid).value)
        assertEquals(false, f.arm(3, valid).value) // A transferred token is single-use.
        val pending = f.frame()
        f.frames.add(pending)
        val next = f.capture()!!
        assertEquals(false, f.arm(2, next).value)
        assertEquals(false, f.call("clear", 1).value)
        assertFalse(pending.bitmap.isRecycled)
        assertEquals(true, f.call("clear", 2).value)
        assertTrue(current.bitmap.isRecycled)
        assertTrue(pending.bitmap.isRecycled)
        assertEquals(false, f.arm(3, next).value)
        f.close()
    }

    @Test fun captureFailureInvalidatesPendingAndDisposeReleasesPendingFrames() {
        val f = Fixture()
        val old = f.frame()
        f.frames.add(old)
        val token = f.capture()!!
        assertNull(f.capture())
        assertTrue(old.bitmap.isRecycled)
        assertEquals(false, f.arm(1, token).value)
        val pending = f.frame()
        f.frames.add(pending)
        f.capture()
        f.back.dispose()
        assertTrue(pending.bitmap.isRecycled)
        assertNull(f.capture())
        assertFalse(f.back.registered)
        f.close()
    }

    @Test fun refreshAndNewPrepareRetireArmedFramesWithoutRecyclingTwice() {
        val f = Fixture(queued = true)
        val background = f.frame()
        val front = f.frame()
        f.frames.addAll(listOf(background, front))
        f.arm(1, f.capture()!!)
        f.start(); f.back.callback.onBackCancelled()
        val refresh = f.call("refresh", 1, pngArgs())
        f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(true, refresh.value)
        assertTrue(background.bitmap.isRecycled)
        assertTrue(front.bitmap.isRecycled)
        assertTrue(f.back.registered)
        val pending = f.frame()
        f.frames.add(pending)
        f.capture()
        f.prepare(2)
        assertTrue(pending.bitmap.isRecycled)
        f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        f.close()
    }

    @Test fun armedCoverDiscardsOnlyForegroundAndRejectsInFlightRefresh() {
        val f = Fixture(queued = true)
        val background = f.frame()
        val front = f.frame()
        f.frames.addAll(listOf(background, front))
        f.arm(4, f.capture()!!)
        val refresh = f.call("refresh", 4, pngArgs())
        f.start()
        assertEquals(true, f.call("setActive", 4, mapOf("eligible" to false)).value)
        assertNull(f.back.overlay)
        assertTrue(front.bitmap.isRecycled)
        assertFalse(background.bitmap.isRecycled)
        assertFalse(f.back.registered)
        f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(false, refresh.value)
        assertEquals(true, f.activate(4).value)
        f.start() // No fresh foreground is available: keep the live route and report failure.
        assertTrue(f.back.captureFailed)
        assertEquals(listOf(4L), f.captureFailures)
        assertNull(f.back.overlay)
        f.back.callback.onBackCancelled()
        f.close()
        assertTrue(background.bitmap.isRecycled)
    }

    @Test fun installedBackgroundCannotBeReusedAsFakeForegroundOrRecycledByCapture() {
        val f = Fixture()
        val background = f.frame()
        f.frames.add(background)
        f.arm(1, f.capture()!!)
        f.frames.add(background) // A broken injected getter must not corrupt installed ownership.
        f.start()
        assertTrue(f.back.captureFailed)
        assertFalse(background.bitmap.isRecycled)
        assertNull(f.back.foreground)
        assertEquals(0, f.commits)
        f.close()
        assertTrue(background.bitmap.isRecycled)
    }

    @Test fun refreshingReadySnapshotsKeepsNativeBackRegistered() {
        val f = Fixture(queued = true)
        f.prepare(1)
        f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        f.activate(1)
        val refresh = f.call("refresh", 1, pngArgs())
        assertTrue("Refreshing an eligible route must not expose Flutter fallback", f.back.registered)
        f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(true, refresh.value)
        f.close()
    }

    @Test fun refreshCompletingDuringGestureRetainsInstalledPixelsAndCommitToken() {
        val f = Fixture(queued = true)
        f.prepare(1); f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        f.activate(1)
        val refresh = f.call("refresh", 1, pngArgs())
        f.start()
        val front = f.back.foreground!!
        val drawable = front.drawable
        f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(false, refresh.value)
        assertSame(front, f.back.foreground)
        assertSame(drawable, front.drawable)
        assertTrue(f.back.registered)
        assertEquals(false, f.call("refresh", 1, pngArgs()).value)
        f.back.callback.onBackInvoked()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(500))
        assertEquals(1L, f.committedGeneration)
        assertEquals(false, f.call("refresh", 1, pngArgs()).value)
        f.close()
    }

    @Test fun cancelledGestureAndClearInvalidatePendingRefresh() {
        val f = Fixture(queued = true)
        f.prepare(1); f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        f.activate(1)
        val refresh = f.call("refresh", 1, pngArgs())
        f.start(); f.back.callback.onBackCancelled()
        f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(false, refresh.value)
        assertTrue(f.back.registered)
        val cleared = f.call("refresh", 1, pngArgs())
        f.call("clear", 1)
        f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(false, cleared.value)
        assertFalse(f.back.registered)
        f.close()
    }

    @Test fun failedRefreshKeepsUsableSnapshotsAndCoverDisablesThem() {
        val f = Fixture(queued = true)
        f.prepare(1); f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        f.activate(1)
        val invalid = f.call("refresh", 1, pngArgs() + ("foreground" to byteArrayOf(1, 2)))
        f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(false, invalid.value)
        assertTrue(f.back.registered)
        val covered = f.call("refresh", 1, pngArgs())
        f.call("setActive", 1, mapOf("eligible" to false))
        f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(false, covered.value)
        assertFalse(f.back.registered)
        assertEquals(true, f.activate(1).value)
        f.start()
        assertNotNull(f.back.foreground)
        f.close()
    }

    @Test fun onlyReadyEligibleGenerationIntercepts() {
        val f = Fixture()
        assertEquals(false, f.activate(1).value)
        assertFalse(f.back.registered)
        assertEquals(true, f.prepare(1).value)
        assertFalse(f.back.registered)
        assertEquals(true, f.activate(1).value)
        assertTrue(f.back.registered)
        assertEquals(false, f.call("clear", 0).value)
        assertEquals(false, f.call("setActive", 0, mapOf("eligible" to false)).value)
        assertTrue(f.back.registered)
        assertEquals(true, f.call("clear", 1).value)
        assertFalse(f.back.registered)
        assertEquals(false, f.prepare(1).value)
        f.close()
    }

    @Test fun progressIsLinearAndCancelRetainsReusableSnapshotsWithoutChangingLiveView() {
        val f = Fixture()
        f.prepare(1); f.activate(1); f.start()
        val density = f.activity.resources.displayMetrics.density
        val front = f.back.foreground!!
        assertEquals(12, (front.layoutParams as FrameLayout.LayoutParams).leftMargin)
        assertEquals(24, (front.layoutParams as FrameLayout.LayoutParams).topMargin)
        for (progress in listOf(.2f, .5f, 1f)) {
            f.back.callback.onBackProgressed(BackEvent(0f, 100f, progress, BackEvent.EDGE_LEFT))
            assertEquals(48f * density * progress, front.translationX, .001f)
            assertEquals(1f - .07f * progress, front.scaleX, .001f)
        }
        assertEquals(1f, f.content.scaleX, 0f)
        assertEquals(1f, f.content.alpha, 0f)
        assertEquals(0f, f.back.overlay!!.getChildAt(0).translationX, 0f)
        f.back.callback.onBackCancelled()
        assertNull(f.back.overlay)
        assertNull(front.drawable)
        assertTrue(f.back.registered)
        f.start(BackEvent.EDGE_RIGHT)
        f.back.callback.onBackProgressed(BackEvent(0f, 100f, .5f, BackEvent.EDGE_RIGHT))
        assertEquals(-24f * density, f.back.foreground!!.translationX, .001f)
        f.call("setActive", 1, mapOf("eligible" to false))
        assertNull(f.back.overlay)
        assertFalse(f.back.registered)
        f.back.callback.onBackInvoked()
        assertEquals(0, f.commits)
        assertFalse(f.activity.isFinishing)
        f.close()
    }

    @Test fun pendingDecodeIsFencedByClearAndNewGeneration() {
        val f = Fixture(queued = true)
        val first = f.prepare(1)
        f.call("clear", 1)
        f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(false, first.value)
        assertEquals(false, f.activate(1).value)
        val second = f.prepare(2)
        val third = f.prepare(3)
        f.tasks.removeAt(0).run(); f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(false, second.value)
        assertEquals(true, third.value)
        f.close()
    }

    @Test fun invalidDecodeAndDisposedDecodeNeverEnable() {
        val f = Fixture(queued = true)
        val invalid = f.call("prepare", 1, pngArgs() + ("foreground" to byteArrayOf(1, 2)))
        f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(false, invalid.value)
        assertEquals(false, f.activate(1).value)
        val pending = f.prepare(2)
        f.back.dispose()
        f.tasks.removeAt(0).run()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(false, pending.value)
        assertFalse(f.back.registered)
        f.close()
    }

    @Test fun commitFailureCleansUpWithoutNativeNavigation() {
        val f = Fixture()
        f.prepare(1); f.activate(1); f.start()
        f.back.callback.onBackInvoked()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(500))
        assertEquals(1, f.commits)
        assertEquals(1L, f.committedGeneration)
        assertNotNull(f.back.overlay)
        f.commitReply!!.success(false)
        shadowOf(Looper.getMainLooper()).idle()
        assertNull(f.back.overlay)
        assertFalse(f.back.registered)
        assertFalse(f.activity.isFinishing)
        f.close()
    }

    @Test fun successfulCommitWaitsForMatchingFinishAndIgnoresOldReply() {
        val f = Fixture()
        f.prepare(1); f.activate(1); f.start()
        f.back.callback.onBackInvoked()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(500))
        val oldReply = f.commitReply!!
        oldReply.success(true)
        shadowOf(Looper.getMainLooper()).idle()
        assertNotNull(f.back.overlay)
        assertEquals(false, f.call("finish", 0).value)
        assertNotNull(f.back.overlay)
        assertEquals(true, f.call("finish", 1).value)
        assertNull(f.back.overlay)
        assertFalse(f.back.registered)
        f.prepare(2); f.activate(2); f.start()
        oldReply.success(false)
        shadowOf(Looper.getMainLooper()).idle()
        assertNotNull(f.back.overlay)
        assertTrue(f.back.registered)
        f.close()
    }

    companion object {
        private fun pngArgs(): Map<String, Any> {
            val bitmap = Bitmap.createBitmap(20, 30, Bitmap.Config.ARGB_8888)
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            bitmap.recycle()
            return mapOf("foreground" to stream.toByteArray(), "background" to stream.toByteArray(),
                "x" to 12.0, "y" to 24.0, "width" to 200.0, "height" to 300.0)
        }
    }
}
