package com.player.player

import android.os.Build
import android.os.Bundle
import android.view.Display
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity

/**
 * Базовый AudioServiceActivity + явный запрос максимальной частоты
 * обновления у системы.
 *
 * По умолчанию Android (особенно на устройствах с переменной частотой
 * — Realme/OnePlus/Xiaomi) не даёт приложению 120 Hz, пока оно само
 * об этом не попросит. Без этого Flutter-приложение рендерится на
 * 60 Hz даже если телефон поддерживает 90/120 Hz.
 *
 * Здесь мы при старте находим максимальный режим экрана с тем же
 * физическим разрешением, что и текущий, и просим систему отдать
 * приложение в этом режиме. Если устройство не поддерживает выбор
 * режимов (старая прошивка / fallback) — мы остаёмся на дефолте,
 * никаких эксепшенов.
 */
class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyHighRefreshRate()
    }

    private fun applyHighRefreshRate() {
        try {
            val display: Display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display ?: return
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay ?: return
            }

            val current = display.mode
            val modes = display.supportedModes
            if (modes.isEmpty()) return

            // Ищем режим с тем же физическим разрешением и максимальной
            // частотой обновления. Менять разрешение мы не хотим —
            // это вызывает перерисовку и хуже выглядит.
            val best = modes
                .filter {
                    it.physicalWidth == current.physicalWidth &&
                            it.physicalHeight == current.physicalHeight
                }
                .maxByOrNull { it.refreshRate }
                ?: return

            val params: WindowManager.LayoutParams = window.attributes
            params.preferredDisplayModeId = best.modeId
            // Подсказка для прошивок OPPO/Realme/OnePlus, которые
            // иногда игнорируют preferredDisplayModeId, но уважают
            // preferredRefreshRate.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                params.preferredRefreshRate = best.refreshRate
            }
            window.attributes = params
        } catch (_: Throwable) {
            // best-effort; на любой случай — молча остаёмся на дефолте.
        }
    }
}
