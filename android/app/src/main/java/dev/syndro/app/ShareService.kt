package dev.syndro.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import java.io.File

class ShareService : Service() {

    companion object {
        const val ACTION_STOP = "dev.syndro.app.action.STOP"
        private const val CHANNEL_ID = "syndro-share"
        private const val NOTIFICATION_ID = 1
    }

    private var server: ShareServer? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.notification_channel),
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        if (server == null) {
            val prefs = getSharedPreferences("syndro", MODE_PRIVATE)
            val stored = prefs.getString("token", null)?.takeIf { Code.isValid(it) }
            val token = stored
                ?: Code.generate().also { prefs.edit().putString("token", it).apply() }

            val instance = ShareServer(
                token = token,
                deviceName = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android",
                assets = assets,
                rootDir = File(filesDir, "received"),
                onFilesChanged = { ShareState.received.value = it },
            )

            try {
                instance.start()
                server = instance
                ShareState.port.value = instance.boundPort
                ShareState.urls.value = Addresses.localUrls(instance.boundPort, "/s/$token")
                ShareState.received.value = instance.files()
                ShareState.error.value = null
            } catch (error: Exception) {
                ShareState.error.value = error.message ?: "Could not start sharing"
                ShareState.running.value = false
                stopSelf()
                return START_NOT_STICKY
            }
        }

        ShareState.running.value = true
        startForeground(NOTIFICATION_ID, buildNotification())
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        server?.stop()
        server = null
        ShareState.running.value = false
        ShareState.urls.value = emptyList()
        ShareState.port.value = 0
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, ShareService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val address = ShareState.urls.value.firstOrNull { it.browserReachable }?.url
            ?: "Waiting for a network"

        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.notification_title))
            .setContentText(address)
            .setSmallIcon(R.drawable.ic_stat_syndro)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, R.drawable.ic_stat_syndro),
                    getString(R.string.notification_stop),
                    stop,
                ).build(),
            )
            .build()
    }
}
