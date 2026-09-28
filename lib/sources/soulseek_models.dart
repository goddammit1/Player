// lib/sources/soulseek_models.dart
//
// Фаза 3 — Dart-модели для Soulseek-интеграции.
//
// Data-классы, энумы и sealed-иерархия событий, соответствующие
// контрактам MethodChannel/EventChannel из Фазы 2 (SoulseekPlugin.kt,
// SoulseekEvent.kt) и DTO из Фазы 1 (SoulseekDtos.cs).

import 'dart:convert';

// ═══════════════════════════════════════════════════════════════════════
//  Исключение
// ═══════════════════════════════════════════════════════════════════════

/// Ошибка платформенного Soulseek-слоя.
///
/// Маппится из [PlatformException]: `code` → [code], `message` → [message],
/// `details["retryable"]` → [retryable].
class SoulseekException implements Exception {
  final String code;
  final String message;
  final bool retryable;

  const SoulseekException(this.code, this.message, {this.retryable = false});

  @override
  String toString() =>
      'SoulseekException($code): $message (retryable: $retryable)';
}

// ═══════════════════════════════════════════════════════════════════════
//  Энумы состояний
// ═══════════════════════════════════════════════════════════════════════

/// Состояние трансфера (загрузки). Маппится из строк Kotlin-энума
/// [TransferState] (uppercase names: "QUEUED", "DOWNLOADING", …),
/// отправляемых в EventChannel.
enum SoulseekTransferState {
  idle,
  connecting,
  searching,
  queued,
  downloading,
  prebuffered,
  completed,
  paused,
  failed,
  cancelled;

  /// Терминальные состояния: трансфер завершён и не потребляет слот очереди.
  bool get isTerminal =>
      this == completed || this == failed || this == cancelled;

  /// Состояния, при которых трансфер числится «активным».
  bool get isActive =>
      this == queued || this == downloading || this == connecting;

  /// Парсит строку состояния (case-insensitive) из EventChannel.
  static SoulseekTransferState fromString(String? name) {
    if (name == null || name.isEmpty) return SoulseekTransferState.idle;
    final upper = name.toUpperCase();
    for (final s in SoulseekTransferState.values) {
      if (s.name.toUpperCase() == upper) return s;
    }
    // Fallback: substring matching для C# state flags
    if (upper.contains('SUCCEEDED')) return SoulseekTransferState.completed;
    if (upper.contains('CANCELLED') || upper.contains('ABORTED')) {
      return SoulseekTransferState.cancelled;
    }
    if (upper.contains('TIMEDOUT') ||
        upper.contains('ERRORED') ||
        upper.contains('REJECTED')) {
      return SoulseekTransferState.failed;
    }
    if (upper.contains('TRANSFERRING')) return SoulseekTransferState.downloading;
    if (upper.contains('NEGOTIATING') ||
        upper.contains('INITIALIZING') ||
        upper.contains('INITIALIZED')) {
      return SoulseekTransferState.connecting;
    }
    if (upper.contains('REQUESTED') || upper.contains('QUEUED')) {
      return SoulseekTransferState.queued;
    }
    return SoulseekTransferState.idle;
  }
}

