package org.tetra.live

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Foreground service with the ongoing radio notification: talker, group and
 * a running timer while someone talks; server, own callsign and ISSI in
 * standby; a Talk/Stop button. On Android 16 it asks to be promoted to a Live
 * Update (status bar chip, top of the shade). Being a foreground service of
 * type microphone also lets the app hear and transmit with the screen off.
 */
class LiveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val status = LiveStatus.load(this)
        if (status == null || !status.live) {
            stopSelf()
            return START_NOT_STICKY
        }
        val n = build(this, status)
        // Every startForegroundService() must be answered with startForeground().
        run {
            try {
                if (Build.VERSION.SDK_INT >= 30) {
                    try {
                        startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
                    } catch (e: SecurityException) {
                        // No microphone permission yet: still keep playback alive.
                        startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
                    }
                } else if (Build.VERSION.SDK_INT == 29) {
                    startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
                } else {
                    startForeground(ID, n)
                }
                foreground = true
            } catch (e: Exception) {
                Log.w(TAG, "startForeground failed: $e")
                stopSelf()
                return START_NOT_STICKY
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        foreground = false
        super.onDestroy()
    }

    companion object {
        private const val TAG = "TetraLive"
        private const val ID = 4711
        private const val CHANNEL = "tetra_live"
        @Volatile private var foreground = false

        /** Starts the service or refreshes its notification with the saved status. */
        fun show(ctx: Context) {
            ensureChannel(ctx)
            if (foreground) {
                // Already running: just refresh the notification.
                LiveStatus.load(ctx)?.let { s -> ctx.getSystemService(NotificationManager::class.java)?.notify(ID, build(ctx, s)) }
                return
            }
            val i = Intent(ctx, LiveService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (e: Exception) {
                // Android 12+: no foreground service start from the background.
                Log.w(TAG, "cannot start: $e")
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, LiveService::class.java))
            ctx.getSystemService(NotificationManager::class.java)?.cancel(ID)
            foreground = false
        }

        private fun ensureChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
            if (nm.getNotificationChannel(CHANNEL) != null) return
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Radio status", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Talkgroup, talker and push-to-talk while connected"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            })
        }

        fun build(ctx: Context, s: LiveStatus): Notification {
            ensureChannel(ctx)
            @Suppress("DEPRECATION")
            val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CHANNEL) else Notification.Builder(ctx)
            val accent = when {
                s.emergency -> Color.rgb(0xD7, 0x00, 0x15)
                s.transmitting -> Color.rgb(0xE5, 0x48, 0x4D)
                else -> Color.rgb(0x1F, 0x8A, 0x70)
            }
            b.setSmallIcon(R.drawable.tetra_live_ic_radio)
                .setContentTitle(s.title)
                .setContentText(s.text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setColor(accent)
                .setCategory(Notification.CATEGORY_STATUS)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
            PttReceiver.pendingOpenApp(ctx)?.let { b.setContentIntent(it) }

            // Running timer: talk time, or the countdown of the tap-to-talk auto-stop.
            val end = s.txEndsAt
            val since = s.talkerSince
            if (s.transmitting && end != null && Build.VERSION.SDK_INT >= 24) {
                b.setWhen(end).setShowWhen(true).setUsesChronometer(true).setChronometerCountDown(true)
            } else if (since != null) {
                b.setWhen(since).setShowWhen(true).setUsesChronometer(true)
            }

            if (s.transmitting || s.canTalk) {
                val label = if (s.transmitting) "Stop" else "Talk"
                val icon = if (s.transmitting) R.drawable.tetra_live_ic_stop else R.drawable.tetra_live_ic_mic
                @Suppress("DEPRECATION")
                val action = if (Build.VERSION.SDK_INT >= 23) {
                    Notification.Action.Builder(Icon.createWithResource(ctx, icon), label, PttReceiver.pendingToggle(ctx, 1)).build()
                } else {
                    Notification.Action.Builder(icon, label, PttReceiver.pendingToggle(ctx, 1)).build()
                }
                b.addAction(action)
            }

            if (TetraLivePlugin.promotedSupported) promote(b, s)
            return b.build()
        }

        /**
         * Android 16 Live Update: promoted ongoing notification with a short
         * text in the status bar chip. Called by reflection so the plugin also
         * builds against older SDKs; a no-op where the API is missing.
         */
        private fun promote(b: Notification.Builder, s: LiveStatus) {
            try {
                Notification.Builder::class.java.getMethod("setRequestPromotedOngoing", Boolean::class.javaPrimitiveType).invoke(b, true)
                val chip = when {
                    s.transmitting -> "TX"
                    s.talker != null -> s.talker
                    else -> null
                }
                if (chip != null) {
                    Notification.Builder::class.java.getMethod("setShortCriticalText", String::class.java).invoke(b, chip.take(7))
                }
            } catch (e: Exception) {
                Log.d(TAG, "no Live Update: $e")
            }
        }
    }
}
