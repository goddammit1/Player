import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../models/playlist.dart';
import 'track_row_codec.dart';

/// DAO плейлистов: CRUD-операции над таблицами `playlists`,
/// `playlist_tracks` и `playlist_covers`.
///
/// Выделено из монолита `AppDatabase` в рамках декомпозиции по обязанностям.
///
/// DAO не владеет соединением: открытая [Database] передаётся из вызывающего
/// слоя (`AppDatabase`/репозиториев), что разрывает циклическую зависимость.
class PlaylistDao {
  PlaylistDao._();
  static final PlaylistDao instance = PlaylistDao._();

  /// Загружает все плейлисты (с треками и кастомными обложками) из БД,
  /// сортируя их «новые сверху».
  Future<List<Playlist>> loadPlaylists(Database db) async {
    final rows = await db.query('playlists', orderBy: 'created_at_ms DESC');
    final result = <Playlist>[];
    for (final row in rows) {
      final tracks = await db.query(
        'playlist_tracks',
        where: 'playlist_id = ?',
        whereArgs: [row['id']],
        orderBy: 'sort_order ASC',
      );
      final coverRows = await db.query(
        'playlist_covers',
        where: 'playlist_id = ?',
        whereArgs: [row['id']],
        limit: 1,
      );
      final coverUrl =
          coverRows.isNotEmpty ? coverRows.first['cover_url'] as String? : null;

      result.add(Playlist(
        id: row['id'] as String,
        name: row['name'] as String,
        tracks: tracks.map(TrackRowCodec.fromRow).toList(),
        coverCustomUrl: coverUrl,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (row['created_at_ms'] as num).toInt()),
      ));
    }
    return result;
  }

  /// Сохраняет (INSERT или REPLACE) плейлист и все его треки.
  Future<void> savePlaylist(
      Database db, Playlist playlist, int sortOrder) async {
    await db.transaction((txn) async {
      await txn.insert(
        'playlists',
        {
          'id': playlist.id,
          'name': playlist.name,
          'created_at_ms': playlist.createdAt.millisecondsSinceEpoch,
          'sort_order': sortOrder,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await txn.delete(
        'playlist_tracks',
        where: 'playlist_id = ?',
        whereArgs: [playlist.id],
      );

      int tOrder = 0;
      for (final track in playlist.tracks) {
        await txn.insert('playlist_tracks', {
          'playlist_id': playlist.id,
          'track_global_id': track.globalId,
          'source_id': track.sourceId,
          'track_id': track.id,
          'title': track.title,
          'artist': track.artist,
          'duration_ms': track.duration?.inMilliseconds,
          'artwork_url': track.artworkUrl,
            'extra_json': jsonEncode(TrackRowCodec.extraPrimitives(track.extra)),
            'quality_score': track.qualityScore,
            'quality_label': track.qualityLabel,
            'sort_order': tOrder++,
          });
      }

      await txn.delete(
        'playlist_covers',
        where: 'playlist_id = ?',
        whereArgs: [playlist.id],
      );
      if (playlist.coverCustomUrl != null) {
        await txn.insert('playlist_covers', {
          'playlist_id': playlist.id,
          'cover_url': playlist.coverCustomUrl,
        });
      }
    });
  }

  /// Сохраняет все плейлисты разом (полный flush).
  Future<void> saveAllPlaylists(Database db, List<Playlist> playlists) async {
    await db.transaction((txn) async {
      await txn.delete('playlist_tracks');
      await txn.delete('playlist_covers');
      await txn.delete('playlists');

      for (var i = 0; i < playlists.length; i++) {
        final playlist = playlists[i];
        await txn.insert('playlists', {
          'id': playlist.id,
          'name': playlist.name,
          'created_at_ms': playlist.createdAt.millisecondsSinceEpoch,
          'sort_order': i,
        });

        if (playlist.coverCustomUrl != null) {
          await txn.insert('playlist_covers', {
            'playlist_id': playlist.id,
            'cover_url': playlist.coverCustomUrl,
          });
        }

        for (var j = 0; j < playlist.tracks.length; j++) {
          final track = playlist.tracks[j];
          await txn.insert('playlist_tracks', {
            'playlist_id': playlist.id,
            'track_global_id': track.globalId,
            'source_id': track.sourceId,
            'track_id': track.id,
            'title': track.title,
            'artist': track.artist,
            'duration_ms': track.duration?.inMilliseconds,
            'artwork_url': track.artworkUrl,
            'extra_json': jsonEncode(TrackRowCodec.extraPrimitives(track.extra)),
            'quality_score': track.qualityScore,
            'quality_label': track.qualityLabel,
            'sort_order': j,
          });
        }
      }
    });
  }

  /// Удаляет плейлист из БД.
  Future<void> deletePlaylist(Database db, String id) async {
    await db.transaction((txn) async {
      await txn.delete('playlist_covers',
          where: 'playlist_id = ?', whereArgs: [id]);
      await txn.delete('playlist_tracks',
          where: 'playlist_id = ?', whereArgs: [id]);
      await txn.delete('playlists', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Полная очистка таблиц плейлистов (для тестов).
  Future<void> clearPlaylists(Database db) async {
    await db.transaction((txn) async {
      await txn.delete('playlist_tracks');
      await txn.delete('playlist_covers');
      await txn.delete('playlists');
    });
  }
}