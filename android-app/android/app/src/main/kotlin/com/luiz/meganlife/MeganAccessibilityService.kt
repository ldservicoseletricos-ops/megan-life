package com.luiz.meganlife

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.view.accessibility.AccessibilityEvent

class MeganAccessibilityService : AccessibilityService() {

    companion object {
        var instance: MeganAccessibilityService? = null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    // 🔥 AÇÕES DO SISTEMA
    fun performAction(action: String) {
        when (action) {
            "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
            "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
            "recent" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
        }
    }

    // 🔥 CLIQUE NA TELA (expansão futura)
    fun tap(x: Float, y: Float) {
        val path = Path()
        path.moveTo(x, y)

        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 100))
            .build()

        dispatchGesture(gesture, null, null)
    }
}