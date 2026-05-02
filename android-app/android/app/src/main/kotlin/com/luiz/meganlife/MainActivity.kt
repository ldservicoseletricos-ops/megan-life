package com.luiz.meganlife

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {

    private val CHANNEL = "megan.apps"
    private val ACCESS_CHANNEL = "megan.accessibility"

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
    }
}