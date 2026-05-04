package com.luiz.meganlife

import android.content.Intent
import android.net.Uri
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {

    private val CHANNEL = "megan.apps"
    private val ACCESS_CHANNEL = "megan.accessibility"
    private val PRESENCE_CHANNEL = "megan.presence"
    private val SYSTEM_CHANNEL = "megan.system"

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

                        val intent = packageManager.getLaunchIntentForPackage(packageName!!)

                        if (intent != null) {
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
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
                        service.performAction(action!!)
                        result.success(true)
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
    }
}
