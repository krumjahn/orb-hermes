package com.keith.orbhermes

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Keeps the orb alive when nobody is looking at it.
 *
 * Android takes the microphone away as soon as the activity is no longer in
 * the foreground, and kills the process shortly after, so a desk assistant
 * that has to keep hearing "Orbit" needs a microphone foreground service.
 *
 * The service owns no state of its own: it starts the shared [OrbCore] and
 * keeps the process alive so the core keeps working with the screen off.
 */
class OrbService : Service() {

    override fun onCreate() {
        super.onCreate()
        createChannel()
        goForeground()
        OrbCore.get(this).start()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // the service can be restarted by the system; make sure the core is up
        OrbCore.get(this).start()
        goForeground()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        OrbCore.get(this).stop()
    }

    /**
     * A microphone foreground service needs RECORD_AUDIO. If the permission is
     * missing the platform refuses the microphone type, so fall back to a
     * plain foreground service rather than crashing.
     */
    private fun goForeground() {
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val type = if (hasMicPermission()) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                } else {
                    0
                }
                startForeground(NOTIFICATION_ID, notification, type)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            android.util.Log.w("OrbHermes", "startForeground failed: ${e.message}")
        }
    }

    private fun hasMicPermission(): Boolean =
        androidx.core.content.ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.RECORD_AUDIO,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Orb assistant",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps the orb listening while the screen is off"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Orb is listening")
            .setContentText("Say “${WakeWord.DEFAULT_PHRASE}” to wake it")
            .setSmallIcon(R.drawable.ic_orb_launcher)
            .setContentIntent(open)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "orb_assistant"
        private const val NOTIFICATION_ID = 4711
    }
}