/// Состояние соединения с сервером Soulseek.
/// Маппится из строк Kotlin [ConnectionState] или C# [SoulseekClientStates].
enum SoulseekConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed;

  /// Парсит строку состояния (case-insensitive).
  static SoulseekConnectionState fromString(String? name) {
    if (name == null || name.isEmpty) return SoulseekConnectionState.disconnected;
    final upper = name.toUpperCase();
    for (final s in SoulseekConnectionState.values) {
      if (s.name.toUpperCase() == upper) return s;
    }
    // Fallback: substring matching для C# state names
    if (upper.contains('LOGGEDIN') || upper.contains('LOGGED_IN')) {
      return SoulseekConnectionState.connected;
    }
    if (upper.contains('CONNECTED') && !upper.contains('DIS')) {
      return SoulseekConnectionState.connected;
    }
    // Важно: DISCONNECTING/RECONNECTING содержат подстроку "CONNECTING",
    // поэтому эти проверки должны идти раньше.
    if (upper.contains('DISCONNECTING') || upper.contains('RECONNECT')) {
      return SoulseekConnectionState.reconnecting;
    }
    if (upper.contains('CONNECTING') || upper.contains('LOGGING')) {
      return SoulseekConnectionState.connecting;
    }
    if (upper.contains('DISCONNECT')) return SoulseekConnectionState.disconnected;
    if (upper.contains('FAIL')) return SoulseekConnectionState.failed;
    return SoulseekConnectionState.disconnected;
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Data-классы
// ═══════════════════════════════════════════════════════════════════════

/// Фильтры поискового запроса Soulseek.
///
/// Передаются в MethodChannel `search` → C# [SearchFiltersDto].
/// Дублируются на Dart-стороне для пост-фильтрации результатов.
class SoulseekSearchFilters {
  /// Разрешённые расширения без точки, нижний регистр (["flac","mp3"]).
  final List<String>? extensions;

  /// Минимальный размер файла, байт.
  final int? minSizeBytes;

  /// Максимальный размер файла, байт.
  final int? maxSizeBytes;

  /// Минимальный битрейт, kbps.
  final int? minBitrate;

  /// Только lossless (flac, alac, wav, ape, wv).
  final bool losslessOnly;

  /// Минимальная скорость загрузки пира, KiB/s.
  final int? minPeerUploadSpeed;

  /// Максимальная длина очереди пира.
  final int? maxPeerQueueLength;

  const SoulseekSearchFilters({
    this.extensions,
    this.minSizeBytes,
    this.maxSizeBytes,
    this.minBitrate,
    this.losslessOnly = false,
    this.minPeerUploadSpeed,
    this.maxPeerQueueLength,
  });

  /// Пустые фильтры (без ограничений).
  static const SoulseekSearchFilters empty = SoulseekSearchFilters();

  /// Расширения, считающиеся lossless.
  static const Set<String> losslessExtensions = {
    'flac',
    'alac',
    'wav',
    'ape',
    'wv',
  };

  /// Маршалинг в Map для MethodChannel.
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{};
    if (extensions != null) map['extensions'] = extensions;
    if (minSizeBytes != null) map['minSizeBytes'] = minSizeBytes;
    if (maxSizeBytes != null) map['maxSizeBytes'] = maxSizeBytes;
    if (minBitrate != null) map['minBitrate'] = minBitrate;
    map['losslessOnly'] = losslessOnly;
    if (minPeerUploadSpeed != null) {
      map['minPeerUploadSpeed'] = minPeerUploadSpeed;
    }
    if (maxPeerQueueLength != null) {
      map['maxPeerQueueLength'] = maxPeerQueueLength;
    }
    return map;
  }

  /// Применяет фильтры к результату поиска на Dart-стороне
  /// (дублирование native-фильтров для надёжности).
  bool matches(SoulseekSearchResult result) {
    final ext = result.extension.toLowerCase();

    if (extensions != null && extensions!.isNotEmpty) {
      if (!extensions!.any((e) => e.toLowerCase() == ext)) return false;
    }

    if (losslessOnly && !losslessExtensions.contains(ext)) return false;

    if (minSizeBytes != null && result.sizeBytes < minSizeBytes!) return false;

    if (maxSizeBytes != null && result.sizeBytes > maxSizeBytes!) return false;

    if (minBitrate != null) {
      final br = result.bitrate;
      if (br == null || br < minBitrate!) return false;
    }

    if (minPeerUploadSpeed != null &&
        result.uploadSpeed < minPeerUploadSpeed!) {
      return false;
    }

    if (maxPeerQueueLength != null &&
        result.queueLength > maxPeerQueueLength!) {
      return false;
    }

    return true;
  }
}

/// Один файл из результатов поиска Soulseek.
/// Маппится из C# [SearchResultDto] → Kotlin Map → Dart Map.
class SoulseekSearchResult {
  /// Уникальный ID результата (генерируется C# bridge).
  final String resultId;

  /// Имя пользователя (пира), у которого найден файл.
  final String username;

  /// Полный путь к файлу на стороне пира.
  final String filename;

  /// Размер файла, байт.
  final int sizeBytes;

  /// Расширение файла без точки (например "flac", "mp3").
  final String extension;

  /// Битрейт, kbps (может отсутствовать).
  final int? bitrate;

  /// Частота дискретизации, Hz или kHz (зависит от C# bridge).
  final int? sampleRate;

  /// Разрядность, бит (для lossless).
  final int? bitDepth;

  /// Длительность, секунд.
  final int? durationSeconds;

  /// Длина очереди загрузок у пира.
  final int queueLength;

