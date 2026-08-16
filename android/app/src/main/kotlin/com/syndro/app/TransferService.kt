package com.syndro.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.FileProvider
import androidx.core.graphics.drawable.IconCompat
import java.io.File

class TransferService : Service() {

    companion object {
        const val CHANNEL_PROGRESS = "syndro_transfer_progress"
        const val CHANNEL_REQUESTS = "syndro_transfer_requests"
        const val CHANNEL_COMPLETE = "syndro_transfer_complete"

        const val NOTIFICATION_PROGRESS = 1001
        const val NOTIFICATION_REQUEST = 1002
        const val NOTIFICATION_COMPLETE = 1003

        const val ACTION_START = "com.syndro.app.START_TRANSFER"
        const val ACTION_STOP = "com.syndro.app.STOP_TRANSFER"
        const val ACTION_UPDATE = "com.syndro.app.UPDATE_TRANSFER"
        const val ACTION_CANCEL = "com.syndro.app.CANCEL_TRANSFER"
        const val ACTION_SHOW_REQUEST = "com.syndro.app.SHOW_REQUEST"
        const val ACTION_ACCEPT_TRANSFER = "com.syndro.app.ACCEPT_TRANSFER"
        const val ACTION_REJECT_TRANSFER = "com.syndro.app.REJECT_TRANSFER"
        const val ACTION_SHOW_COMPLETE = "com.syndro.app.SHOW_COMPLETE"
        const val ACTION_OPEN_FILE = "com.syndro.app.OPEN_FILE"
        const val ACTION_SHARE_FILE = "com.syndro.app.SHARE_FILE"
        const val ACTION_DISMISS_REQUEST = "com.syndro.app.DISMISS_REQUEST"

        const val EXTRA_TITLE = "title"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_FILE_NAME = "file_name"
        const val EXTRA_FILE_PATH = "file_path"
        const val EXTRA_SPEED = "speed"
        const val EXTRA_TIME_REMAINING = "time_remaining"
        const val EXTRA_BYTES_TRANSFERRED = "bytes_transferred"
        const val EXTRA_TOTAL_BYTES = "total_bytes"
        const val EXTRA_SENDER_NAME = "sender_name"
        const val EXTRA_FILE_COUNT = "file_count"
        const val EXTRA_TOTAL_SIZE = "total_size"
        const val EXTRA_REQUEST_ID = "request_id"
        const val EXTRA_THUMBNAIL_PATH = "thumbnail_path"
        const val EXTRA_FIRST_FILE_NAME = "first_file_name"
    }

    private var currentRequestId: String? = null
    private var lastFilePath: String? = null
    private var lastFileName: String? = null

    // Held for the duration of a transfer / pending receive so MIUI-style
    // battery managers can't freeze the isolate that hosts the HTTP server
    // (which would make incoming upload connections be refused).
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val idleHandler = Handler(Looper.getMainLooper())
    private var idleStopRunnable: Runnable? = null

    // Safety net: if a transfer we kept the service alive for never actually
    // starts (e.g. sender went away after we accepted), stop after this delay
    // instead of holding locks forever.
    private val pendingReceiveTimeoutMs = 90_000L

