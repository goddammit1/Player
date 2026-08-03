import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/playlist.dart';
import 'app_database.dart';
import 'artwork_helper.dart';
import 'history_repository.dart';
import 'playlist_repository.dart';

/// Максимальная поддерживаемая версия формата бэкапа.
const int _maxSupportedVersion = 1;

/// Экспорт/импорт пользовательских плейлистов в один JSON-файл.
///
/// Назначение — «бэкап, который переживёт удаление приложения»: файл
/// уходит в системный share-sheet (Drive, Files, отправить себе), а при
/// импорте читается обратно. Формат — самодостаточный JSON со схемой
/// плейлистов из [Playlist.toJson], так что ничего нового сериализовать
/// не нужно.
///
/// ```json
/// {
///   "format": "player_playlists_backup",
///   "version": 1,
///   "exported_at_ms": 1700000000000,
///   "playlists": [ { ...Playlist.toJson()... } ]
/// }
/// ```
class PlaylistBackup {
  PlaylistBackup._();

  static const String formatTag = 'player_playlists_backup';
  static const int formatVersion = 1;

  /// Сериализует переданные плейлисты в pretty-JSON строку бэкапа.
  static String encode(List<Playlist> playlists) {
    final map = <String, dynamic>{
      'format': formatTag,
      'version': formatVersion,
      'exported_at_ms': DateTime.now().millisecondsSinceEpoch,
      'playlists': playlists.map((p) => p.toJson()).toList(),
    };
    return const JsonEncoder().convert(map);
  }

  /// Парсит строку бэкапа в список плейлистов.
  ///
  /// Бросает [FormatException], если JSON битый или это не наш формат.
  static List<Playlist> decode(String raw) {
    final dynamic parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      throw const FormatException('Not a valid JSON file');
    }
    if (parsed is! Map) {
      throw const FormatException('Unexpected JSON structure');
    }
    final format = parsed['format'];
    if (format != formatTag) {
      throw const FormatException('This file is not a playlist backup');
    }
    final version = parsed['version'];
    if (version != null) {
      if (version is! int || version < 1 || version > _maxSupportedVersion) {
        throw FormatException(
          'Unsupported backup version: $version (max supported: $_maxSupportedVersion)',
        );
      }
    }
    final rawList = parsed['playlists'];
    if (rawList is! List) {
      throw const FormatException('No playlists found in file');
    }
    final result = <Playlist>[];
    var skippedCount = 0;
    for (final e in rawList) {
      if (e is Map) {
        final map = e.cast<String, dynamic>();
        // Валидируем обязательные поля перед вызовом fromJson.
        if (map['id'] is! String ||
            map['id'] == null ||
            (map['id'] as String).isEmpty ||
            map['name'] is! String ||
            map['name'] == null ||
            (map['name'] as String).isEmpty) {
          skippedCount++;
          continue;
        }
        try {
          result.add(Playlist.fromJson(map));
        } catch (_) {
          skippedCount++;
          // Пропускаем отдельный битый плейлист, не валим весь импорт.
        }
      } else {
        skippedCount++;
      }
    }
    if (result.isEmpty) {
      if (skippedCount > 0) {
        throw FormatException('No valid playlists in file ($skippedCount skipped)');
      }
      throw const FormatException('No valid playlists in file');
    }
    return result;
  }

  /// Пишет бэкап во временный файл и отдаёт в системный share-sheet.
  ///
  /// Возвращает число выгруженных плейлистов.
  static Future<int> exportAndShare(List<Playlist> playlists) async {
    final json = encode(playlists);
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final file = File('${dir.path}/playlists_backup_$stamp.json');
    await file.writeAsString(json);
    try {
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'Player playlists backup',
      );
    } finally {
      // Удаляем временный файл после завершения share-sheet.
      // Игнорируем ошибки удаления — файл всё равно во временной директории.
      try {
        await file.delete();
      } catch (_) {}
    }
    return playlists.length;
  }

  /// Читает файл бэкапа с диска и импортирует в репозиторий.
  ///
  /// Возвращает [ImportResult] со статистикой.
  static Future<ImportResult> importFromFile(
    String path, {
    required ImportStrategy strategy,
  }) async {
    final raw = await File(path).readAsString();
    final playlists = decode(raw);
    return await PlaylistRepository.instance.importPlaylists(
      playlists,
      strategy: strategy,
    );
  }
}

enum ImportStrategy { replace, keepBoth, skip }

/// Статистика импорта для отображения пользователю.
class ImportResult {
  const ImportResult({
    required this.added,
    required this.replaced,
    required this.skipped,
  });

  final int added;
  final int replaced;
  final int skipped;

  int get total => added + replaced + skipped;
}

// ======================================================================
//  ПОЛНЫЙ БЭКАП (все данные приложения: плейлисты, история, настройки)
// ======================================================================

/// Бэкап **всех** данных приложения в один JSON-файл.
///
/// Формат: `player_full_backup` v1 — содержит все таблицы БД как есть.
/// После восстановления приложение полностью идентично состоянию на момент
/// экспорта.
class FullBackup {
  FullBackup._();

  /// Экспортирует все данные в JSON и отправляет через share-sheet.
  static Future<void> exportAndShare() async {
    final json = await AppDatabase.instance.exportFullBackup();
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final file = File('${dir.path}/player_full_backup_$stamp.json');
    await file.writeAsString(json);
    try {
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        subject: 'Player full backup',
      );
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  /// Импортирует данные из JSON-файла, полностью замещая текущие.
  ///
  /// Бросает [FormatException], если файл битый или не того формата.
  static Future<void> importFromFile(String path) async {
    final raw = await File(path).readAsString();
    await AppDatabase.instance.importFullBackup(raw);

    // Перезагружаем репозитории после импорта.
    await PlaylistRepository.instance.ensureLoaded();
    await HistoryRepository.instance.reload();

    // Сбрасываем флаг _initialized, чтобы init() перечитал БД заново.
    ArtworkHelper.resetInit();
    await ArtworkHelper.init();
  }
}
