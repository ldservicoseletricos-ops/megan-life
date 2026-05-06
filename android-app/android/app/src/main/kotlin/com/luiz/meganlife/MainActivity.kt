package com.luiz.meganlife

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.provider.AlarmClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {

    companion object {
        @Volatile
        private var pendingNativeWakeDetected: Boolean = false

        fun markNativeWakeDetected() {
            pendingNativeWakeDetected = true
        }

        fun consumeNativeWakeDetected(): Boolean {
            val value = pendingNativeWakeDetected
            pendingNativeWakeDetected = false
            return value
        }
    }


    private val CHANNEL = "megan.apps"
    private val ACCESS_CHANNEL = "megan.accessibility"
    private val PRESENCE_CHANNEL = "megan.presence"
    private val SYSTEM_CHANNEL = "megan.system"
    private val REMINDER_CHANNEL = "megan.reminders"
    private val ALARM_CHANNEL = "megan.alarm"
    private val WAKE_EVENT_CHANNEL = "megan.wake_event"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureNativeWakeIntent(intent)
        handleOpenAppIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureNativeWakeIntent(intent)
        handleOpenAppIntent(intent)
    }

    private fun captureNativeWakeIntent(intent: Intent?) {
        if (intent?.getBooleanExtra("nativeWakeDetected", false) == true) {
            markNativeWakeDetected()
        }
    }

    private fun handleOpenAppIntent(intent: Intent?) {
        val packageName = intent?.getStringExtra("open_app_package") ?: return
        openInstalledApp(packageName)
    }

    private fun openInstalledApp(packageName: String): Boolean {
        return try {
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)

            if (launchIntent != null) {
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                startActivity(launchIntent)
                true
            } else {
                false
            }
        } catch (_: Exception) {
            false
        }
    }


    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 🔥 APPS
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->

                when (call.method) {

                    "getInstalledApps" -> {
                        val pm = packageManager
                        val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)

                        val list = apps
                            .filter {
                                (it.flags and ApplicationInfo.FLAG_SYSTEM) == 0
                            }
                            .map {
                                mapOf(
                                    "name" to pm.getApplicationLabel(it).toString().lowercase(),
                                    "package" to it.packageName
                                )
                            }

                        result.success(list)
                    }

                    "openApp" -> {
                        val packageName = call.argument<String>("package")

                        if (packageName.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }

                        result.success(openInstalledApp(packageName))
                    }

                    else -> result.notImplemented()
                }
            }

        // 🔥 ACCESSIBILITY
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ACCESS_CHANNEL)
            .setMethodCallHandler { call, result ->

                val service = MeganAccessibilityService.instance

                if (service == null) {
                    result.success(false)
                    return@setMethodCallHandler
                }

                when (call.method) {

                    "action" -> {
                        val action = call.argument<String>("type")
                        if (action.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }

                        service.performAction(action)
                        result.success(true)
                    }

                    "openApp" -> {
                        val packageName = call.argument<String>("package")
                        if (packageName.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }

                        result.success(service.openApp(packageName))
                    }

                    else -> result.notImplemented()
                }
            }

        // 🔥 6.1.1 — PRESENÇA REAL / FOREGROUND SERVICE
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PRESENCE_CHANNEL)
            .setMethodCallHandler { call, result ->

                when (call.method) {

                    "startPresence" -> {
                        val intent = Intent(this, MeganPresenceService::class.java).apply {
                            action = MeganPresenceService.ACTION_START
                        }

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }

                        result.success(true)
                    }

                    "stopPresence" -> {
                        val intent = Intent(this, MeganPresenceService::class.java).apply {
                            action = MeganPresenceService.ACTION_STOP
                        }

                        startService(intent)
                        result.success(true)
                    }

                    "presenceStatus" -> {
                        result.success(MeganPresenceService.isRunning)
                    }

                    else -> result.notImplemented()
                }
            }


        // 🔥 6.3 — CENTRAL DE PERMISSÕES / CONFIGURAÇÕES DO SISTEMA
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_CHANNEL)
            .setMethodCallHandler { call, result ->

                try {
                    when (call.method) {

                        "openBatterySettings" -> {
                            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        }

                        "openAppSettings" -> {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        }

                        "openAccessibilitySettings" -> {
                            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        }

                        // 🔥 6.4 — AUTO-RETORNO INTELIGENTE
                        "bringToFront" -> {
                            val intent = Intent(this, MainActivity::class.java).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                                addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                            }
                            startActivity(intent)
                            result.success(true)
                        }

                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.success(false)
                }
            }


        // ⏰ LEMBRETES / ALERTAS REAIS DO ANDROID
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, REMINDER_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "scheduleReminder" -> {
                            val id = call.argument<Int>("id") ?: System.currentTimeMillis().toInt()
                            val title = call.argument<String>("title") ?: "Megan Life"
                            val body = call.argument<String>("body") ?: "Lembrete da Megan"
                            val triggerMillis = call.argument<Long>("triggerMillis")
                                ?: (call.argument<Int>("triggerMillis")?.toLong())

                            if (triggerMillis == null) {
                                result.success(false)
                                return@setMethodCallHandler
                            }

                            val intent = Intent(this, MeganReminderReceiver::class.java).apply {
                                putExtra("title", title)
                                putExtra("body", body)
                                putExtra("id", id)
                            }

                            val pendingIntent = PendingIntent.getBroadcast(
                                this,
                                id,
                                intent,
                                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                            )

                            val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !alarmManager.canScheduleExactAlarms()) {
                                alarmManager.setAndAllowWhileIdle(
                                    AlarmManager.RTC_WAKEUP,
                                    triggerMillis,
                                    pendingIntent
                                )
                            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                alarmManager.setExactAndAllowWhileIdle(
                                    AlarmManager.RTC_WAKEUP,
                                    triggerMillis,
                                    pendingIntent
                                )
                            } else {
                                alarmManager.setExact(
                                    AlarmManager.RTC_WAKEUP,
                                    triggerMillis,
                                    pendingIntent
                                )
                            }

                            result.success(true)
                        }

                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.success(false)
                }
            }



        // ⏰ DESPERTADOR REAL DO CELULAR
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ALARM_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "setAlarm" -> {
                            val hour = call.argument<Int>("hour") ?: 7
                            val minute = call.argument<Int>("minute") ?: 0
                            val message = call.argument<String>("message") ?: "Alarme Megan"
                            val skipUi = call.argument<Boolean>("skipUi") ?: true

                            if (hour !in 0..23 || minute !in 0..59) {
                                result.success(false)
                                return@setMethodCallHandler
                            }

                            val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
                                putExtra(AlarmClock.EXTRA_HOUR, hour)
                                putExtra(AlarmClock.EXTRA_MINUTES, minute)
                                putExtra(AlarmClock.EXTRA_MESSAGE, message)
                                putExtra(AlarmClock.EXTRA_SKIP_UI, skipUi)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }

                            if (intent.resolveActivity(packageManager) != null) {
                                startActivity(intent)
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        }

                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.success(false)
                }
            }



        // 🎙️ EVENTO NATIVO DE WAKE WORD / OPÇÃO A
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WAKE_EVENT_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getAndClearNativeWake" -> {
                            result.success(consumeNativeWakeDetected())
                        }

                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.success(false)
                }
            }

    }
}
