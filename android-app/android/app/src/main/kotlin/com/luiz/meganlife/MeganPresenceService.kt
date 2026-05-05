package com.luiz.meganlife

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import androidx.core.content.ContextCompat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.concurrent.thread

class MeganPresenceService : Service(), TextToSpeech.OnInitListener {

    companion object {
        const val ACTION_START = "com.luiz.meganlife.presence.START"
        const val ACTION_STOP = "com.luiz.meganlife.presence.STOP"

        private const val CHANNEL_ID = "megan_presence_channel"
        private const val CHANNEL_NAME = "Megan escuta segura"
        private const val NOTIFICATION_ID = 6101
        private const val WAKE_NOTIFICATION_ID = 6102
        private const val WAKE_CHANNEL_ID = "megan_wake_alert_channel"
        private const val WAKE_CHANNEL_NAME = "Megan Wake Alert"
        private const val WAKE_LOCK_TAG = "MeganLife:PresenceWakeLock"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var wakeLock: PowerManager.WakeLock? = null
    private var wakeThread: Thread? = null
    private var tts: TextToSpeech? = null
    private var speechRecognizer: SpeechRecognizer? = null

    @Volatile
    private var wakeListening: Boolean = false

    @Volatile
    private var isListeningCommand: Boolean = false

    @Volatile
    private var ttsReady: Boolean = false

    private var lastWakeAt: Long = 0L
    private var lastCommandAt: Long = 0L
    private var lastNoCommandAt: Long = 0L
    private var lastPresenceNotificationAt: Long = 0L

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        tts = TextToSpeech(this, this)
    }

