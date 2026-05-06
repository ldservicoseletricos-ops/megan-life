package com.luiz.meganlife

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
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

        val appOption = options.firstOrNull { isAnyOpenExternalAppCommand(it) }
        if (appOption != null) return appOption.lowercase(Locale("pt", "BR"))

        val greetingOption = options.firstOrNull { isGreetingCommand(it) }
        if (greetingOption != null) return greetingOption.lowercase(Locale("pt", "BR"))

        val identityOption = options.firstOrNull { isIdentityCommand(it) }
        if (identityOption != null) return identityOption.lowercase(Locale("pt", "BR"))

        val statusOption = options.firstOrNull { isStatusCommand(it) }
        if (statusOption != null) return statusOption.lowercase(Locale("pt", "BR"))

        val stopOption = options.firstOrNull { isStopPresenceCommand(it) }
        if (stopOption != null) return stopOption.lowercase(Locale("pt", "BR"))

        val openMeganOption = options.firstOrNull { isOpenMeganCommand(it) }
        if (openMeganOption != null) return openMeganOption.lowercase(Locale("pt", "BR"))

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

            isAnyOpenExternalAppCommand(realCommand) -> {
                val appName = extractAppNameFromOpenCommand(realCommand)
                val packageName = findInstalledPackageForAppName(appName)

                if (packageName != null) {
                    speakNative("Abrindo $appName.")
                    openAppFromBackground(packageName)
                } else {
                    speakNative("Não encontrei $appName instalado, Luiz.")
                }
            }

            isGreetingCommand(realCommand) -> {
                speakNative("Olá Luiz. Estou ouvindo. Como posso ajudar?")
            }

            isIdentityCommand(realCommand) -> {
                speakNative("Eu sou a Megan Life, sua assistente.")
            }

            isStatusCommand(realCommand) -> {
                speakNative("Estou funcionando em segundo plano, Luiz.")
            }

            isOpenMeganCommand(realCommand) -> {
                speakNative("Abrindo a Megan.")
                openMainActivity()
            }

            isStopPresenceCommand(realCommand) -> {
                speakNative("Tudo bem, Luiz. Vou desativar a presença segura.")
                mainHandler.postDelayed({
                    stopPresence()
                }, 1400L)
                return
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

    private fun isGreetingCommand(text: String): Boolean {
        val command = normalize(text)

        return command == "oi" ||
            command == "ola" ||
            command == "olá" ||
            command.contains("bom dia") ||
            command.contains("boa tarde") ||
            command.contains("boa noite") ||
            command.contains("tudo bem")
    }

    private fun isIdentityCommand(text: String): Boolean {
        val command = normalize(text)

        return command.contains("seu nome") ||
            command.contains("qual seu nome") ||
            command.contains("quem e voce") ||
            command.contains("quem voce e") ||
            command.contains("quem é você")
    }

    private fun isStatusCommand(text: String): Boolean {
        val command = normalize(text)

        return command.contains("teste") ||
            command.contains("funcionando") ||
            command.contains("esta ai") ||
            command.contains("esta ouvindo") ||
            command.contains("me escuta") ||
            command.contains("me ouve")
    }

    private fun isOpenMeganCommand(text: String): Boolean {
        val command = normalize(text)

        return command.contains("abrir megan") ||
            command.contains("abre megan") ||
            command.contains("abrir o app") ||
            command.contains("abre o app") ||
            command.contains("abrir aplicativo") ||
            command.contains("abre aplicativo")
    }

    private fun isStopPresenceCommand(text: String): Boolean {
        val command = normalize(text)

        return command.contains("parar presenca") ||
            command.contains("desativar presenca") ||
            command.contains("desliga presenca") ||
            command.contains("desligar presenca") ||
            command.contains("parar de ouvir") ||
            command.contains("pare de ouvir")
    }

    private fun isAnyOpenExternalAppCommand(text: String): Boolean {
        val command = normalize(text)

        return command.startsWith("abrir ") ||
            command.startsWith("abre ") ||
            command.startsWith("iniciar ") ||
            command.startsWith("executar ") ||
            command.contains("abrir aplicativo ") ||
            command.contains("abrir app ") ||
            command.contains("abre aplicativo ") ||
            command.contains("abre app ") ||
            isOpenWhatsAppCommand(command) ||
            isOpenWhatsAppBusinessCommand(command) ||
            isOpenWazeCommand(command) ||
            isOpenMapsCommand(command) ||
            isOpenYouTubeCommand(command)
    }

    private fun extractAppNameFromOpenCommand(text: String): String {
        var command = normalize(text)

        val patterns = listOf(
            "abrir o aplicativo ",
            "abrir aplicativo ",
            "abrir o app ",
            "abrir app ",
            "abrir ",
            "abre o aplicativo ",
            "abre aplicativo ",
            "abre o app ",
            "abre app ",
            "abre ",
            "iniciar o aplicativo ",
            "iniciar aplicativo ",
            "iniciar o app ",
            "iniciar app ",
            "iniciar ",
            "executar o aplicativo ",
            "executar aplicativo ",
            "executar o app ",
            "executar app ",
            "executar "
        )

        for (pattern in patterns) {
            if (command.contains(pattern)) {
                command = command.substringAfter(pattern).trim()
                break
            }
        }

        command = command
            .removePrefix("o ")
            .removePrefix("a ")
            .removePrefix("app ")
            .removePrefix("aplicativo ")
            .trim()

        return when (command) {
            "zap", "wpp" -> "whatsapp"
            "zap business", "wpp business", "business" -> "whatsapp business"
            "insta" -> "instagram"
            "yt", "you tube" -> "youtube"
            "mapa", "maps" -> "google maps"
            "rvx", "revanced", "youtube rvx", "youtube revanced" -> "rvx"
            else -> command
        }
    }

    private fun findInstalledPackageForAppName(appName: String): String? {
        val target = normalize(appName)
        if (target.isBlank()) return null

        val knownPackages = mapOf(
            "whatsapp" to "com.whatsapp",
            "zap" to "com.whatsapp",
            "wpp" to "com.whatsapp",
            "whatsapp business" to "com.whatsapp.w4b",
            "zap business" to "com.whatsapp.w4b",
            "wpp business" to "com.whatsapp.w4b",
            "waze" to "com.waze",
            "maps" to "com.google.android.apps.maps",
            "google maps" to "com.google.android.apps.maps",
            "mapa" to "com.google.android.apps.maps",
            "youtube" to "com.google.android.youtube",
            "you tube" to "com.google.android.youtube",
            "yt" to "com.google.android.youtube",
            "spotify" to "com.spotify.music",
            "instagram" to "com.instagram.android",
            "insta" to "com.instagram.android",
            "telegram" to "org.telegram.messenger",
            "gmail" to "com.google.android.gm",
            "nubank" to "com.nu.production",
            "rvx" to "app.rvx.android.youtube",
            "revanced" to "app.revanced.android.youtube"
        )

        knownPackages[target]?.let { packageName ->
            if (isPackageLaunchable(packageName)) return packageName
        }

        val launcherApps = getLaunchableApps()
        val compactTarget = target.replace(" ", "")
        var bestPackage: String? = null
        var bestScore = 0

        for (item in launcherApps) {
            val label = normalize(item.first)
            val packageName = item.second
            val compactLabel = label.replace(" ", "")
            val compactPackage = normalize(packageName).replace(" ", "")

            if (label.isBlank() || packageName.isBlank()) continue

            val score = when {
                label == target || compactLabel == compactTarget -> 140
                label.contains(target) || compactLabel.contains(compactTarget) -> 120
                target.contains(label) || compactTarget.contains(compactLabel) -> 105
                packageName.contains(target, ignoreCase = true) ||
                    compactPackage.contains(compactTarget) -> 100
                isRvxMatch(target, label, packageName) -> 130
                wordsMatch(target, label) -> 85
                else -> 0
            }

            if (score > bestScore) {
                bestScore = score
                bestPackage = packageName
            }
        }

        return if (bestScore >= 85) bestPackage else null
    }

    private fun getLaunchableApps(): List<Pair<String, String>> {
        val result = mutableListOf<Pair<String, String>>()

        try {
            val launcherIntent = Intent(Intent.ACTION_MAIN, null).apply {
                addCategory(Intent.CATEGORY_LAUNCHER)
            }

            val activities: List<ResolveInfo> = packageManager.queryIntentActivities(
                launcherIntent,
                PackageManager.MATCH_ALL
            )

            for (resolveInfo in activities) {
                val activityInfo = resolveInfo.activityInfo ?: continue
                val packageName = activityInfo.packageName ?: continue
                val label = resolveInfo.loadLabel(packageManager)?.toString()
                    ?: activityInfo.loadLabel(packageManager)?.toString()
                    ?: packageName

                if (packageName.isNotBlank()) {
                    result.add(label to packageName)
                }
            }
        } catch (_: Exception) {
        }

        return result.distinctBy { it.second }
    }

    private fun isRvxMatch(target: String, label: String, packageName: String): Boolean {
        val compactTarget = target.replace(" ", "")
        val compactLabel = label.replace(" ", "")
        val compactPackage = packageName.lowercase(Locale("pt", "BR"))

        if (compactTarget == "rvx" || compactTarget == "revanced") {
            return compactLabel.contains("rvx") ||
                compactLabel.contains("revanced") ||
                compactPackage.contains("rvx") ||
                compactPackage.contains("revanced")
        }

        return false
    }

    private fun wordsMatch(input: String, label: String): Boolean {
        val inputWords = input.split(" ").filter { it.length >= 2 }
        val labelWords = label.split(" ").filter { it.length >= 2 }

        if (inputWords.isEmpty() || labelWords.isEmpty()) return false

        var hits = 0

        for (inputWord in inputWords) {
            if (labelWords.any { labelWord ->
                    labelWord == inputWord ||
                        labelWord.contains(inputWord) ||
                        inputWord.contains(labelWord)
                }) {
                hits++
            }
        }

        return hits >= 1 && hits == inputWords.size
    }

    private fun isPackageLaunchable(packageName: String): Boolean {
        return try {
            packageManager.getLaunchIntentForPackage(packageName) != null
        } catch (_: Exception) {
            false
        }
    }

    private fun isOpenWhatsAppCommand(text: String): Boolean {
        val command = normalize(text)
        return command.contains("abrir whatsapp") ||
            command.contains("abre whatsapp") ||
            command.contains("abrir zap") ||
            command.contains("abre zap") ||
            command == "whatsapp" ||
            command == "zap"
    }

    private fun isOpenWhatsAppBusinessCommand(text: String): Boolean {
        val command = normalize(text)
        return command.contains("whatsapp business") ||
            command.contains("zap business") ||
            command.contains("abrir business") ||
            command.contains("abre business")
    }

    private fun isOpenWazeCommand(text: String): Boolean {
        val command = normalize(text)
        return command.contains("abrir waze") ||
            command.contains("abre waze") ||
            command == "waze"
    }

    private fun isOpenMapsCommand(text: String): Boolean {
        val command = normalize(text)
        return command.contains("google maps") ||
            command.contains("abrir maps") ||
            command.contains("abre maps") ||
            command.contains("abrir mapa") ||
            command.contains("abre mapa") ||
            command.contains("abrir google mapas") ||
            command.contains("abre google mapas")
    }

    private fun isOpenYouTubeCommand(text: String): Boolean {
        val command = normalize(text)
        return command.contains("abrir youtube") ||
            command.contains("abre youtube") ||
            command.contains("abrir you tube") ||
            command.contains("abre you tube") ||
            command == "youtube" ||
            command == "you tube"
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

    private fun openAppFromBackground(packageName: String) {
        try {
            val openedByAccessibility = MeganAccessibilityService.instance?.openApp(packageName) == true

            if (openedByAccessibility) {
                return
            }

            MainActivity.markNativeWakeDetected()

            val intent = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                putExtra("nativeWakeDetected", true)
                putExtra("open_app_package", packageName)
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
