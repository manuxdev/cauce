package dev.manuxdev.cauce

import android.Manifest
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// The channels the iOS app answers natively. Playback controls and notifications are Android's
/// own; the rest answer with the value that means "nothing here": no phone Music library and no
/// picked folders yet.
class MainActivity : FlutterActivity() {
    /// Hands the Rust core the app context: its certificate verifier and audio output need it.
    private external fun initAndroid(context: Context)

    /// The icon picked in settings, applied once the app leaves the screen: switching launcher
    /// entries while in front can close the app or drop its home screen shortcut.
    private var pendingIcon: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The same library Dart opens over FFI, so the verifier set here is the one it uses.
        System.loadLibrary("cauce_bridge")
        initAndroid(applicationContext)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "cauce/app_icon").setMethodCallHandler { call, result ->
            pendingIcon = (call.arguments as String?) ?: "night"
            result.success(null)
        }
        NowPlaying(this, messenger)
        MethodChannel(messenger, "cauce/notifications").setMethodCallHandler { call, result ->
            when (call.method) {
                "ask" -> {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
                    }
                    result.success(null)
                }
                "post" -> {
                    @Suppress("UNCHECKED_CAST")
                    val note = call.arguments as Map<String, Any?>
                    NowPlaying.createChannel(this, NOTICES_CHANNEL, NotificationManager.IMPORTANCE_DEFAULT)
                    val notification = NotificationCompat.Builder(this, NOTICES_CHANNEL)
                        .setSmallIcon(R.drawable.ic_notification)
                        .setContentTitle(note["title"] as String?)
                        .setContentText(note["body"] as String?)
                        .setAutoCancel(true)
                        .build()
                    // Without the permission the system drops it, as iOS does.
                    runCatching { NotificationManagerCompat.from(this).notify(note.hashCode(), notification) }
                    result.success(null)
                }
                else -> result.success(null)
            }
        }
        MethodChannel(messenger, "cauce/media_library").setMethodCallHandler { call, result ->
            when (call.method) {
                "songs", "folders" -> result.success(emptyList<Any>())
                "claim", "addFolder" -> result.success(false)
                else -> result.success(null)
            }
        }
    }

    override fun onStop() {
        super.onStop()
        val icon = pendingIcon ?: return
        pendingIcon = null
        // One launcher alias per icon, in the manifest; only the chosen one stays enabled.
        for (name in listOf("night", "paper", "magenta", "coral")) {
            val alias = ComponentName(this, "$packageName.Icon${name.replaceFirstChar { it.uppercase() }}")
            val state = if (name == icon) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            packageManager.setComponentEnabledSetting(alias, state, PackageManager.DONT_KILL_APP)
        }
    }

    private companion object {
        const val NOTICES_CHANNEL = "notices"
    }
}
