package dev.manuxdev.cauce

import android.app.Activity
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
import android.database.ContentObserver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaRouter2
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.media.app.NotificationCompat.MediaStyle
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.URL
import kotlin.concurrent.thread

/// Android's side of `cauce/now_playing`, as the iOS app's NowPlaying: the media session and its
/// notification, the audio focus, the phone's volume and output, and their buttons back to Dart.
class NowPlaying(private val activity: Activity, messenger: BinaryMessenger) {
    private val context: Context = activity.applicationContext
    private val channel = MethodChannel(messenger, "cauce/now_playing")
    private val audio = context.getSystemService(AudioManager::class.java)
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val session = MediaSessionCompat(context, "Cauce")
    private var metadata: MediaMetadataCompat? = null
    private var playing = false
    private var artworkUrl: String? = null
    private var artwork: Bitmap? = null
    private var volume = -1f

    private val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build(),
        )
        .setOnAudioFocusChangeListener { change ->
            // A call or another player took the sound; ducking is left to the system.
            if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                send("pause")
            }
        }
        .build()

    init {
        current = this
        session.setCallback(object : MediaSessionCompat.Callback() {
            override fun onPlay() = send("play")
            override fun onPause() = send("pause")
            override fun onSkipToNext() = send("next")
            override fun onSkipToPrevious() = send("previous")
            override fun onSeekTo(position: Long) = send("seek", position / 1000.0)
        })
        session.setSessionActivity(
            PendingIntent.getActivity(
                context,
                0,
                context.packageManager.getLaunchIntentForPackage(context.packageName),
                PendingIntent.FLAG_IMMUTABLE,
            ),
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    @Suppress("UNCHECKED_CAST")
                    update(call.arguments as Map<String, Any?>)
                    result.success(null)
                }
                // Asked before every play. The output never needs opening again on Android.
                "claim" -> {
                    audio.requestAudioFocus(focus)
                    result.success(false)
                }
                "clear" -> {
                    clear()
                    result.success(null)
                }
                "volume" -> {
                    val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    val fraction = (call.arguments as Double).coerceIn(0.0, 1.0)
                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, Math.round(fraction * max).toInt(), 0)
                    result.success(null)
                }
                "output" -> {
                    sendOutput()
                    result.success(null)
                }
                "pickOutput" -> {
                    pickOutput()
                    result.success(null)
                }
                // Asked once Dart listens, as no callback comes while there is no network.
                "online" -> {
                    sendOnline()
                    result.success(null)
                }
                else -> result.success(null)
            }
        }
        // Headphones pulled out: pause rather than play out loud.
        ContextCompat.registerReceiver(
            context,
            object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) = send("pause")
            },
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        context.contentResolver.registerContentObserver(
            Settings.System.CONTENT_URI,
            true,
            object : ContentObserver(main) {
                override fun onChange(selfChange: Boolean) = sendVolume()
            },
        )
        // Whether the phone reaches the network, as the iOS app's path monitor says.
        connectivity.registerDefaultNetworkCallback(
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = send("online", true)
                override fun onLost(network: Network) = sendOnline()
            },
        )
        audio.registerAudioDeviceCallback(
            object : AudioDeviceCallback() {
                override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = sendOutput()
                override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = sendOutput()
            },
            main,
        )
    }

    private fun update(track: Map<String, Any?>) {
        playing = track["playing"] == true
        val url = track["artwork"] as String?
        if (url != artworkUrl) {
            artworkUrl = url
            artwork = null
            if (url != null) fetchArtwork(url)
        }
        metadata = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, track["title"] as String?)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, track["artist"] as String?)
            .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, track["album"] as String?)
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, millis(track["duration"]))
            .putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, artwork)
            .build()
        session.setMetadata(metadata)
        session.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_PLAY_PAUSE or PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                        PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or PlaybackStateCompat.ACTION_SEEK_TO,
                )
                .setState(
                    if (playing) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                    millis(track["position"]),
                    if (playing) 1f else 0f,
                    SystemClock.elapsedRealtime(),
                )
                .build(),
        )
        session.isActive = true
        show()
    }

    /// The cover, fetched off the main thread and small enough for the notification.
    private fun fetchArtwork(url: String) {
        thread {
            val bitmap = runCatching {
                URL(url).openStream().use { BitmapFactory.decodeStream(it) }
                    ?.let { Bitmap.createScaledBitmap(it, 512, 512, true) }
            }.getOrNull() ?: return@thread
            main.post {
                if (url != artworkUrl) return@post
                artwork = bitmap
                metadata = metadata?.let {
                    MediaMetadataCompat.Builder(it).putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, bitmap).build()
                }
                session.setMetadata(metadata)
                show()
            }
        }
    }

    private fun show() {
        val description = metadata?.description ?: return
        createChannel(context, PLAYBACK_CHANNEL, NotificationManager.IMPORTANCE_LOW)
        val notification = NotificationCompat.Builder(context, PLAYBACK_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(description.title)
            .setContentText(description.subtitle)
            .setLargeIcon(artwork)
            .setContentIntent(session.controller.sessionActivity)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(playing)
            .setSilent(true)
            .addAction(R.drawable.ic_previous, "Previous", PlaybackService.action(context, "previous"))
            .addAction(
                if (playing) R.drawable.ic_pause else R.drawable.ic_play,
                if (playing) "Pause" else "Play",
                PlaybackService.action(context, if (playing) "pause" else "play"),
            )
            .addAction(R.drawable.ic_next, "Next", PlaybackService.action(context, "next"))
            .setStyle(MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0, 1, 2))
            .build()
        PlaybackService.show(context, notification, playing)
    }

    private fun clear() {
        artworkUrl = null
        artwork = null
        metadata = null
        session.isActive = false
        PlaybackService.hide(context)
        audio.abandonAudioFocusRequest(focus)
    }

    /// The system's output switcher, where Android lists the phone, Bluetooth and cast devices.
    private fun pickOutput() {
        if (Build.VERSION.SDK_INT >= 34 && MediaRouter2.getInstance(context).showSystemOutputSwitcher()) return
        val panel = Intent("com.android.settings.panel.action.MEDIA_OUTPUT")
            .putExtra("com.android.settings.panel.extra.PACKAGE_NAME", context.packageName)
        runCatching { activity.startActivity(panel) }
            .onFailure { activity.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)) }
    }

    private fun sendOnline() = send("online", connectivity.activeNetwork != null)

    private fun sendVolume() {
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val now = audio.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() / max
        if (now == volume) return
        volume = now
        send("volume", now.toDouble())
    }

    /// What plays the sound now, by the name the phone gives it, for the player's output chip.
    /// Only sent to Dart for the screen, never written to the log.
    private fun sendOutput() {
        val device = if (Build.VERSION.SDK_INT >= 33) {
            audio.getAudioDevicesForAttributes(focus.audioAttributes).firstOrNull()?.let { routed ->
                audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.id == routed.id }
            }
        } else {
            // ponytail: the likeliest route by type before Android 13, which names none.
            audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).maxByOrNull { rank(it.type) }
        }
        val name = when (device?.type) {
            null, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> Build.MODEL
            else -> device.productName?.toString()
        }
        send("output", name)
        volume = -1f
        sendVolume()
    }

    private fun rank(type: Int) = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLE_HEADSET -> 3
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_USB_HEADSET -> 2
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> 1
        else -> 0
    }

    fun send(command: String, value: Any? = null) {
        main.post { channel.invokeMethod("command", mapOf("name" to command, "value" to value)) }
    }

    private fun millis(seconds: Any?) = ((seconds as? Number)?.toDouble() ?: 0.0).times(1000).toLong()

    companion object {
        const val PLAYBACK_CHANNEL = "playback"

        /// The one live instance, which the notification's buttons reach through the service.
        var current: NowPlaying? = null

        fun createChannel(context: Context, id: String, importance: Int) {
            val name = if (id == PLAYBACK_CHANNEL) "Playback" else "Downloads"
            context.getSystemService(NotificationManager::class.java)
                .createNotificationChannel(NotificationChannel(id, name, importance))
        }
    }
}