    override fun onInit(status: Int) {
        ttsReady = status == TextToSpeech.SUCCESS

        if (ttsReady) {
            try {
                tts?.language = Locale("pt", "BR")
                tts?.setSpeechRate(0.98f)
                tts?.setPitch(1.04f)
            } catch (_: Exception) {
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopPresence()
                return START_NOT_STICKY
            }

            ACTION_START, null -> startPresence()
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopNativeWakeListener()
        stopCommandRecognizer()
        releaseWakeLock()

        try {
            tts?.stop()
            tts?.shutdown()
        } catch (_: Exception) {
        } finally {
            tts = null
            ttsReady = false
        }

        isRunning = false
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)

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
            }
        }
    }

    private fun startPresence() {
        if (isRunning && wakeListening) {
            updateNotificationText("Presença ativa. Diga: ok Megan.", throttle = true)
            return
        }

        isRunning = true
        acquireWakeLockSafely()
        startForeground(
            NOTIFICATION_ID,
            buildNotification("Presença ativa. Diga: ok Megan.")
        )
        startNativeWakeListener()
    }

    private fun stopPresence() {
        isRunning = false
        stopNativeWakeListener()
        stopCommandRecognizer()
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
                @Suppress("WakelockTimeout")
                acquire()
            }
        } catch (_: Exception) {
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        } finally {
            wakeLock = null
        }
    }

    private fun startNativeWakeListener() {
        if (wakeListening || !isRunning) return

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            updateNotificationText("Microfone sem permissão. Ative para usar Ok Megan em segundo plano.")
            return
        }

        wakeListening = true

        wakeThread = thread(start = true, name = "MeganNativeWakeListener") {
            var recorder: AudioRecord? = null

            try {
                val sampleRate = 16000
                val minBuffer = AudioRecord.getMinBufferSize(
                    sampleRate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                )

                if (minBuffer <= 0) {
                    updateNotificationText("Escuta nativa indisponível neste aparelho.")
                    wakeListening = false
                    return@thread
                }

                val bufferSize = minBuffer.coerceAtLeast(sampleRate / 3)

                recorder = AudioRecord(
                    MediaRecorder.AudioSource.VOICE_RECOGNITION,
                    sampleRate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    bufferSize
                )

                val buffer = ShortArray(bufferSize)
                recorder.startRecording()

                var voiceFrames = 0
                var silenceFrames = 0

                while (wakeListening && isRunning) {
                    if (isListeningCommand) {
                        Thread.sleep(180)
                        continue
                    }

                    val read = recorder.read(buffer, 0, buffer.size)
                    if (read <= 0) continue

                    var sum = 0.0
                    var peak = 0

                    for (i in 0 until read) {
                        val value = buffer[i].toInt()
                        val abs = kotlin.math.abs(value)
                        if (abs > peak) peak = abs
                        sum += (value * value).toDouble()
                    }

                    val rms = kotlin.math.sqrt(sum / read)

                    // Ajuste anti-spam:
                    // resposta ainda rápida, mas menos sensível para não acordar com qualquer ruído.
                    val voiceDetected = rms > 1450.0 && peak > 5600

                    if (voiceDetected) {
                        voiceFrames++
                        silenceFrames = 0
                    } else {
                        silenceFrames++
                        if (silenceFrames > 5) {
                            voiceFrames = 0
                            silenceFrames = 0
                        }
                    }

                    if (voiceFrames >= 4) {
                        triggerMeganWake()
                        voiceFrames = 0
                        silenceFrames = 0
                    }
                }
            } catch (_: Exception) {
                if (isRunning) {
                    updateNotificationText("Escuta nativa pausada. Toque para abrir a Megan.")
                }
            } finally {
                try {
                    recorder?.stop()
                } catch (_: Exception) {
                }

                try {
                    recorder?.release()
                } catch (_: Exception) {
                }

                recorder = null
                wakeListening = false
            }
        }
    }

    private fun stopNativeWakeListener() {
        wakeListening = false

        try {
            val current = Thread.currentThread()
            val threadToStop = wakeThread
            if (threadToStop != null && threadToStop != current) {
                threadToStop.interrupt()
            }
        } catch (_: Exception) {
        } finally {
            wakeThread = null
        }
    }

    private fun stopCommandRecognizer() {
        try {
            speechRecognizer?.cancel()
            speechRecognizer?.destroy()
        } catch (_: Exception) {
        } finally {
            speechRecognizer = null
            isListeningCommand = false
        }
    }

    private fun speakNative(text: String) {
        try {
            if (!ttsReady || text.isBlank()) return

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                tts?.speak(
                    text,
                    TextToSpeech.QUEUE_FLUSH,
                    null,
                    "megan_presence_${System.currentTimeMillis()}"
                )
            } else {
                @Suppress("DEPRECATION")
                tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null)
            }
        } catch (_: Exception) {
        }
    }

    private fun startCommandListening() {
        mainHandler.post {
            if (!isRunning) return@post

            if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                updateNotificationText("Microfone sem permissão.")
                restartWakeAfterCommand()
                return@post
            }

            try {
                if (!SpeechRecognizer.isRecognitionAvailable(this)) {
                    speakNative("Reconhecimento de fala indisponível neste aparelho.")
                    restartWakeAfterCommand()
                    return@post
                }

                if (isListeningCommand) {
                    stopCommandRecognizer()
                }

                speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this)

                val listenIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, "pt-BR")
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "pt-BR")
                    putExtra(RecognizerIntent.EXTRA_ONLY_RETURN_LANGUAGE_PREFERENCE, false)
                    putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
                    putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                    putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 1800L)
                    putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1400L)
                    putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 2500L)
                }

                speechRecognizer?.setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(params: Bundle?) {
                        updateNotificationText("Megan ouvindo comando em segundo plano.")
                    }

                    override fun onBeginningOfSpeech() {
                        updateNotificationText("Comando detectado. Continue falando.")
                    }

                    override fun onRmsChanged(rmsdB: Float) {}
                    override fun onBufferReceived(buffer: ByteArray?) {}

                    override fun onEndOfSpeech() {
                        updateNotificationText("Processando comando.")
                    }

                    override fun onError(error: Int) {
                        isListeningCommand = false

                        when (error) {
                            SpeechRecognizer.ERROR_NO_MATCH,
                            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> {
                                lastNoCommandAt = System.currentTimeMillis()
                                updateNotificationText("Não ouvi comando claro. Diga: ok Megan e fale o comando.", throttle = true)
                                // Não fala em voz alta para não criar loop de áudio e alerta.
                            }

                            SpeechRecognizer.ERROR_AUDIO -> {
                                updateNotificationText("Tive problema com o áudio do microfone.", throttle = true)
                            }

                            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
                                speakNative("Permissão de microfone insuficiente.")
                                updateNotificationText("Permissão de microfone insuficiente.")
                            }

                            SpeechRecognizer.ERROR_NETWORK,
                            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> {
                                updateNotificationText("Reconhecimento de fala sem conexão agora.", throttle = true)
                            }

                            else -> {
                                updateNotificationText("Não consegui ouvir o comando agora.", throttle = true)
                            }
                        }

                        restartWakeAfterCommand(extraDelayMs = 2200L)
                    }

                    override fun onResults(results: Bundle?) {
                        isListeningCommand = false

                        val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        val command = matches
                            ?.firstOrNull()
                            ?.trim()
                            ?.lowercase(Locale("pt", "BR"))
                            ?: ""

                        handleNativeCommand(command)
                        restartWakeAfterCommand(extraDelayMs = 1400L)
                    }

                    override fun onPartialResults(partialResults: Bundle?) {}
                    override fun onEvent(eventType: Int, params: Bundle?) {}
                })

                isListeningCommand = true
                speechRecognizer?.startListening(listenIntent)
            } catch (_: Exception) {
                isListeningCommand = false
                updateNotificationText("Não consegui iniciar a escuta do comando.", throttle = true)
                restartWakeAfterCommand(extraDelayMs = 2200L)
            }
        }
    }

    private fun restartWakeAfterCommand(extraDelayMs: Long = 1200L) {
        lastCommandAt = System.currentTimeMillis()

        mainHandler.postDelayed({
            stopCommandRecognizer()

            if (isRunning && !wakeListening) {
                startNativeWakeListener()
            }

            if (isRunning) {
                updateNotificationText("Presença ativa. Diga: ok Megan.", throttle = true)
            }
        }, extraDelayMs)
    }

    private fun handleNativeCommand(command: String) {
        val clean = command.trim().lowercase(Locale("pt", "BR"))

        if (clean.isBlank()) {
            lastNoCommandAt = System.currentTimeMillis()
            updateNotificationText("Comando vazio. Diga: ok Megan e fale o comando.", throttle = true)
            return
        }

        updateNotificationText("Comando: $clean")

        when {
            clean.contains("hora") || clean.contains("horas") -> {
                val time = SimpleDateFormat("HH:mm", Locale("pt", "BR")).format(Date())
                speakNative("Agora são $time.")
            }

            clean.contains("seu nome") ||
                clean.contains("qual seu nome") ||
                clean.contains("quem é você") ||
                clean.contains("quem e voce") -> {
                speakNative("Eu sou a Megan Life, sua assistente.")
            }

            clean.contains("teste") || clean.contains("funcionando") -> {
                speakNative("Estou funcionando em segundo plano, Luiz.")
            }

            clean.contains("parar") ||
                clean.contains("desativar presença") ||
                clean.contains("desliga presença") -> {
                speakNative("Tudo bem, Luiz. Vou desativar a presença segura.")
                stopPresence()
            }

            clean.contains("abrir megan") ||
                clean.contains("abre megan") ||
                clean.contains("abrir o app") ||
                clean.contains("abre o app") -> {
                speakNative("Abrindo a Megan.")
                openMainActivity()
            }

            else -> {
                speakNative("Entendi você dizendo: $clean. Vou abrir a Megan para continuar com inteligência completa.")
                openMainActivity()
            }
        }
    }

    private fun openMainActivity() {
        try {
            MainActivity.markNativeWakeDetected()

            val intent = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                putExtra("nativeWakeDetected", true)
            }
            startActivity(intent)
        } catch (_: Exception) {
            showWakeNotification()
        }
    }

    private fun triggerMeganWake() {
        val now = System.currentTimeMillis()

        // Cooldown anti-spam: evita dezenas de alertas quando há ruído contínuo.
        if (now - lastWakeAt < 7000L) return
        if (now - lastCommandAt < 4200L) return
        if (now - lastNoCommandAt < 5000L) return
        if (isListeningCommand) return

        lastWakeAt = now
        MainActivity.markNativeWakeDetected()

        showWakeNotification()
        updateNotificationText("Megan acordada. Fale o comando agora.", throttle = true)

        stopNativeWakeListener()

        mainHandler.postDelayed({
            if (isRunning) {
                startCommandListening()
            }
        }, 320L)
    }

    private fun updateNotificationText(text: String, throttle: Boolean = false) {
        try {
            val now = System.currentTimeMillis()
            if (throttle && now - lastPresenceNotificationAt < 1800L) return
            lastPresenceNotificationAt = now

            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, buildNotification(text))
        } catch (_: Exception) {
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Mantém a presença segura da Megan Life com escuta nativa leve em foreground."
            setShowBadge(false)
        }

        val wakeChannel = NotificationChannel(
            WAKE_CHANNEL_ID,
            WAKE_CHANNEL_NAME,
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Alerta usado para acordar a Megan e abrir a escuta."
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(channel)
        manager.createNotificationChannel(wakeChannel)
    }

    private fun buildWakeNotification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
            addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            putExtra("nativeWakeDetected", true)
        }

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        val pendingIntent = PendingIntent.getActivity(this, 6202, openIntent, flags)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, WAKE_CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Megan acordada")
            .setContentText("Fale seu comando agora.")
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(pendingIntent)
            .setFullScreenIntent(pendingIntent, true)
            .setPriority(Notification.PRIORITY_MAX)
            .setCategory(Notification.CATEGORY_ALARM)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setOngoing(false)
            .build()
    }

    private fun showWakeNotification() {
        try {
            val now = System.currentTimeMillis()
            if (now - lastWakeAt < 700L) {
                // Permite o primeiro alerta do wake atual, mas evita duplicações imediatas do Android.
            }

            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(WAKE_NOTIFICATION_ID, buildWakeNotification())
        } catch (_: Exception) {
        }
    }

    private fun buildNotification(text: String = "Presença ativa. Diga: ok Megan."): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        val pendingIntentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        val pendingIntent = PendingIntent.getActivity(this, 0, openAppIntent, pendingIntentFlags)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Megan ativa")
            .setContentText(text)
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
