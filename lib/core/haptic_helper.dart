import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vibration/vibration.dart';

import 'providers.dart'; // путь к вашему vibrationEnabledProvider

// ============================================================
//  Универсальный HapticHelper
// ============================================================

class HapticHelper {
  static bool _hasVibrator = false;
  static bool _hasAmplitude = false;
  static bool _checked = false;

  static Future<void> _ensureChecked() async {
    if (_checked) return;
    _checked = true;
  }

  /// Проверяет, включена ли вибрация в настройках.
  /// Если [ref] не передан — считаем, что вибрация разрешена.
  static bool _isEnabled(WidgetRef? ref) {
    if (ref == null) return true;
    return ref.read(vibrationEnabledProvider);
  }

  // ─────────────────────────────────────────────────────────────
  //  Базовые отклики
  // ─────────────────────────────────────────────────────────────

  /// Микро-отклик — для шагов progress bar, скролла и т.д.
  static Future<void> microTick({WidgetRef? ref}) async {
    if (!_isEnabled(ref)) return;
    await _ensureChecked();
    if (!_hasVibrator) {
      await HapticFeedback.selectionClick();
      return;
    }
    if (_hasAmplitude) {
      await Vibration.vibrate(duration: 5, amplitude: 40);
    } else {
      await Vibration.vibrate(duration: 5);
    }
  }

  /// Лёгкий отклик — обычный тап
  static Future<void> light({WidgetRef? ref}) async {
    if (!_isEnabled(ref)) return;
    await _ensureChecked();
    if (!_hasVibrator) {
      await HapticFeedback.lightImpact();
      return;
    }
    if (_hasAmplitude) {
      await Vibration.vibrate(duration: 10, amplitude: 80);
    } else {
      await Vibration.vibrate(duration: 10);
    }
  }

  /// Средний отклик — подтверждение действия
  static Future<void> medium({WidgetRef? ref}) async {
    if (!_isEnabled(ref)) return;
    await _ensureChecked();
    if (!_hasVibrator) {
      await HapticFeedback.mediumImpact();
      return;
    }
    if (_hasAmplitude) {
      await Vibration.vibrate(duration: 20, amplitude: 140);
    } else {
      await Vibration.vibrate(duration: 20);
    }
  }

  /// Сильный отклик — пересечение threshold, важное событие
  static Future<void> strong({WidgetRef? ref}) async {
    if (!_isEnabled(ref)) return;
    await _ensureChecked();
    if (!_hasVibrator) {
      await HapticFeedback.heavyImpact();
      return;
    }
    if (_hasAmplitude) {
      await Vibration.vibrate(duration: 30, amplitude: 220);
    } else {
      await Vibration.vibrate(duration: 40);
    }
  }

  /// Слабый отклик — возврат, отмена
  static Future<void> weak({WidgetRef? ref}) async {
    if (!_isEnabled(ref)) return;
    await _ensureChecked();
    if (!_hasVibrator) {
      await HapticFeedback.lightImpact();
      return;
    }
    if (_hasAmplitude) {
      await Vibration.vibrate(duration: 10, amplitude: 50);
    } else {
      await Vibration.vibrate(duration: 10);
    }
  }

  // ─────────────────────────────────────────────────────────────
  //  Специальные паттерны
  // ─────────────────────────────────────────────────────────────

  /// Подтверждение удаления — двойной тик
  static Future<void> confirmDelete({WidgetRef? ref}) async {
    if (!_isEnabled(ref)) return;
    await _ensureChecked();
    if (!_hasVibrator) {
      await HapticFeedback.mediumImpact();
      return;
    }
    if (_hasAmplitude) {
      await Vibration.vibrate(
        pattern: [0, 30, 50, 20],
        intensities: [0, 255, 0, 100],
      );
    } else {
      await Vibration.vibrate(duration: 35);
    }
  }

  /// Ошибка / предупреждение
  static Future<void> error({WidgetRef? ref}) async {
    if (!_isEnabled(ref)) return;
    await _ensureChecked();
    if (!_hasVibrator) {
      await HapticFeedback.vibrate();
      return;
    }
    if (_hasAmplitude) {
      await Vibration.vibrate(
        pattern: [0, 50, 30, 50],
        intensities: [0, 200, 0, 200],
      );
    } else {
      await Vibration.vibrate(pattern: [0, 50, 30, 50]);
    }
  }

  /// Успешное завершение — восходящий паттерн
  static Future<void> success({WidgetRef? ref}) async {
    if (!_isEnabled(ref)) return;
    await _ensureChecked();
    if (!_hasVibrator) {
      await HapticFeedback.mediumImpact();
      return;
    }
    if (_hasAmplitude) {
      await Vibration.vibrate(
        pattern: [0, 20, 30, 40],
        intensities: [0, 100, 0, 255],
      );
    } else {
      await Vibration.vibrate(pattern: [0, 20, 30, 40]);
    }
  }

  /// Тройной отклик — «тик-тик-тик»
  static Future<void> tripleTick({WidgetRef? ref}) async {
    if (!_isEnabled(ref)) return;
    await _ensureChecked();
    if (!_hasVibrator) {
      await HapticFeedback.lightImpact();
      await Future.delayed(const Duration(milliseconds: 60));
      await HapticFeedback.lightImpact();
      await Future.delayed(const Duration(milliseconds: 60));
      await HapticFeedback.lightImpact();
      return;
    }
    if (_hasAmplitude) {
      await Vibration.vibrate(
        pattern: [0, 15, 40, 15, 40, 15],
        intensities: [0, 120, 0, 120, 0, 120],
      );
    } else {
      await Vibration.vibrate(pattern: [0, 15, 40, 15, 40, 15]);
    }
  }

  // ─────────────────────────────────────────────────────────────
  //  Сброс кэша (для тестов или смены устройства)
  // ─────────────────────────────────────────────────────────────

  static void reset() {
    _checked = false;
    _hasVibrator = false;
    _hasAmplitude = false;
  }
}