  /// Количество свободных слотов загрузки у пира.
  final int freeUploadSlots;

  /// Скорость загрузки пира, KiB/s.
  final int uploadSpeed;

  const SoulseekSearchResult({
    required this.resultId,
    required this.username,
    required this.filename,
    required this.sizeBytes,
    required this.extension,
    this.bitrate,
    this.sampleRate,
    this.bitDepth,
    this.durationSeconds,
    required this.queueLength,
    required this.freeUploadSlots,
    required this.uploadSpeed,
  });

  /// Парсит Map из MethodChannel в типизированный объект.
  factory SoulseekSearchResult.fromMap(Map<String, dynamic> m) {
    return SoulseekSearchResult(
      resultId: (m['resultId'] ?? '') as String,
      username: (m['username'] ?? '') as String,
      filename: (m['filename'] ?? '') as String,
      sizeBytes: _asInt(m['sizeBytes']),
      extension: (m['extension'] ?? '') as String,
      bitrate: _asIntOrNull(m['bitrate']),
      sampleRate: _asIntOrNull(m['sampleRate']),
      bitDepth: _asIntOrNull(m['bitDepth']),
      durationSeconds: _asIntOrNull(m['durationSeconds']),
      queueLength: _asInt(m['queueLength']),
      freeUploadSlots: _asInt(m['freeUploadSlots']),
      uploadSpeed: _asInt(m['uploadSpeed']),
    );
  }
}

/// Информация о трансфере (загрузке).
/// Маппится из transfer-событий EventChannel и из `getTransfer` /
/// `getActiveTransfers` MethodChannel-команд.
class SoulseekTransferInfo {
  final String downloadId;
  final SoulseekTransferState state;
  final int bytesReceived;
  final int totalBytes;
  final int bytesPerSecond;
  final String? localPath;
  final String? errorCode;
  final bool retryable;
  final String? message;

  const SoulseekTransferInfo({
    required this.downloadId,
    required this.state,
    this.bytesReceived = 0,
    this.totalBytes = 0,
    this.bytesPerSecond = 0,
    this.localPath,
    this.errorCode,
    this.retryable = false,
    this.message,
  });

  /// Парсит Map (transfer-событие или getTransfer-результат).
  factory SoulseekTransferInfo.fromMap(Map<String, dynamic> m) {
    return SoulseekTransferInfo(
      downloadId: (m['downloadId'] ?? '') as String,
      state: SoulseekTransferState.fromString(m['state'] as String?),
      bytesReceived: _asInt(m['bytesReceived']),
      totalBytes: _asInt(m['totalBytes']),
      bytesPerSecond: _asInt(m['bytesPerSecond']),
      localPath: m['localPath'] as String?,
      errorCode: m['errorCode'] as String?,
      retryable: m['retryable'] == true,
      message: m['message'] as String?,
    );
  }

  /// Прогресс загрузки 0.0..1.0 (null если totalBytes неизвестен).
  double? get progress {
    if (totalBytes <= 0) return null;
    final p = bytesReceived / totalBytes;
    if (p < 0) return 0;
    if (p > 1) return 1;
    return p;
  }

  Map<String, dynamic> toMap() => {
        'downloadId': downloadId,
        'state': state.name.toUpperCase(),
        'bytesReceived': bytesReceived,
        'totalBytes': totalBytes,
        'bytesPerSecond': bytesPerSecond,
        'localPath': localPath,
        'errorCode': errorCode,
        'retryable': retryable,
        'message': message,
      };
}

/// Запись о кэшированном файле Soulseek.
/// Маппится из `getCacheEntry` MethodChannel-команды.
class SoulseekCacheEntry {
  final String cacheKey;
  final String localPath;
  final int sizeBytes;
  final bool complete;
  final bool pinned;

  const SoulseekCacheEntry({
    required this.cacheKey,
    required this.localPath,
    required this.sizeBytes,
    required this.complete,
    required this.pinned,
  });

  factory SoulseekCacheEntry.fromMap(Map<String, dynamic> m) {
    return SoulseekCacheEntry(
      cacheKey: (m['cacheKey'] ?? '') as String,
      localPath: (m['localPath'] ?? '') as String,
      sizeBytes: _asInt(m['sizeBytes']),
      complete: m['complete'] == true,
      pinned: m['pinned'] == true,
    );
  }
}

