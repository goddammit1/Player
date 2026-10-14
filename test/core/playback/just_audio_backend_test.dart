// Регресс мобилки: PlaybackSource превращается ровно в те just_audio-объекты,
// которые раньше создавали сами источники.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:player/core/playback/just_audio_backend.dart';
import 'package:player/sources/playback_source.dart';
import 'package:player/sources/soulseek_stream_audio_source.dart';

void main() {
  test('LocalFile → file:// UriAudioSource', () {
    final s = toJustAudioSource(const LocalFile('/cache/a.mp3'), tag: 't');
    expect(s, isA<UriAudioSource>());
    expect((s as UriAudioSource).uri, Uri.file('/cache/a.mp3'));
    expect(s.tag, 't');
  });

  test('RemoteStream with a cache path → LockCachingAudioSource', () {
    final s = toJustAudioSource(
      RemoteStream(
        Uri.parse('https://cdn/a.mp3'),
        headers: const {'Referer': 'https://muzmo/'},
        cachePath: '/cache/muzmo_1.mp3',
      ),
      tag: 'muzmo:1',
    );
    expect(s, isA<LockCachingAudioSource>());
    final lc = s as LockCachingAudioSource;
    expect(lc.uri, Uri.parse('https://cdn/a.mp3'));
    expect(lc.headers, {'Referer': 'https://muzmo/'});
    expect(lc.tag, 'muzmo:1');
    expect(File('/cache/muzmo_1.mp3').path, endsWith('muzmo_1.mp3'));
  });

  test('RemoteStream without headers passes null headers', () {
    final s = toJustAudioSource(
      RemoteStream(Uri.parse('https://yt/a'), cachePath: '/cache/a.m4a'),
    );
    expect((s as LockCachingAudioSource).headers, isNull);
  });

  test('RemoteStream without a cache path → plain UriAudioSource', () {
    final s = toJustAudioSource(RemoteStream(Uri.parse('https://x/a.mp3')));
    expect(s, isA<UriAudioSource>());
    expect((s as UriAudioSource).uri, Uri.parse('https://x/a.mp3'));
  });

  test('Hls → UriAudioSource with headers', () {
    final s = toJustAudioSource(Hls(
      Uri.parse('https://sc/playlist.m3u8'),
      headers: const {'Accept-Encoding': 'identity'},
    ));
    expect(s, isA<UriAudioSource>());
    expect((s as UriAudioSource).headers, {'Accept-Encoding': 'identity'});
  });

  test('GrowingFile → SoulseekStreamAudioSource', () {
    final s = toJustAudioSource(GrowingFile(
      partPath: '/slsk/ck.part',
      totalBytes: 1000,
      contentType: 'audio/flac',
      completion: Future<String>.value('/slsk/ck.flac'),
    ));
    expect(s, isA<SoulseekStreamAudioSource>());
    final stream = s as SoulseekStreamAudioSource;
    expect(stream.partPath, '/slsk/ck.part');
    expect(stream.totalBytes, 1000);
    expect(stream.contentType, 'audio/flac');
  });
}
