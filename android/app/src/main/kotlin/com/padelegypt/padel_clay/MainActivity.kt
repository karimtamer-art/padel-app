package com.padelegypt.padel_clay

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity

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
}
