// lib/core/secure_storage_diagnostics.dart
//
// Отчёт о состоянии secure storage для удалённой отладки: пользователь
// открывает Soulseek → Troubleshooting и отправляет текст разработчику.
//
// flutter_secure_storage при сбое инициализации пишет настоящую причину
// только в logcat и проглатывает её — в Dart доходит лишь вторичный NPE.
// Отчёт собирает её сам:
//  1. round-trip через плагин (SoulseekCredentials.diagnosticRoundTrip) —
//     симптом на уровне приложения; заодно плагин заново пишет свои ошибки
//     в logcat текущего процесса;
//  2. нативная часть (SecureStorageDiagnostics.kt) — те же шаги напрямую
//     с полными исключениями + выдержка из logcat приложения.
//
// Отчёт не содержит учётных данных.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'soulseek_credentials.dart';

class SecureStorageDiagnostics {
  SecureStorageDiagnostics._();

  static const MethodChannel _channel = MethodChannel('player/diagnostics');

  static Future<String> buildReport() async {
    final out = StringBuffer()..writeln('Player secure storage diagnostics');

    try {
      final info = await PackageInfo.fromPlatform();
      out.writeln('Version: ${info.version}+${info.buildNumber}');
    } catch (_) {
      out.writeln('Version: unknown');
    }
    out
      ..writeln('Generated: ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln()
      ..writeln('== flutter_secure_storage round-trip ==')
      ..write(await SoulseekCredentials.diagnosticRoundTrip());

    if (defaultTargetPlatform == TargetPlatform.android) {
      out.writeln();
      try {
        final native =
            await _channel.invokeMethod<String>('secureStorageReport');
        out.write(native ?? 'Native report: empty');
      } catch (e) {
        out.writeln('Native report failed: $e');
      }
    }
    return out.toString().trimRight();
  }
}
