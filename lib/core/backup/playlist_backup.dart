import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/playlist.dart';
import '../../sources/source_registry.dart';
import '../../ui/desktop/desktop_layout.dart' show isDesktop;
import '../database/app_database.dart';
import '../artwork_helper.dart';
import '../repositories/history_repository.dart';
import '../repositories/playlist_repository.dart';

/// Максимальная поддерживаемая версия формата бэкапа.
const int _maxSupportedVersion = 1;

/// Экспорт/импорт пользовательских плейлистов в один JSON-файл.
///
/// Назначение — «бэкап, который переживёт удаление приложения»: файл
/// уходит в системный share-sheet (Drive, Files, отправить себе), на
/// десктопе — сохраняется через «Сохранить как…», а при импорте читается
/// обратно. Формат — самодостаточный JSON со схемой
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

  /// Выгружает бэкап: на мобильных — в системный share-sheet, на десктопе —
  /// диалогом «Сохранить как…».
  ///
  /// Возвращает `false`, если пользователь отменил сохранение.
  static Future<bool> exportAndShare(List<Playlist> playlists) {
    final name = playlists.length == 1
        ? _safeFileName(playlists.single.name)
        : 'playlists_backup';
    return deliverBackupFile(
      json: encode(playlists),
      fileName: '${name}_${backupStamp()}.json',
      subject: 'Player playlists backup',
    );
  }

  /// Читает файл бэкапа с диска и импортирует в репозиторий.
  ///
  /// Все плейлисты из файла добавляются как новые (без выбора и проверки
  /// на дубликаты). Возвращает [ImportResult] со статистикой.
  static Future<ImportResult> importFromFile(String path) async {
    final raw = await File(path).readAsString();
    final playlists = decode(raw);
    return await PlaylistRepository.instance.importPlaylists(playlists);
  }
}

/// Метка времени для имени файла бэкапа: `2026-10-13T01-32-05`.
String backupStamp() =>
    DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;

/// Имя плейлиста без символов, запрещённых в именах файлов Windows.
String _safeFileName(String name) {
  final clean =
      name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
  return clean.isEmpty ? 'playlist' : clean;
}

/// Тестовая подмена диалога «Сохранить как…»: получает предложенное имя,
/// возвращает выбранный путь или `null` (отмена).
@visibleForTesting
Future<String?> Function(String fileName)? saveFileDialogOverride;

/// Отдаёт готовый JSON пользователю. На десктопе share-sheet бесполезен
/// (на Windows `Share.shareXFiles` открывает системное окно «Поделиться»
/// без сохранения в файл), поэтому там — «Сохранить как…». Возвращает
/// `false`, если пользователь отменил диалог сохранения.
Future<bool> deliverBackupFile({
  required String json,
  required String fileName,
  required String subject,
}) async {
  if (isDesktop) {
    final picked = await (saveFileDialogOverride?.call(fileName) ??
        FilePicker.platform.saveFile(
          dialogTitle: 'Save backup',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: const ['json'],
        ));
    if (picked == null) return false;
    // Диалог Windows не дописывает расширение сам.
    final path = p.extension(picked).isEmpty ? '$picked.json' : picked;
    await File(path).writeAsString(json, flush: true);
    return true;
  }

  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, fileName));
  await file.writeAsString(json);
  try {
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json')],
      subject: subject,
    );
  } finally {
    // Временный файл после share-sheet не нужен; ошибки удаления не важны.
    try {
      await file.delete();
    } catch (_) {}
  }
  return true;
}

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

  /// Экспортирует все данные в JSON: share-sheet на мобильных, «Сохранить
  /// как…» на десктопе. Возвращает `false`, если сохранение отменено.
  static Future<bool> exportAndShare() async {
    final json = await AppDatabase.instance.exportFullBackup();
    return deliverBackupFile(
      json: json,
      fileName: 'player_full_backup_${backupStamp()}.json',
      subject: 'Player full backup',
    );
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

    // Настройки Soulseek тоже в таблице settings: перечитываем флаг поиска,
    // фильтры/таймаут источника и синхронизируем натив (порт, кэш и т.д.).
    await SourceRegistry.reloadSoulseekSettings();
  }
}
