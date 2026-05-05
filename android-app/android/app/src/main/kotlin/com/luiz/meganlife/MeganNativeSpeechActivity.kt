package com.luiz.meganlife

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.WindowManager
import androidx.core.content.ContextCompat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MeganNativeSpeechActivity : Activity(), TextToSpeech.OnInitListener {

    private var speechRecognizer: SpeechRecognizer? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var alreadyStarted = false
    private var isFinishingSafely = false
    private var isListening = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        prepareInvisibleWindow()
        tts = TextToSpeech(this, this)
    }

    override fun onInit(status: Int) {
        ttsReady = status == TextToSpeech.SUCCESS

        if (ttsReady) {
            try {
                tts?.language = Locale("pt", "BR")
                tts?.setSpeechRate(0.94f)
                tts?.setPitch(1.04f)

                tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {
                    }

                    override fun onDone(utteranceId: String?) {
                        if (utteranceId == "megan_native_intro") {
                            runOnUiThread {
                                startCommandListening()
                            }
                        }
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        if (utteranceId == "megan_native_intro") {
                            runOnUiThread {
                                startCommandListening()
                            }
                        }
                    }

                    override fun onError(utteranceId: String?, errorCode: Int) {
                        if (utteranceId == "megan_native_intro") {
                            runOnUiThread {
                                startCommandListening()
                            }
                        }
                    }
                })
            } catch (_: Exception) {
            }
        }

        if (!alreadyStarted) {
            alreadyStarted = true
            speakAndListen()
        }
    }

    private fun prepareInvisibleWindow() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            }

            window.addFlags(
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )

            window.setDimAmount(0f)
            window.setLayout(1, 1)
        } catch (_: Exception) {
        }
    }

    private fun speakAndListen() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            speakNative("Luiz, preciso da permissão de microfone para ouvir o comando.")
            finishSoon(2500)
            return
        }

        if (ttsReady) {
            speakNative("Estou ouvindo, Luiz. Pode falar.", utteranceId = "megan_native_intro")
        } else {
            runOnUiThread {
                startCommandListening()
            }
        }
    }

    private fun startCommandListening() {
        if (isFinishingSafely || isListening) return

        try {
            if (!SpeechRecognizer.isRecognitionAvailable(this)) {
                speakNative("Reconhecimento de fala indisponível neste aparelho.")
                finishSoon(2500)
                return
            }

            speechRecognizer?.cancel()
            speechRecognizer?.destroy()

            speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this)

            val listenIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "pt-BR")
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "pt-BR")
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 1500L)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1200L)
            }

            speechRecognizer?.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {
                    isListening = true
                }

                override fun onBeginningOfSpeech() {
                }

                override fun onRmsChanged(rmsdB: Float) {
                }

                override fun onBufferReceived(buffer: ByteArray?) {
                }

                override fun onEndOfSpeech() {
                    isListening = false
                }

                override fun onError(error: Int) {
                    isListening = false

                    val answer = when (error) {
                        SpeechRecognizer.ERROR_NO_MATCH -> "Não entendi o comando, Luiz."
                        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "Não ouvi nenhum comando depois do chamado."
                        SpeechRecognizer.ERROR_AUDIO -> "Tive problema com o áudio do microfone."
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Permissão de microfone insuficiente."
                        SpeechRecognizer.ERROR_NETWORK,
                        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Reconhecimento de fala sem conexão agora."
                        else -> "Não consegui ouvir o comando agora."
                    }

                    speakNative(answer)
                    finishSoon(2600)
                }

                override fun onResults(results: Bundle?) {
                    isListening = false

                    val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    val command = matches
                        ?.firstOrNull()
                        ?.trim()
                        ?.lowercase(Locale("pt", "BR"))
                        ?: ""

                    handleNativeCommand(command)
                }

                override fun onPartialResults(partialResults: Bundle?) {
                }

                override fun onEvent(eventType: Int, params: Bundle?) {
                }
            })

            isListening = true
            speechRecognizer?.startListening(listenIntent)
        } catch (_: Exception) {
            isListening = false
            speakNative("Não consegui iniciar a escuta do comando.")
            finishSoon(2600)
        }
    }

    private fun handleNativeCommand(command: String) {
        val clean = command.trim().lowercase(Locale("pt", "BR"))

        if (clean.isBlank()) {
            speakNative("Não entendi o comando, Luiz.")
            finishSoon(2400)
            return
        }

        when {
            clean.contains("hora") || clean.contains("horas") -> {
                val time = SimpleDateFormat("HH:mm", Locale("pt", "BR")).format(Date())
                speakNative("Agora são $time.")
                finishSoon(2500)
            }

            clean.contains("seu nome") ||
                clean.contains("qual seu nome") ||
                clean.contains("quem é você") ||
                clean.contains("quem e voce") -> {
                speakNative("Eu sou a Megan Life, sua assistente.")
                finishSoon(2500)
            }

            clean.contains("teste") || clean.contains("funcionando") -> {
                speakNative("Estou funcionando em modo invisível, Luiz.")
                finishSoon(2500)
            }

            clean.contains("abrir megan") ||
                clean.contains("abre megan") ||
                clean.contains("abrir o app") ||
                clean.contains("abre o app") -> {
                speakNative("Abrindo a Megan.")
                openMainActivity()
                finishSoon(900)
            }

            clean.contains("parar") ||
                clean.contains("desativar presença") ||
                clean.contains("desliga presença") -> {
                speakNative("Tudo bem, Luiz. Vou desativar a presença segura.")
                stopPresenceService()
                finishSoon(1600)
            }

            else -> {
                speakNative("Entendi você dizendo: $clean. Vou abrir a Megan para continuar com inteligência completa.")
                openMainActivity()
                finishSoon(1800)
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
        }
    }

    private fun stopPresenceService() {
        try {
            val intent = Intent(this, MeganPresenceService::class.java).apply {
                action = MeganPresenceService.ACTION_STOP
            }
            startService(intent)
        } catch (_: Exception) {
        }
    }

    private fun speakNative(text: String, utteranceId: String = "megan_native_speech_${System.currentTimeMillis()}") {
        try {
            if (!ttsReady || text.isBlank()) return

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                tts?.speak(
                    text,
                    TextToSpeech.QUEUE_FLUSH,
                    null,
                    utteranceId
                )
            } else {
                @Suppress("DEPRECATION")
                tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null)
            }
        } catch (_: Exception) {
        }
    }

    private fun finishSoon(delayMs: Long) {
        Thread {
            try {
                Thread.sleep(delayMs)
            } catch (_: Exception) {
            }

            runOnUiThread {
                finishSafely()
            }
        }.start()
    }

    private fun finishSafely() {
        if (isFinishingSafely) return
        isFinishingSafely = true

        try {
            speechRecognizer?.cancel()
            speechRecognizer?.destroy()
        } catch (_: Exception) {
        } finally {
            speechRecognizer = null
            isListening = false
        }

        try {
            finish()
            overridePendingTransition(0, 0)
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        try {
            speechRecognizer?.cancel()
            speechRecognizer?.destroy()
        } catch (_: Exception) {
        } finally {
            speechRecognizer = null
            isListening = false
        }

        try {
            tts?.stop()
            tts?.shutdown()
        } catch (_: Exception) {
        } finally {
            tts = null
            ttsReady = false
        }

        super.onDestroy()
    }
}
