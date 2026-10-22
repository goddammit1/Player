// Формат «Share link»: что уходит на сервер и как разбирается ответ.

import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/share/playlist_share_codec.dart';
import 'package:player/models/playlist.dart';
import 'package:player/models/track.dart';

Track _t(
  String id, {
  String source = 'youtube',
  Map<String, dynamic> extra = const {},
  String? art,
}) => Track(
  id: id,
  sourceId: source,
  title: 'Song $id',
  artist: 'Artist $id',
  duration: const Duration(seconds: 200),
  artworkUrl: art,
  extra: extra,
);

Playlist _p(List<Track> tracks, {List<String>? manualOrder, String? cover}) =>
    Playlist(
      id: 'local-id',
      name: '  Road trip ',
      tracks: tracks,
      manualOrder: manualOrder,
      coverCustomUrl: cover,
      createdAt: DateTime(2024),
    );

List<int> _gzipJson(Object json) => gzip.encode(utf8.encode(jsonEncode(json)));

void main() {
  group('PlaylistShareCodec.toShareJson', () {
    test('keeps only portable playlist fields', () {
      final json = PlaylistShareCodec.toShareJson(
        _p([_t('a')], cover: r'C:\Users\me\covers\p.jpg'),
      );
      expect(json['format'], 'player_playlist_share');
      expect(json['version'], 1);
      final playlist = json['playlist'] as Map<String, dynamic>;
      expect(playlist.keys, unorderedEquals(['name', 'tracks']));
      expect(playlist['name'], 'Road trip');
    });

    test('applies manual order to tracks', () {
      final json = PlaylistShareCodec.toShareJson(
        _p(
          [_t('a'), _t('b'), _t('c')],
          manualOrder: ['youtube:c', 'youtube:a'],
        ),
      );
      final ids = ((json['playlist'] as Map)['tracks'] as List).map(
        (t) => t['id'],
      );
      expect(ids, ['c', 'a', 'b']);
    });

    test('drops local artwork paths, keeps http ones; omits nulls', () {
      final json = PlaylistShareCodec.toShareJson(
        _p([
          _t('a', art: '/data/user/0/covers/a.jpg'),
          _t('b', art: 'https://img/b.jpg'),
        ]),
      );
      final tracks = (json['playlist'] as Map)['tracks'] as List;
      expect((tracks[0] as Map).containsKey('artwork_url'), isFalse);
      expect(tracks[1]['artwork_url'], 'https://img/b.jpg');
      expect((tracks[0] as Map).containsKey('quality_score'), isFalse);
      expect((tracks[0] as Map).containsKey('extra'), isFalse);
      expect(tracks[0]['duration_ms'], 200000);
    });

    test('keeps source data needed to play, drops volatile Soulseek keys', () {
      final json = PlaylistShareCodec.toShareJson(
        _p([
          _t('m', source: 'muzmo', extra: {'streamUrl': 'https://muzmo/1.mp3'}),
          _t(
            's',
            source: 'soulseek',
            extra: {
              'peerUsername': 'alice',
              'remoteFilename': r'Music\a.flac',
              'sizeBytes': 123,
              'extension': 'flac',
              'cacheKey': 'abc',
              'queueLength': 4,
              'uploadSpeed': 1000,
              'hasFreeUploadSlot': true,
              'alternates': [
                {
                  'peerUsername': 'bob',
                  'remoteFilename': r'x\a.flac',
                  'sizeBytes': 123,
                },
              ],
              'notJson': DateTime(2024),
            },
          ),
        ]),
      );
      final tracks = (json['playlist'] as Map)['tracks'] as List;
      expect(tracks[0]['extra'], {'streamUrl': 'https://muzmo/1.mp3'});
      final soulseek = tracks[1]['extra'] as Map;
      expect(
        soulseek.keys,
        unorderedEquals([
          'peerUsername',
          'remoteFilename',
          'sizeBytes',
          'extension',
          'alternates',
        ]),
      );
    });
  });

  group('PlaylistShareCodec encode/decode', () {
    test('round-trips through gzip', () {
      final original = _p([
        _t('a', art: 'https://img/a.jpg'),
        _t('m', source: 'muzmo', extra: {'streamUrl': 'https://muzmo/1.mp3'}),
      ]);
      final decoded = PlaylistShareCodec.decode(
        PlaylistShareCodec.encode(original),
      );
      expect(decoded.name, 'Road trip');
      expect(decoded.coverCustomUrl, isNull);
      expect(decoded.manualOrder, isNull);
      expect(decoded.tracks.map((t) => t.globalId), ['youtube:a', 'muzmo:m']);
      expect(decoded.tracks[0].artworkUrl, 'https://img/a.jpg');
      expect(decoded.tracks[0].duration, const Duration(seconds: 200));
      expect(decoded.tracks[1].extra['streamUrl'], 'https://muzmo/1.mp3');
    });

    test('compresses repetitive playlists well', () {
      final big = _p(
        List.generate(
          2000,
          (i) => _t('id$i', art: 'https://i.ytimg.com/vi/id$i/hq.jpg'),
        ),
      );
      final raw = utf8
          .encode(jsonEncode(PlaylistShareCodec.toShareJson(big)))
          .length;
      final packed = PlaylistShareCodec.encode(big).length;
      expect(packed, lessThan(raw ~/ 4));
    });

    test('rejects data that is not gzip', () {
      expect(
        () => PlaylistShareCodec.decode(utf8.encode('{}')),
        throwsFormatException,
      );
    });

    test('rejects a foreign format', () {
      expect(
        () => PlaylistShareCodec.decode(
          _gzipJson({'format': 'player_playlists_backup', 'version': 1}),
        ),
        throwsFormatException,
      );
    });

    test('asks to update the app for a newer version', () {
      expect(
        () => PlaylistShareCodec.decode(
          _gzipJson({
            'format': 'player_playlist_share',
            'version': 2,
            'playlist': {'name': 'x', 'tracks': []},
          }),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('update'),
          ),
        ),
      );
    });

    test('rejects tracks without required fields', () {
      expect(
        () => PlaylistShareCodec.decode(
          _gzipJson({
            'format': 'player_playlist_share',
            'version': 1,
            'playlist': {
              'name': 'x',
              'tracks': [
                {'id': 'a'},
              ],
            },
          }),
        ),
        throwsFormatException,
      );
    });
  });
}