/// Keeps the app playing once it leaves the screen: in the foreground while the music plays, and
/// a plain notification, which can be swiped away, while it is paused.
class PlaybackService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.getStringExtra(COMMAND)?.let { NowPlaying.current?.send(it) }
        running = this
        val notification = notification
        if (notification == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (playing) {
            ServiceCompat.startForeground(this, ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = null
        super.onDestroy()
    }

    companion object {
        private const val ID = 1
        private const val COMMAND = "command"
        private var running: PlaybackService? = null
        private var notification: Notification? = null
        private var playing = false

        /// A notification button: the service passes its command on to Dart.
        fun action(context: Context, command: String): PendingIntent = PendingIntent.getService(
            context,
            command.hashCode(),
            Intent(context, PlaybackService::class.java).putExtra(COMMAND, command),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        fun show(context: Context, notification: Notification, playing: Boolean) {
            this.notification = notification
            this.playing = playing
            val service = running
            when {
                playing && service == null ->
                    ContextCompat.startForegroundService(context, Intent(context, PlaybackService::class.java))
                playing -> ServiceCompat.startForeground(
                    service!!,
                    ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
                else -> {
                    service?.let { ServiceCompat.stopForeground(it, ServiceCompat.STOP_FOREGROUND_DETACH) }
                    runCatching { NotificationManagerCompat.from(context).notify(ID, notification) }
                }
            }
        }

        fun hide(context: Context) {
            notification = null
            playing = false
            running?.let {
                ServiceCompat.stopForeground(it, ServiceCompat.STOP_FOREGROUND_REMOVE)
                it.stopSelf()
            }
            NotificationManagerCompat.from(context).cancel(ID)
        }
    }
}
