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

class MeganPresenceService : Service(), TextToSpeech.OnInitListener {

    companion object {
        const val ACTION_START = "com.luiz.meganlife.presence.START"
        const val ACTION_STOP = "com.luiz.meganlife.presence.STOP"

        private const val CHANNEL_ID = "megan_presence_channel"
        private const val CHANNEL_NAME = "Megan escuta segura"
        private const val NOTIFICATION_ID = 6101
        private const val WAKE_CHANNEL_ID = "megan_wake_alert_channel"
        private const val WAKE_CHANNEL_NAME = "Megan Wake Alert"
        private const val WAKE_NOTIFICATION_ID = 6102
        private const val WAKE_LOCK_TAG = "MeganLife:PresenceWakeLock"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var wakeLock: PowerManager.WakeLock? = null
    private var tts: TextToSpeech? = null
    private var speechRecognizer: SpeechRecognizer? = null

    @Volatile
    private var isListeningCommand: Boolean = false

    @Volatile
    private var ttsReady: Boolean = false

    @Volatile
    private var awaitingCommandAfterWake: Boolean = false

    private var commandWindowUntil: Long = 0L
    private var lastRestartAt: Long = 0L
    private var lastWakeAt: Long = 0L
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
        if (isRunning && isListeningCommand) {
            updateNotificationText("Presença ativa. Diga: ok Megan e o comando.", throttle = true)
            return
        }

        isRunning = true
        awaitingCommandAfterWake = false
        commandWindowUntil = 0L
        acquireWakeLockSafely()

        startForeground(
            NOTIFICATION_ID,
            buildNotification("Presença ativa. Diga: ok Megan e o comando.")
        )

        restartSpeechLoop(delayMs = 600L, force = true)
    }