/// Результат команды `startDownload`.
///
/// `cacheHit == true` → файл уже в кэше, [result] содержит локальный путь.
/// `cacheHit == false` → загрузка запущена, [result] содержит downloadId.
class SoulseekDownloadResult {
  final String downloadId;
  final String result;
  final bool cacheHit;

  const SoulseekDownloadResult({
    required this.downloadId,
    required this.result,
    required this.cacheHit,
  });

  factory SoulseekDownloadResult.fromMap(Map<String, dynamic> m) {
    return SoulseekDownloadResult(
      downloadId: (m['downloadId'] ?? '') as String,
      result: (m['result'] ?? '').toString(),
      cacheHit: m['cacheHit'] == true,
    );
  }
}

/// Результат команды `connect` — состояние соединения после логина.
class SoulseekConnectionInfo {
  final String username;
  final SoulseekConnectionState state;

  const SoulseekConnectionInfo({
    required this.username,
    required this.state,
  });

  factory SoulseekConnectionInfo.fromMap(Map<String, dynamic> m) {
    return SoulseekConnectionInfo(
      username: (m['username'] ?? '') as String,
      state: SoulseekConnectionState.fromString(m['state'] as String?),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Sealed-иерархия событий EventChannel
// ═══════════════════════════════════════════════════════════════════════

/// Базовый класс для всех событий Soulseek EventChannel.
sealed class SoulseekEvent {
  const SoulseekEvent();

  /// Парсит Map (из JSON-строки EventChannel) в типизированное событие.
  factory SoulseekEvent.fromMap(Map<String, dynamic> m) {
    final type = m['eventType'] as String? ?? '';
    switch (type) {
      case 'transfer':
        return SoulseekTransferEvent(
          SoulseekTransferInfo.fromMap(m),
        );
      case 'connection':
        return SoulseekConnectionEvent(
          state: SoulseekConnectionState.fromString(m['state'] as String?),
          message: m['message'] as String?,
        );
      case 'transferSnapshot':
        final transfersRaw = m['transfers'] as List? ?? const [];
        return SoulseekTransferSnapshot(
          transfers: transfersRaw
              .map((t) => SoulseekTransferInfo.fromMap(t as Map<String, dynamic>))
              .toList(growable: false),
        );
      default:
        return SoulseekUnknownEvent(type, m);
    }
  }

  /// Парсит JSON-строку из EventChannel.
  static SoulseekEvent fromJsonString(String json) {
    final decoded = jsonDecode(json);
    if (decoded is Map<String, dynamic>) {
      return SoulseekEvent.fromMap(decoded);
    }
    return SoulseekUnknownEvent('raw', {'raw': json});
  }
}

/// Событие трансфера (прогресс / смена состояния / завершение).
class SoulseekTransferEvent extends SoulseekEvent {
  final SoulseekTransferInfo transfer;

  const SoulseekTransferEvent(this.transfer);

  // Делегаты для удобства
  String get downloadId => transfer.downloadId;
  SoulseekTransferState get state => transfer.state;
  int get bytesReceived => transfer.bytesReceived;
  int get totalBytes => transfer.totalBytes;
  int get bytesPerSecond => transfer.bytesPerSecond;
  String? get localPath => transfer.localPath;
  String? get errorCode => transfer.errorCode;
  bool get retryable => transfer.retryable;
  String? get message => transfer.message;
}

/// Событие соединения с сервером Soulseek.
class SoulseekConnectionEvent extends SoulseekEvent {
  final SoulseekConnectionState state;
  final String? message;

  const SoulseekConnectionEvent({required this.state, this.message});
}

/// Снимок активных трансферов (отправляется при onListen).
class SoulseekTransferSnapshot extends SoulseekEvent {
  final List<SoulseekTransferInfo> transfers;

  const SoulseekTransferSnapshot({required this.transfers});
}

/// Неизвестный тип события (для forward-compatibility).
class SoulseekUnknownEvent extends SoulseekEvent {
  final String type;
  final Map<String, dynamic> raw;

  const SoulseekUnknownEvent(this.type, this.raw);
}

// ═══════════════════════════════════════════════════════════════════════
//  Вспомогательные функции парсинга
// ═══════════════════════════════════════════════════════════════════════

int _asInt(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is num) return v.toInt();
  return int.tryParse(v.toString()) ?? 0;
}

int? _asIntOrNull(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}
