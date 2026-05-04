package com.luiz.meganlife

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class MeganPresenceService : Service() {

    companion object {
        const val ACTION_START = "com.luiz.meganlife.presence.START"
        const val ACTION_STOP = "com.luiz.meganlife.presence.STOP"

        private const val CHANNEL_ID = "megan_presence_channel"
        private const val CHANNEL_NAME = "Megan ativa"
        private const val NOTIFICATION_ID = 6101
        private const val WAKE_LOCK_TAG = "MeganLife:PresenceWakeLock"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopPresence()
                return START_NOT_STICKY
            }

            ACTION_START, null -> {
                startPresence()
            }
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    override fun onDestroy() {
        releaseWakeLock()
        isRunning = false
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)

        // 6.2 — Presença com tela bloqueada:
        // Mantém o serviço preparado para continuar vivo quando o Android remove
        // a tarefa da lista de recentes. Não ativa microfone agressivo e não mexe
        // no fluxo Flutter; apenas reforça a base foreground segura.
        if (isRunning) {
            try {
                val restartIntent = Intent(applicationContext, MeganPresenceService::class.java).apply {
                    action = ACTION_START
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    applicationContext.startForegroundService(restartIntent)
                } else {
                    applicationContext.startService(restartIntent)
                }
            } catch (_: Exception) {
                // Se o Android bloquear o restart imediato, o START_STICKY ainda
                // permite que o sistema recrie o serviço quando possível.
            }
        }
    }

    private fun startPresence() {
        isRunning = true
        acquireWakeLockSafely()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    private fun stopPresence() {
        isRunning = false
        releaseWakeLock()
        stopForegroundCompat()
        stopSelf()
    }

    private fun acquireWakeLockSafely() {
        try {
            if (wakeLock?.isHeld == true) return

            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                WAKE_LOCK_TAG
            ).apply {
                setReferenceCounted(false)

                // 6.2 — Mantém a base de presença mais resistente com tela bloqueada.
                // O serviço continua sem ativar escuta agressiva; apenas preserva CPU
                // suficiente para manter a presença foreground estável.
                @Suppress("WakelockTimeout")
                acquire()
            }
        } catch (_: Exception) {
            // Mantém o serviço vivo mesmo se o aparelho bloquear wake lock.
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Exception) {
        } finally {
            wakeLock = null
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Mantém a base de presença segura da Megan Life."
            setShowBadge(false)
        }

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        val pendingIntentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            pendingIntentFlags
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Megan ativa")
            .setContentText("Presença segura em execução.")
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
