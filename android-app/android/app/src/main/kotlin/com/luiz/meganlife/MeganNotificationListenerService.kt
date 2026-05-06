package com.luiz.meganlife

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MeganNotificationListenerService : NotificationListenerService() {

    companion object {
        private const val MAX_MESSAGES = 12
        private val latestMessages = mutableListOf<Map<String, String>>()

        @Synchronized
        fun getLatestWhatsAppMessages(): List<Map<String, String>> {
            return latestMessages.toList()
        }

        @Synchronized
        fun clearLatestWhatsAppMessages() {
            latestMessages.clear()
        }

        @Synchronized
        private fun saveMessage(sender: String, message: String, packageName: String) {
            val cleanSender = sender.trim()
            val cleanMessage = message.trim()

            if (cleanSender.isBlank() || cleanMessage.isBlank()) return
            if (cleanMessage.equals("null", ignoreCase = true)) return

            val now = SimpleDateFormat("HH:mm", Locale("pt", "BR")).format(Date())

            val item = mapOf(
                "sender" to cleanSender,
                "message" to cleanMessage,
                "package" to packageName,
                "time" to now
            )

            val duplicated = latestMessages.firstOrNull {
                it["sender"] == cleanSender && it["message"] == cleanMessage
            }

            if (duplicated != null) return

            latestMessages.add(0, item)

            while (latestMessages.size > MAX_MESSAGES) {
                latestMessages.removeAt(latestMessages.lastIndex)
            }
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)

        if (sbn == null) return

        val packageName = sbn.packageName ?: return
        if (packageName != "com.whatsapp" && packageName != "com.whatsapp.w4b") return

        val notification = sbn.notification ?: return
        val extras = notification.extras ?: return

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim().orEmpty()
        val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()?.trim().orEmpty()

        val sender = when {
            title.isNotBlank() -> title
            subText.isNotBlank() -> subText
            else -> "WhatsApp"
        }

        val message = when {
            bigText.isNotBlank() -> bigText
            text.isNotBlank() -> text
            else -> ""
        }

        if (message.contains("novas mensagens", ignoreCase = true)) return
        if (message.contains("mensagens", ignoreCase = true) && sender == "WhatsApp") return

        saveMessage(sender, message, packageName)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        super.onNotificationRemoved(sbn)
    }
}
