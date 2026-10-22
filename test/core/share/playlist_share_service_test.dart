// PlaylistShareService: HTTP-обмен с share-server и разбор ссылок.
// Сеть подменяется mock-Dio (http_mock_adapter).

import 'dart:convert';
import 'dart:io' show gzip;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart' hide Matcher;

import 'package:player/core/repositories/playlist_repository.dart';
import 'package:player/core/share/playlist_share_codec.dart';
import 'package:player/core/share/playlist_share_service.dart';
import 'package:player/models/playlist.dart';
import 'package:player/models/track.dart';

import '../../setup/test_harness.dart';

const _base = 'http://share.test';
const _id = 'DpDuXoudAp';

Playlist _playlist([int count = 2]) => Playlist(
  id: 'p1',
  name: 'Road trip',
  tracks: [
    for (var i = 0; i < count; i++)
      Track(
        id: 't$i',
        sourceId: 'youtube',
        title: 'Song $i',
        artist: 'Artist $i',
      ),
  ],
  createdAt: DateTime(2024),
);

List<int> _snapshot() => PlaylistShareCodec.encode(_playlist());

Matcher _shareError(String text) => throwsA(
  isA<PlaylistShareException>().having(
    (e) => e.message,
    'message',
    contains(text),
  ),
);

void main() {
  late Dio dio;
  late DioAdapter adapter;
  late PlaylistShareService service;

  setUp(() {
    dio = Dio();
    adapter = DioAdapter(dio: dio);
    service = PlaylistShareService(dio: dio, baseUrl: '$_base/');
  });

  group('parseId', () {
    test('accepts links, app links, bare ids and text with a link', () {
      expect(PlaylistShareService.parseId(_id), _id);
      expect(
        PlaylistShareService.parseId(' https://share.example/p/$_id '),
        _id,
      );
      expect(PlaylistShareService.parseId('http://10.0.2.2:8787/p/$_id'), _id);
      expect(PlaylistShareService.parseId('playerapp://p/$_id'), _id);
      expect(
        PlaylistShareService.parseId('Listen: https://share.example/p/$_id!'),
        _id,
      );
    });

    test(
      'containsShareLink ignores bare ids (ordinary words in clipboard)',
      () {
        expect(PlaylistShareService.containsShareLink('everything'), isFalse);
        expect(PlaylistShareService.containsShareLink(_id), isFalse);
        expect(
          PlaylistShareService.containsShareLink(
            'https://share.example/p/$_id',
          ),
          isTrue,
        );
        expect(
          PlaylistShareService.containsShareLink('playerapp://p/$_id'),
          isTrue,
        );
      },
    );

    test('rejects everything else', () {
      expect(PlaylistShareService.parseId(''), isNull);
      expect(
        PlaylistShareService.parseId('https://share.example/p/short'),
        isNull,
      );
      expect(
        PlaylistShareService.parseId('https://share.example/p/${_id}X'),
        isNull,
      );
      expect(
        PlaylistShareService.parseId('https://youtube.com/watch?v=abc'),
        isNull,
      );
    });
  });

  group('upload', () {
    test('posts gzip JSON and returns the link', () async {
      adapter.onPost(
        '$_base/api/p',
        (s) => s.reply(201, {'id': _id, 'url': '$_base/p/$_id'}),
        data: Matchers.any,
      );
      final url = await service.upload(_playlist());
      expect(url.toString(), '$_base/p/$_id');
    });

    test('sends the codec payload', () async {
      List<int>? sent;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            sent = o.data as List<int>;
            expect(o.contentType, 'application/gzip');
            h.next(o);
          },
        ),
      );
      adapter.onPost(
        '$_base/api/p',
        (s) => s.reply(201, {'id': _id, 'url': 'u'}),
        data: Matchers.any,
      );
      await service.upload(_playlist());
      final json = jsonDecode(utf8.decode(gzip.decode(sent!)));
      expect(json['format'], 'player_playlist_share');
      expect(json['playlist']['tracks'], hasLength(2));
    });

    test('refuses an empty playlist without calling the server', () async {
      expect(service.upload(_playlist(0)), _shareError('empty'));
    });

    test('maps server errors to readable messages', () async {
      for (final (status, text) in [
        (413, 'too large'),
        (429, 'try again'),
        (400, 'Playlist is empty'),
      ]) {
        adapter.onPost(
          '$_base/api/p',
          (s) => s.reply(status, {'error': 'Playlist is empty'}),
          data: Matchers.any,
        );
        await expectLater(service.upload(_playlist()), _shareError(text));
      }
    });

    test('reports an unreachable server', () async {
      adapter.onPost(
        '$_base/api/p',
        (s) => s.throws(
          0,
          DioException.connectionError(
            requestOptions: RequestOptions(path: '/api/p'),
            reason: 'refused',
          ),
        ),
        data: Matchers.any,
      );
      expect(service.upload(_playlist()), _shareError('Could not reach'));
    });

    test('is disabled without a base URL', () {
      final off = PlaylistShareService(dio: dio, baseUrl: '');
      expect(off.isEnabled, isFalse);
      expect(off.upload(_playlist()), _shareError('not configured'));
    });
  });

  group('fetch', () {
    test('decodes the snapshot', () async {
      adapter.onGet('$_base/api/p/$_id', (s) => s.reply(200, _snapshot()));
      final p = await service.fetch(_id);
      expect(p.name, 'Road trip');
      expect(p.tracks, hasLength(2));
    });

    test('404 means a broken link', () async {
      adapter.onGet(
        '$_base/api/p/$_id',
        (s) => s.reply(404, {'error': 'Playlist not found'}),
      );
      expect(service.fetch(_id), _shareError('not found'));
    });

    test('corrupted data is reported, not thrown raw', () async {
      adapter.onGet(
        '$_base/api/p/$_id',
        (s) => s.reply(200, utf8.encode('garbage')),
      );
      expect(service.fetch(_id), _shareError('corrupted'));
    });

    test('fetchFromLink fetches by the id from a full link', () async {
      adapter.onGet('$_base/api/p/$_id', (s) => s.reply(200, _snapshot()));
      final p = await service.fetchFromLink(
        'Listen: https://share.example/p/$_id',
      );
      expect(p.name, 'Road trip');
    });

    test('fetchFromLink rejects non-links', () {
      expect(
        service.fetchFromLink('hello'),
        _shareError('not a playlist link'),
      );
    });
  });

  // Тот же путь, что у «Import from link» в UI: fetchFromLink → importPlaylists.
  group('import of a fetched playlist', () {
    TestHarness.ensureInitialized();

    setUp(() async {
      await TestHarness.setUpDb();
      await PlaylistRepository.instance.resetForTesting();
    });

    tearDown(() async {
      await TestHarness.tearDownDb();
    });

    test('adds the playlist as a new one', () async {
      adapter.onGet('$_base/api/p/$_id', (s) => s.reply(200, _snapshot()));
      await PlaylistRepository.instance.ensureLoaded();
      final before = PlaylistRepository.instance.current.length;

      final result = await PlaylistRepository.instance.importPlaylists([
        await service.fetchFromLink('https://share.example/p/$_id'),
      ]);

      expect(result.added, 1);
      final all = PlaylistRepository.instance.current;
      expect(all, hasLength(before + 1));
      final imported = all.firstWhere((p) => p.name == 'Road trip');
      expect(imported.id, isNot('shared'));
      expect(imported.tracks.map((t) => t.id), ['t0', 't1']);
    });
  });
}
