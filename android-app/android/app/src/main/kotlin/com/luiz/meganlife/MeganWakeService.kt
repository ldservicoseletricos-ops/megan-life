package com.luiz.meganlife

import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

class MeganWakeService : Service() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Compatibilidade: este serviço antigo não deve mais abrir outro AudioRecord.
        // A escuta de presença fica centralizada em MeganPresenceService para evitar
        // duplicidade de microfone, travamentos e conflito com a escuta em segundo plano.
        val presenceIntent = Intent(this, MeganPresenceService::class.java).apply {
            action = MeganPresenceService.ACTION_START
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(presenceIntent)
            } else {
                startService(presenceIntent)
            }
        } catch (_: Exception) {
        }

        stopSelf()
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
