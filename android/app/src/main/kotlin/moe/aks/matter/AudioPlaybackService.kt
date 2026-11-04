package moe.aks.matter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.IBinder
import android.os.SystemClock

/** Metadata/control plane only. media_kit in the retained Flutter engine plays audio. */
class AudioPlaybackService : Service() {
    private lateinit var session: MediaSession
    private lateinit var audioManager: AudioManager
    private lateinit var focus: AudioFocusRequest
    private var ownsFocus = false
    private val noisyReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(
                context: Context?,
                intent: Intent?,
            ) {
                AudioRuntime.command("pause")
            }
        }

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "音频播放", NotificationManager.IMPORTANCE_LOW),
        )
        audioManager = getSystemService(AudioManager::class.java)
        focus =
            AudioFocusRequest
                .Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes
                        .Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                ).setOnAudioFocusChangeListener { change ->
                    if (change != AudioManager.AUDIOFOCUS_GAIN) AudioRuntime.command("pause")
                }.build()
        session =
            MediaSession(this, "MatterAudio").apply {
                setCallback(
                    object : MediaSession.Callback() {
                        override fun onPlay() {
                            AudioRuntime.command("play")
                        }

                        override fun onPause() {
                            AudioRuntime.command("pause")
                        }

                        override fun onStop() {
                            AudioRuntime.command("stop")
                        }

                        override fun onSkipToNext() {
                            AudioRuntime.command("next")
                        }

                        override fun onSkipToPrevious() {
                            AudioRuntime.command("previous")
                        }

                        override fun onSeekTo(position: Long) {
                            AudioRuntime.command("seek", position)
                        }

                        override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean = super.onMediaButtonEvent(mediaButtonIntent)
                    },
                )
                isActive = true
            }
        registerReceiver(noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        if (intent?.action != "update") {
            intent?.action?.let { action ->
                if (intent.getLongExtra("generation", -1) == AudioRuntime.generation) {
                    AudioRuntime.command(action)
                    if (action == "stop") stopSelf()
                }
            }
            return START_NOT_STICKY
        }
        val title = intent.getStringExtra("title") ?: return START_NOT_STICKY
        val playing = intent.getBooleanExtra("playing", false)
        val loading = intent.getBooleanExtra("loading", false)
        if (playing && !ownsFocus) {
            ownsFocus = audioManager.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            if (!ownsFocus) AudioRuntime.command("pause")
        } else if (!playing && ownsFocus) {
            audioManager.abandonAudioFocusRequest(focus)
            ownsFocus = false
        }
        val position = intent.getLongExtra("positionMs", 0)
        val duration = intent.getLongExtra("durationMs", 0)
        val speed = intent.getFloatExtra("speed", 1f)
        val hasNext = intent.getBooleanExtra("hasNext", false)
        val hasPrevious = intent.getBooleanExtra("hasPrevious", false)
        session.setMetadata(
            MediaMetadata
                .Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .apply { if (duration > 0) putLong(MediaMetadata.METADATA_KEY_DURATION, duration) }
                .build(),
        )
        val actions =
            PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP or
                (if (duration > 0) PlaybackState.ACTION_SEEK_TO else 0L) or
                (if (hasNext) PlaybackState.ACTION_SKIP_TO_NEXT else 0L) or
                (if (hasPrevious) PlaybackState.ACTION_SKIP_TO_PREVIOUS else 0L)
        session.setPlaybackState(
            PlaybackState
                .Builder()
                .setActions(actions)
                .setState(
                    if (loading) {
                        PlaybackState.STATE_BUFFERING
                    } else if (playing) {
                        PlaybackState.STATE_PLAYING
                    } else {
                        PlaybackState.STATE_PAUSED
                    },
                    position,
                    if (playing) speed else 0f,
                    SystemClock.elapsedRealtime(),
                ).build(),
        )
        val openApp =
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        val notification =
            Notification
                .Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(if (loading) "正在加载…" else "音频播放")
                .setContentIntent(openApp)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0, 1, 2))
                .addAction(Notification.Action.Builder(android.R.drawable.ic_media_previous, "上一首", action("previous", 1)).build())
                .addAction(
                    Notification.Action
                        .Builder(
                            if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                            if (playing) "暂停" else "播放",
                            action(if (playing) "pause" else "play", 2),
                        ).build(),
                ).addAction(Notification.Action.Builder(android.R.drawable.ic_media_next, "下一首", action("next", 3)).build())
                .addAction(Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel, "停止", action("stop", 4)).build())
                .setDeleteIntent(action("stop", 5))
                .build()
        // Keep the media service foreground while paused so lock-screen resume
        // never tries an Android 12+ background foreground-service restart.
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        return START_NOT_STICKY
    }

    private fun action(
        name: String,
        request: Int,
    ): PendingIntent =
        PendingIntent.getService(
            this,
            request,
            Intent(this, AudioPlaybackService::class.java)
                .setAction(name)
                .putExtra("generation", AudioRuntime.generation),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    override fun onTaskRemoved(rootIntent: Intent?) {
        AudioRuntime.command("stop")
        stopSelf()
    }

    override fun onDestroy() {
        if (ownsFocus) audioManager.abandonAudioFocusRequest(focus)
        unregisterReceiver(noisyReceiver)
        session.release()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val CHANNEL = "matter_audio_playback"
        private const val NOTIFICATION_ID = 8401
    }
}