    /** Acquire CPU + Wi-Fi locks (idempotent). */
    private fun acquireLocks() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "syndro:transfer"
                )
            }
            if (wakeLock?.isHeld == false) wakeLock?.acquire(30 * 60 * 1000L)

            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm.createWifiLock(mode, "syndro:transfer")
            }
            if (wifiLock?.isHeld == false) wifiLock?.acquire()
        } catch (e: Exception) {
            Log.w("TransferService", "Could not acquire transfer locks: $e")
        }
    }

    /** Release CPU + Wi-Fi locks (idempotent). */
    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (e: Exception) {
            Log.w("TransferService", "Error releasing wake lock: $e")
        }
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (e: Exception) {
            Log.w("TransferService", "Error releasing wifi lock: $e")
        }
    }

    private fun cancelIdleStop() {
        idleStopRunnable?.let { idleHandler.removeCallbacks(it) }
        idleStopRunnable = null
    }

    private fun scheduleIdleStop() {
        cancelIdleStop()
        val r = Runnable {
            releaseLocks()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        idleStopRunnable = r
        idleHandler.postDelayed(r, pendingReceiveTimeoutMs)
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "Transferring files..."
                val fileName = intent.getStringExtra(EXTRA_FILE_NAME) ?: ""
                cancelIdleStop()
                acquireLocks()
                // Clear any incoming-request notification now that we're receiving.
                (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .cancel(NOTIFICATION_REQUEST)
                currentRequestId = null
                startForeground(
                    NOTIFICATION_PROGRESS,
                    createProgressNotification(title, fileName, 0, null, null)
                )
                // Safety net in case this was a "receiving..." bridge and the
                // upload never actually arrives.
                scheduleIdleStop()
            }

            ACTION_UPDATE -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "Transferring files..."
                val fileName = intent.getStringExtra(EXTRA_FILE_NAME) ?: ""
                val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                val speed = intent.getStringExtra(EXTRA_SPEED)
                val timeRemaining = intent.getStringExtra(EXTRA_TIME_REMAINING)
                cancelIdleStop()
                acquireLocks()
                updateProgressNotification(title, fileName, progress, speed, timeRemaining)
            }

            ACTION_STOP -> {
                cancelIdleStop()
                releaseLocks()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }

            ACTION_CANCEL -> {
                val cancelIntent = Intent("com.syndro.app.TRANSFER_CANCELLED")
                sendBroadcast(cancelIntent)
                cancelIdleStop()
                releaseLocks()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }

            ACTION_SHOW_REQUEST -> {
                val senderName = intent.getStringExtra(EXTRA_SENDER_NAME) ?: "Unknown"
                val fileCount = intent.getIntExtra(EXTRA_FILE_COUNT, 1)
                val totalSize = intent.getLongExtra(EXTRA_TOTAL_SIZE, 0L)
                val thumbnailPath = intent.getStringExtra(EXTRA_THUMBNAIL_PATH)
                val firstFileName = intent.getStringExtra(EXTRA_FIRST_FILE_NAME)
                currentRequestId = intent.getStringExtra(EXTRA_REQUEST_ID)
                showTransferRequestNotification(senderName, fileCount, totalSize, thumbnailPath, firstFileName)
            }

            ACTION_ACCEPT_TRANSFER -> {
                currentRequestId?.let { requestId ->
                    val acceptIntent = Intent("com.syndro.app.TRANSFER_ACCEPTED").apply {
                        putExtra(EXTRA_REQUEST_ID, requestId)
                    }
                    sendBroadcast(acceptIntent)
                }
                currentRequestId = null
                // Do NOT stop the service here. The incoming upload arrives a
                // moment after we accept; if we drop to background now, MIUI /
                // aggressive battery managers can freeze the isolate hosting the
                // HTTP server and the sender's upload connection gets refused.
                // Keep a foreground "receiving" notification + locks alive until
                // the real progress notification (ACTION_START) takes over, or
                // the idle timeout fires.
                val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                notificationManager.cancel(NOTIFICATION_REQUEST)
                acquireLocks()
                startForeground(
                    NOTIFICATION_PROGRESS,
                    createProgressNotification("Receiving files...", "", 0, null, null)
                )
                scheduleIdleStop()
            }

            ACTION_REJECT_TRANSFER -> {
                currentRequestId?.let { requestId ->
                    val rejectIntent = Intent("com.syndro.app.TRANSFER_REJECTED").apply {
                        putExtra(EXTRA_REQUEST_ID, requestId)
                    }
                    sendBroadcast(rejectIntent)
                }
                dismissRequestNotification()
            }

            ACTION_DISMISS_REQUEST -> {
                dismissRequestNotification()
            }

            ACTION_SHOW_COMPLETE -> {
                val fileName = intent.getStringExtra(EXTRA_FILE_NAME) ?: ""
                val filePath = intent.getStringExtra(EXTRA_FILE_PATH) ?: ""
                val fileCount = intent.getIntExtra(EXTRA_FILE_COUNT, 1)
                val totalSize = intent.getLongExtra(EXTRA_TOTAL_SIZE, 0L)
                val thumbnailPath = intent.getStringExtra(EXTRA_THUMBNAIL_PATH)
                lastFilePath = filePath
                lastFileName = fileName
                cancelIdleStop()
                releaseLocks()
                showCompletionNotification(fileName, filePath, fileCount, totalSize, thumbnailPath)
                stopForeground(STOP_FOREGROUND_REMOVE)
            }

            ACTION_OPEN_FILE -> {
                lastFilePath?.let { openFile(it) }
            }

            ACTION_SHARE_FILE -> {
                lastFilePath?.let { path ->
                    lastFileName?.let { name ->
                        shareFile(path, name)
                    }
                }
            }
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        cancelIdleStop()
        releaseLocks()
        super.onDestroy()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(NotificationManager::class.java)

            val progressChannel = NotificationChannel(
                CHANNEL_PROGRESS,
                "File Transfers",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows file transfer progress"
                setShowBadge(false)
                enableLights(false)
                enableVibration(false)
                setSound(null, null)
            }

            val requestsChannel = NotificationChannel(
                CHANNEL_REQUESTS,
                "Transfer Requests",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Incoming file transfer requests"
                setShowBadge(true)
                enableLights(true)
                lightColor = Color.BLUE
                enableVibration(true)
            }

            val completeChannel = NotificationChannel(
                CHANNEL_COMPLETE,
                "Transfer Complete",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "File transfer completion notifications"
                setShowBadge(true)
            }

            notificationManager.createNotificationChannels(
                listOf(progressChannel, requestsChannel, completeChannel)
            )
        }
    }

    private fun createProgressNotification(
        title: String,
        fileName: String,
        progress: Int,
        speed: String?,
        timeRemaining: String?
    ): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val cancelIntent = Intent(this, TransferService::class.java).apply {
            action = ACTION_CANCEL
        }
        val cancelPendingIntent = PendingIntent.getService(
            this, 1, cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val contentText = buildString {
            if (fileName.isNotEmpty()) append(fileName)
            if (speed != null) {
                if (isNotEmpty()) append(" • ")
                append(speed)
            }
            if (timeRemaining != null) {
                if (isNotEmpty()) append(" • ")
                append(timeRemaining)
            }
            if (isEmpty()) append("Preparing...")
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_PROGRESS)
            .setContentTitle(title)
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .addAction(R.drawable.ic_cancel, "Cancel", cancelPendingIntent)

        if (progress > 0) {
            builder.setProgress(100, progress, false)
            builder.setSubText("$progress%")
        } else {
            builder.setProgress(100, 0, true)
        }

        return builder.build()
    }

    private fun updateProgressNotification(
        title: String,
        fileName: String,
        progress: Int,
        speed: String?,
        timeRemaining: String?
    ) {
        val notification = createProgressNotification(title, fileName, progress, speed, timeRemaining)
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(NOTIFICATION_PROGRESS, notification)
    }

    private fun showTransferRequestNotification(
        senderName: String,
        fileCount: Int,
        totalSize: Long,
        thumbnailPath: String? = null,
        firstFileName: String? = null
    ) {
        val intent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val acceptIntent = Intent(this, TransferService::class.java).apply {
            action = ACTION_ACCEPT_TRANSFER
        }
        val acceptPendingIntent = PendingIntent.getService(
            this, 2, acceptIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val rejectIntent = Intent(this, TransferService::class.java).apply {
            action = ACTION_REJECT_TRANSFER
        }
        val rejectPendingIntent = PendingIntent.getService(
            this, 3, rejectIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val sizeText = formatBytes(totalSize)
        val filesText = if (fileCount == 1) "1 file" else "$fileCount files"

        // Build the notification with rich content
        val builder = NotificationCompat.Builder(this, CHANNEL_REQUESTS)
            .setContentTitle("📥 Incoming Transfer from $senderName")
            .setContentText("$filesText ($sizeText)")
            .setSmallIcon(R.drawable.ic_notification)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_SOCIAL)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setContentIntent(pendingIntent)
            .addAction(R.drawable.ic_accept, "Accept", acceptPendingIntent)
            .addAction(R.drawable.ic_reject, "Reject", rejectPendingIntent)
            .setAutoCancel(false)
            .setOngoing(true)

        // Add large icon/thumbnail if available
        if (!thumbnailPath.isNullOrEmpty()) {
            try {
                val thumbnailFile = File(thumbnailPath)
                if (thumbnailFile.exists()) {
                    val bitmap = loadThumbnail(thumbnailPath, 256)
                    if (bitmap != null) {
                        builder.setLargeIcon(bitmap)
                        // Add big picture style for expanded view
                        builder.setStyle(
                            NotificationCompat.BigPictureStyle()
                                .bigPicture(bitmap)
                                .setBigContentTitle("Incoming Transfer from $senderName")
                                .setSummaryText("$filesText ($sizeText)${firstFileName?.let { " • $it" } ?: ""}")
                        )
                    }
                }
            } catch (e: Exception) {
                // Ignore thumbnail errors
            }
        } else if (!firstFileName.isNullOrEmpty()) {
            // Show file name in expanded text
            builder.setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText("$senderName wants to send $filesText ($sizeText)\n\nFirst file: $firstFileName")
            )
        }

        startForeground(NOTIFICATION_REQUEST, builder.build())
    }

    private fun dismissRequestNotification() {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(NOTIFICATION_REQUEST)
        currentRequestId = null
        cancelIdleStop()
        releaseLocks()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun showCompletionNotification(
        fileName: String,
        filePath: String,
        fileCount: Int,
        totalSize: Long,
        thumbnailPath: String? = null
    ) {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val sizeText = formatBytes(totalSize)

        val builder = NotificationCompat.Builder(this, CHANNEL_COMPLETE)
            .setContentTitle("✅ Transfer Complete")
            .setSmallIcon(R.drawable.ic_done)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)

        if (fileCount == 1 && fileName.isNotEmpty()) {
            builder.setContentText("Received: $fileName ($sizeText)")

            // Add thumbnail for images
            if (!thumbnailPath.isNullOrEmpty()) {
                try {
                    val thumbnailFile = File(thumbnailPath)
                    if (thumbnailFile.exists()) {
                        val bitmap = loadThumbnail(thumbnailPath, 256)
                        if (bitmap != null) {
                            builder.setLargeIcon(bitmap)
                            builder.setStyle(
                                NotificationCompat.BigPictureStyle()
                                    .bigPicture(bitmap)
                                    .setBigContentTitle("Transfer Complete")
                                    .setSummaryText(fileName)
                            )
                        }
                    }
                } catch (e: Exception) {
                    // Ignore thumbnail errors
                }
            }

            if (filePath.isNotEmpty()) {
                try {
                    val file = File(filePath)
                    if (file.exists()) {
                        val openIntent = Intent(this, TransferService::class.java).apply {
                            action = ACTION_OPEN_FILE
                        }
                        val openPendingIntent = PendingIntent.getService(
                            this, 4, openIntent,
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                        )
                        builder.addAction(R.drawable.ic_open, "Open", openPendingIntent)

                        val shareIntent = Intent(this, TransferService::class.java).apply {
                            action = ACTION_SHARE_FILE
                        }
                        val sharePendingIntent = PendingIntent.getService(
                            this, 5, shareIntent,
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                        )
                        builder.addAction(R.drawable.ic_share, "Share", sharePendingIntent)
                    }
                } catch (e: Exception) {
                    // Ignore
                }
            }
        } else {
            builder.setContentText("Received $fileCount files ($sizeText)")
        }

        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(NOTIFICATION_COMPLETE, builder.build())
    }

    private fun openFile(filePath: String) {
        try {
            val file = File(filePath)
            if (file.exists()) {
                val uri = FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    file
                )
                val mimeType = getMimeType(filePath)
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mimeType)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(intent)
            } else {
                Log.w("TransferService", "Cannot open file - file does not exist: $filePath")
            }
        } catch (e: Exception) {
            Log.e("TransferService", "Error opening file: $e")
        }
    }

    private fun shareFile(filePath: String, fileName: String) {
        try {
            val file = File(filePath)
            if (file.exists()) {
                val uri = FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    file
                )
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = getMimeType(filePath)
                    putExtra(Intent.EXTRA_STREAM, uri)
                    putExtra(Intent.EXTRA_SUBJECT, fileName)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(Intent.createChooser(intent, "Share file").apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                })
            } else {
                Log.w("TransferService", "Cannot share file - file does not exist: $filePath")
            }
        } catch (e: Exception) {
            Log.e("TransferService", "Error sharing file: $e")
        }
    }

    private fun getMimeType(filePath: String): String {
        val extension = filePath.substringAfterLast('.', "").lowercase()
        return when (extension) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "mp4" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "avi" -> "video/x-msvideo"
            "mov" -> "video/quicktime"
            "mp3" -> "audio/mpeg"
            "wav" -> "audio/wav"
            "flac" -> "audio/flac"
            "pdf" -> "application/pdf"
            "doc" -> "application/msword"
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "xls" -> "application/vnd.ms-excel"
            "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "zip" -> "application/zip"
            "rar" -> "application/x-rar-compressed"
            "txt" -> "text/plain"
            "apk" -> "application/vnd.android.package-archive"
            else -> "*/*"
        }
    }

    private fun formatBytes(bytes: Long): String {
        return when {
            bytes < 1024 -> "$bytes B"
            bytes < 1024 * 1024 -> "${bytes / 1024} KB"
            bytes < 1024 * 1024 * 1024 -> String.format("%.1f MB", bytes / (1024.0 * 1024.0))
            else -> String.format("%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0))
        }
    }

    /// Load a thumbnail from a file path with size limit
    private fun loadThumbnail(path: String, maxSize: Int): Bitmap? {
        return try {
            val options = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            BitmapFactory.decodeFile(path, options)

            val width = options.outWidth
            val height = options.outHeight
            var scale = 1

            if (width > maxSize || height > maxSize) {
                val halfWidth = width / 2
                val halfHeight = height / 2
                while (halfWidth / scale >= maxSize && halfHeight / scale >= maxSize) {
                    scale *= 2
                }
            }

            val decodeOptions = BitmapFactory.Options().apply {
                inSampleSize = scale
            }
            BitmapFactory.decodeFile(path, decodeOptions)
        } catch (e: Exception) {
            null
        }
    }
}
