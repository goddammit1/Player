import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/playlist.dart';
import 'playlist_repository.dart';

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
    return const JsonEncoder.withIndent('  ').convert(map);
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
    if (format != null && format != formatTag) {
      throw const FormatException('This file is not a playlist backup');
    }
    final rawList = parsed['playlists'];
    if (rawList is! List) {
      throw const FormatException('No playlists found in file');
    }
    final result = <Playlist>[];
    for (final e in rawList) {
      if (e is Map) {
        try {
          result.add(Playlist.fromJson(e.cast<String, dynamic>()));
        } catch (_) {
          // Пропускаем отдельный битый плейлист, не валим весь импорт.
        }
      }
    }
    if (result.isEmpty) {
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
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json')],
      subject: 'Player playlists backup',
    );
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
    return PlaylistRepository.instance.importPlaylists(
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
