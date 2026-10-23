package com.padelegypt.padel_clay

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Create the FCM default channel as early as possible so a notification
    // arriving while the app is killed has a valid channel to land on. The id
    // must match `default_notification_channel_id` in AndroidManifest.xml and
    // the `channel_id` sent by the push-notify Edge Function.
    //
    // Channels are immutable after creation: importance/visibility set here are
    // what the OS uses forever (re-registering with new values is ignored). If
    // these ever need to change, bump the channel id.
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "padel_default",
                "Match & Order Updates",
                NotificationManager.IMPORTANCE_HIGH, // heads-up pop-up
            ).apply {
                description = "Match invites, results, and order updates"
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC // show content on lock screen
                enableVibration(true)
            }
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }
    }

    // Console → "send the confirmation": open a chat in WhatsApp BUSINESS
    // specifically (the business number lives there; a plain wa.me link lets
    // Android pick personal WhatsApp). Answers false when Business isn't
    // installed so the Dart side falls back to wa.me.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "padel/whatsapp")
            .setMethodCallHandler { call, result ->
                if (call.method != "openBusiness") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val url = call.argument<String>("url")
                if (url == null) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                try {
                    startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            .setPackage("com.whatsapp.w4b")
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(true)
                } catch (e: ActivityNotFoundException) {
                    result.success(false)
                }
            }
    }
}
