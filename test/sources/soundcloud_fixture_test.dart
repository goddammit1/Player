import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/soundcloud_source.dart';

void main() {
  late SoundCloudSource s;
  setUp(() => s = SoundCloudSource());
  tearDown(() => s.dispose());

  Map<String, dynamic> t(int id, String title, String artist,
      {int dur = 200000, String? art, List<Map<String, dynamic>>? tc}) {
    return {
      'kind': 'track', 'id': id, 'title': title, 'duration': dur,
      'user': {'username': artist},
      // ignore: use_null_aware_elements
      if (art != null) 'artwork_url': art,
      'media': {
        'transcodings': tc ?? [
          {'url': 'https://api.soundcloud.com/stream/$id',
           'preset': 'mp3_0_0', 'quality': 'sq',
           'format': {'protocol': 'progressive', 'mime_type': 'audio/mpeg'}}]}};
  }

  String json(List<Map<String, dynamic>> items) =>
      jsonEncode({'collection': items});

  group('parseTracks', () {
    test('basic', () {
      final r = s.parseTracks(jsonDecode(json([t(123, 'Song', 'artist1')])), 10);
      expect(r.length, 1);
      expect(r.first.id, '123');
      expect(r.first.artist, 'artist1');
    });
    test('filters DRM', () {
      final r = s.parseTracks(jsonDecode(json([t(1, 'T', 'A', tc: [
        {'url': 'https://x.com/e', 'format': {'protocol': 'cbc-encrypted-hls'}}])])), 10);
      expect(r, isEmpty);
    });
    test('filters non-track', () {
      final j = jsonEncode({'collection': [{'kind': 'playlist', 'id': 9, 'title': 'P',
        'duration': 1, 'user': {'username': 'u'}, 'media': {'transcodings': [
        {'url': 'https://x.com/s', 'format': {'protocol': 'progressive', 'mime_type': 'aac'}}]}}]});
      expect(s.parseTracks(jsonDecode(j), 10), isEmpty);
    });
    test('limit', () {
      final items = List.generate(5, (i) => t(i, 'S$i', 'A$i'));
      expect(s.parseTracks(jsonDecode(json(items)), 3).length, 3);
    });
    test('no media skip', () {
      final j = jsonEncode({'collection': [{'kind': 'track', 'id': 1, 'title': 'X',
        'user': {'username': 'u'}, 'media': {}}]});
      expect(s.parseTracks(jsonDecode(j), 10), isEmpty);
    });
    test('artwork', () {
      final r = s.parseTracks(jsonDecode(
        json([t(7, 'A', 'V', art: 'https://i1.sndcdn.com/artworks-x-large.jpg')])), 10);
      expect(r.first.artworkUrl, contains('sndcdn.com'));
    });
    test('empty input', () {
      expect(s.parseTracks(null, 10), isEmpty);
      expect(s.parseTracks('{}', 10), isEmpty);
    });
  });
}
