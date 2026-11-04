package moe.aks.matter

import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.FlutterJNI
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.platform.PlatformViewsController
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadow.api.Shadow

@Implements(FlutterEngine::class)
class ShadowDownloadEngine {
    var destroyed = false

    @Implementation
    fun __constructor__(
        context: Context,
        loader: FlutterLoader?,
        jni: FlutterJNI?,
        platformViews: PlatformViewsController?,
        arguments: Array<String>?,
        registerPlugins: Boolean,
        waitForRestoration: Boolean,
        group: FlutterEngineGroup?,
    ) {}

    @Implementation
    fun destroy() {
        destroyed = true
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(
    sdk = [33],
    application = Application::class,
    manifest = Config.NONE,
    shadows = [ShadowDownloadEngine::class],
    instrumentedPackages = ["io.flutter.embedding.engine"],
)
class DownloadRuntimeTest {
    private fun engine() = FlutterEngine(RuntimeEnvironment.getApplication())

    private fun destroyed(engine: FlutterEngine): Boolean = Shadow.extract<ShadowDownloadEngine>(engine).destroyed

    @After
    fun release() {
        DownloadRuntime.release()
    }

    @Test
    fun keepsTheDetachedEngineUntilEveryTransferFinishes() {
        val engine = engine()
        val host = FlutterActivity()
        DownloadRuntime.retain(101, engine, host)
        DownloadRuntime.retain(102, engine, host)
        DownloadRuntime.detachHost(host)
        DownloadRuntime.finish(101)
        assertSame(engine, DownloadRuntime.engine)
        assertFalse(destroyed(engine))
        DownloadRuntime.finish(102)
        assertNull(DownloadRuntime.engine)
        assertTrue(destroyed(engine))
    }

    @Test
    fun completingAudioKeepsADownloadAlive() {
        val engine = engine()
        val host = FlutterActivity()
        DownloadRuntime.retain(101, engine, host)
        DownloadRuntime.retain(-1, engine, host)
        DownloadRuntime.detachHost(host)
        DownloadRuntime.finish(-1)
        assertSame(engine, DownloadRuntime.engine)
        assertFalse(destroyed(engine))
        DownloadRuntime.finish(101)
        assertTrue(destroyed(engine))
    }

    @Test
    fun completingADownloadKeepsAudioAlive() {
        val engine = engine()
        val host = FlutterActivity()
        DownloadRuntime.retain(101, engine, host)
        DownloadRuntime.retain(-1, engine, host)
        DownloadRuntime.detachHost(host)
        DownloadRuntime.finish(101)
        assertSame(engine, DownloadRuntime.engine)
        assertFalse(destroyed(engine))
        DownloadRuntime.finish(-1)
        assertTrue(destroyed(engine))
    }

    @Test
    fun completionLeavesAnAttachedEngineForTheHostToDestroy() {
        val engine = engine()
        DownloadRuntime.retain(101, engine, FlutterActivity())
        DownloadRuntime.finish(101)
        assertNull(DownloadRuntime.engine)
        assertFalse(destroyed(engine))
    }

    @Test
    fun lateDestructionOfTheOldHostDoesNotDetachTheNewHost() {
        val engine = engine()
        val oldHost = FlutterActivity()
        DownloadRuntime.retain(101, engine, oldHost)
        DownloadRuntime.detachHost(oldHost)
        DownloadRuntime.attachHost(FlutterActivity(), engine)
        DownloadRuntime.detachHost(oldHost)
        DownloadRuntime.finish(101)
        assertNull(DownloadRuntime.engine)
        assertFalse(destroyed(engine))
    }

    @Test
    fun aReturningActivityReusesTheDownloadingEngine() {
        val engine = engine()
        val oldHost = FlutterActivity()
        DownloadRuntime.retain(101, engine, oldHost)
        DownloadRuntime.detachHost(oldHost)
        assertSame(engine, MainActivity().provideFlutterEngine(RuntimeEnvironment.getApplication()))
    }

    @Test
    fun serviceCompletionReleasesTheDetachedEngine() {
        val engine = engine()
        val host = FlutterActivity()
        DownloadRuntime.retain(101, engine, host)
        DownloadRuntime.detachHost(host)
        val controller = Robolectric.buildService(DownloadService::class.java).create()
        val service = controller.get()
        service.onStartCommand(Intent().setAction("start").putExtra("id", 101), 0, 1)
        service.onStartCommand(Intent().setAction("finish").putExtra("id", 101).putExtra("status", "complete"), 0, 2)
        assertNull(DownloadRuntime.engine)
        assertTrue(destroyed(engine))
        controller.destroy()
    }

    @Test
    fun serviceTimeoutReleasesTheDetachedEngine() {
        val engine = engine()
        val host = FlutterActivity()
        DownloadRuntime.retain(101, engine, host)
        DownloadRuntime.detachHost(host)
        val controller = Robolectric.buildService(DownloadService::class.java).create()
        val service = controller.get()
        service.onStartCommand(Intent().setAction("start").putExtra("id", 101), 0, 1)
        service.onTimeout(1, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        assertNull(DownloadRuntime.engine)
        assertTrue(destroyed(engine))
        controller.destroy()
    }
}