    private fun stopPresence() {
        isRunning = false
        awaitingCommandAfterWake = false
        commandWindowUntil = 0L
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

    private fun restartSpeechLoop(delayMs: Long = 900L, force: Boolean = false) {
        if (!isRunning) return

        val now = System.currentTimeMillis()
        if (!force && now - lastRestartAt < 450L) return
        lastRestartAt = now

        mainHandler.postDelayed({
            if (!isRunning) return@postDelayed
            startCommandListening()
        }, delayMs)
    }

    private fun startCommandListening() {
        mainHandler.post {
            if (!isRunning) return@post

            if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                updateNotificationText("Microfone sem permissão. Ative para usar a presença da Megan.")
                restartSpeechLoop(delayMs = 5000L, force = true)
                return@post
            }

            try {
                if (!SpeechRecognizer.isRecognitionAvailable(this)) {
                    updateNotificationText("Reconhecimento de fala indisponível neste aparelho.", throttle = true)
                    restartSpeechLoop(delayMs = 6000L, force = true)
                    return@post
                }

                stopCommandRecognizer()
                speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this)

                val listenIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, "pt-BR")
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "pt-BR")
                    putExtra(RecognizerIntent.EXTRA_ONLY_RETURN_LANGUAGE_PREFERENCE, false)
                    putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                    putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)
                    putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 1900L)
                    putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1400L)
                    putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 2500L)
                }

                speechRecognizer?.setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(params: Bundle?) {
                        isListeningCommand = true

                        if (awaitingCommandAfterWake || isCommandWindowOpen()) {
                            awaitingCommandAfterWake = true
                            updateNotificationText("Megan acordada. Fale seu comando agora.", throttle = true)
                        } else {
                            awaitingCommandAfterWake = false
                            updateNotificationText("Presença ativa. Diga: ok Megan e o comando.", throttle = true)
                        }
                    }

                    override fun onBeginningOfSpeech() {
                        updateNotificationText("Ouvindo...", throttle = true)
                    }

                    override fun onRmsChanged(rmsdB: Float) {}

                    override fun onBufferReceived(buffer: ByteArray?) {}

                    override fun onEndOfSpeech() {
                        updateNotificationText("Processando comando.", throttle = true)
                    }

                    override fun onError(error: Int) {
                        isListeningCommand = false

                        when (error) {
                            SpeechRecognizer.ERROR_NO_MATCH,
                            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> {
                                if (awaitingCommandAfterWake || isCommandWindowOpen()) {
                                    awaitingCommandAfterWake = true
                                    updateNotificationText("Megan acordada. Fale seu comando agora.", throttle = true)
                                    restartSpeechLoop(delayMs = 350L, force = true)
                                } else {
                                    awaitingCommandAfterWake = false
                                    commandWindowUntil = 0L
                                    updateNotificationText("Presença ativa. Diga: ok Megan e o comando.", throttle = true)
                                    restartSpeechLoop(delayMs = 900L, force = true)
                                }
                            }

                            SpeechRecognizer.ERROR_AUDIO -> {
                                updateNotificationText("Microfone ocupado. Vou tentar novamente.", throttle = true)
                                restartSpeechLoop(delayMs = if (awaitingCommandAfterWake || isCommandWindowOpen()) 700L else 2200L, force = true)
                            }

                            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> {
                                stopCommandRecognizer()
                                updateNotificationText("Reconhecimento ocupado. Reiniciando escuta.", throttle = true)
                                restartSpeechLoop(delayMs = if (awaitingCommandAfterWake || isCommandWindowOpen()) 700L else 1700L, force = true)
                            }

                            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
                                awaitingCommandAfterWake = false
                                commandWindowUntil = 0L
                                updateNotificationText("Permissão de microfone insuficiente.")
                                restartSpeechLoop(delayMs = 5000L, force = true)
                            }

                            SpeechRecognizer.ERROR_NETWORK,
                            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> {
                                updateNotificationText("Reconhecimento de fala sem conexão agora.", throttle = true)
                                restartSpeechLoop(delayMs = if (awaitingCommandAfterWake || isCommandWindowOpen()) 900L else 2500L, force = true)
                            }

                            else -> {
                                updateNotificationText("Reiniciando escuta da Megan.", throttle = true)
                                restartSpeechLoop(delayMs = if (awaitingCommandAfterWake || isCommandWindowOpen()) 700L else 1600L, force = true)
                            }
                        }
                    }

                    override fun onResults(results: Bundle?) {
                        isListeningCommand = false

                        val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        val command = selectBestCommand(matches)

                        handleNativeCommand(command)
                    }

                    override fun onPartialResults(partialResults: Bundle?) {
                        val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        val partial = matches
                            ?.firstOrNull()
                            ?.trim()
                            ?.lowercase(Locale("pt", "BR"))
                            ?: ""

                        if (!awaitingCommandAfterWake && !isCommandWindowOpen() && partial.isNotBlank() && looksLikeWakeCommand(partial)) {
                            updateNotificationText("Megan acordada. Continue falando.", throttle = true)
                        }
                    }

                    override fun onEvent(eventType: Int, params: Bundle?) {}
                })

                isListeningCommand = true
                speechRecognizer?.startListening(listenIntent)
            } catch (_: Exception) {
                isListeningCommand = false
                updateNotificationText("Não consegui iniciar a escuta. Tentando novamente.", throttle = true)
                restartSpeechLoop(delayMs = if (awaitingCommandAfterWake || isCommandWindowOpen()) 700L else 2500L, force = true)
            }
        }
    }

    private fun selectBestCommand(matches: ArrayList<String>?): String {
        val options = matches
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?: emptyList()

        if (options.isEmpty()) return ""

        val timeOption = options.firstOrNull { isTimeCommand(it) }
        if (timeOption != null) return timeOption.lowercase(Locale("pt", "BR"))

        val dateOption = options.firstOrNull { isDateCommand(it) }
        if (dateOption != null) return dateOption.lowercase(Locale("pt", "BR"))

        val wakeOption = options.firstOrNull { looksLikeWakeCommand(it) }
        if (wakeOption != null) return wakeOption.lowercase(Locale("pt", "BR"))

        return options.first().lowercase(Locale("pt", "BR"))
    }

    private fun handleNativeCommand(command: String) {
        val clean = normalize(command)

        if (clean.isBlank()) {
            if (awaitingCommandAfterWake || isCommandWindowOpen()) {
                awaitingCommandAfterWake = true
                updateNotificationText("Megan acordada. Fale seu comando agora.", throttle = true)
                restartSpeechLoop(delayMs = 350L, force = true)
            } else {
                awaitingCommandAfterWake = false
                commandWindowUntil = 0L
                updateNotificationText("Presença ativa. Diga: ok Megan e o comando.", throttle = true)
                restartSpeechLoop(delayMs = 900L, force = true)
            }
            return
        }

        // Correção principal:
        // Depois que "ok Megan" foi detectado, aceita o próximo texto como comando
        // mesmo que o tempo da janela tenha oscilado entre callbacks do Android.
        if (awaitingCommandAfterWake) {
            awaitingCommandAfterWake = false
            commandWindowUntil = 0L
            handleRealCommand(clean)
            return
        }

        if (isCommandWindowOpen()) {
            awaitingCommandAfterWake = false
            commandWindowUntil = 0L
            handleRealCommand(clean)
            return
        }

        if (!looksLikeWakeCommand(clean)) {
            updateNotificationText("Presença ativa. Aguardando ok Megan.", throttle = true)
            restartSpeechLoop(delayMs = 900L, force = true)
            return
        }

        val realCommand = extractCommandAfterWake(clean)

        if (realCommand.isBlank()) {
            activateCommandWindow()
            return
        }

        awaitingCommandAfterWake = false
        commandWindowUntil = 0L
        handleRealCommand(realCommand)
    }

    private fun isCommandWindowOpen(): Boolean {
        return awaitingCommandAfterWake && System.currentTimeMillis() <= commandWindowUntil
    }

    private fun activateCommandWindow() {
        val now = System.currentTimeMillis()

        if (now - lastWakeAt < 1800L) return

        lastWakeAt = now
        awaitingCommandAfterWake = true
        commandWindowUntil = now + 15000L
        MainActivity.markNativeWakeDetected()

        showWakeNotification()
        updateNotificationText("Megan acordada. Fale seu comando agora.", throttle = true)
        speakNative("Pode falar.")

        stopCommandRecognizer()
        restartSpeechLoop(delayMs = 550L, force = true)

        mainHandler.postDelayed({
            if (awaitingCommandAfterWake && System.currentTimeMillis() > commandWindowUntil) {
                awaitingCommandAfterWake = false
                commandWindowUntil = 0L
                updateNotificationText("Presença ativa. Diga: ok Megan e o comando.", throttle = true)
                restartSpeechLoop(delayMs = 900L, force = true)
            }
        }, 15500L)
    }

    private fun handleRealCommand(command: String) {
        val realCommand = normalize(command)

        if (realCommand.isBlank()) {
            updateNotificationText("Comando vazio. Diga: ok Megan e fale o comando.", throttle = true)
            restartSpeechLoop(delayMs = 900L, force = true)
            return
        }

        MainActivity.markNativeWakeDetected()
        updateNotificationText("Comando: $realCommand")

        when {
            isTimeCommand(realCommand) -> {
                val time = SimpleDateFormat("HH:mm", Locale("pt", "BR")).format(Date())
                speakNative("Agora são $time.")
            }

            isDateCommand(realCommand) -> {
                val date = SimpleDateFormat("dd/MM/yyyy", Locale("pt", "BR")).format(Date())
                speakNative("Hoje é $date.")
            }

            realCommand.contains("seu nome") ||
                realCommand.contains("qual seu nome") ||
                realCommand.contains("quem e voce") -> {
                speakNative("Eu sou a Megan Life, sua assistente.")
            }

            realCommand.contains("teste") || realCommand.contains("funcionando") -> {
                speakNative("Estou funcionando em segundo plano, Luiz.")
            }

            realCommand.contains("parar") ||
                realCommand.contains("desativar presenca") ||
                realCommand.contains("desliga presenca") -> {
                speakNative("Tudo bem, Luiz. Vou desativar a presença segura.")
                mainHandler.postDelayed({
                    stopPresence()
                }, 1400L)
                return
            }

            realCommand.contains("abrir megan") ||
                realCommand.contains("abre megan") ||
                realCommand.contains("abrir o app") ||
                realCommand.contains("abre o app") -> {
                speakNative("Abrindo a Megan.")
                openMainActivity()
            }

            else -> {
                speakNative("Não entendi esse comando, Luiz. Pode repetir com poucas palavras.")
            }
        }

        mainHandler.postDelayed({
            if (isRunning) {
                awaitingCommandAfterWake = false
                commandWindowUntil = 0L
                restartSpeechLoop(delayMs = 1200L, force = true)
            }
        }, 1700L)
    }

    private fun isTimeCommand(text: String): Boolean {
        val command = normalize(text)

        return command.contains("hora") ||
            command.contains("horas") ||
            command.contains("horario") ||
            command.contains("que ora") ||
            command.contains("que oras") ||
            command.contains("que horas sao") ||
            command.contains("que hora e") ||
            command.contains("que horas e") ||
            command.contains("agora sao") ||
            command.contains("sao que horas") ||
            command == "agora"
    }

    private fun isDateCommand(text: String): Boolean {
        val command = normalize(text)

        return command.contains("data") ||
            command.contains("dia e hoje") ||
            command.contains("dia hoje") ||
            command.contains("que dia e") ||
            command.contains("que dia e hoje") ||
            command.contains("qual e a data")
    }

    private fun looksLikeWakeCommand(text: String): Boolean {
        val clean = normalize(text)
        return clean.contains("ok megan") ||
            clean.contains("oi megan") ||
            clean.contains("ok mega") ||
            clean.contains("oi mega") ||
            clean == "megan" ||
            clean.startsWith("megan ")
    }

    private fun extractCommandAfterWake(text: String): String {
        var clean = normalize(text)

        val wakeWords = listOf(
            "ok megan",
            "oi megan",
            "ok mega",
            "oi mega",
            "megan"
        )

        for (wake in wakeWords) {
            val index = clean.indexOf(wake)
            if (index >= 0) {
                clean = clean.substring(index + wake.length).trim()
                break
            }
        }

        return clean
            .removePrefix(",")
            .removePrefix(".")
            .removePrefix("-")
            .trim()
    }

    private fun normalize(text: String): String {
        return text
            .lowercase(Locale("pt", "BR"))
            .replace("á", "a")
            .replace("à", "a")
            .replace("ã", "a")
            .replace("â", "a")
            .replace("é", "e")
            .replace("ê", "e")
            .replace("í", "i")
            .replace("ó", "o")
            .replace("ô", "o")
            .replace("õ", "o")
            .replace("ú", "u")
            .replace("ç", "c")
            .replace(Regex("\\s+"), " ")
            .trim()
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
            description = "Mantém a presença segura da Megan Life com reconhecimento de voz em foreground."
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
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(WAKE_NOTIFICATION_ID, buildWakeNotification())
        } catch (_: Exception) {
        }
    }

    private fun buildNotification(text: String = "Presença ativa. Diga: ok Megan e o comando."): Notification {
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
