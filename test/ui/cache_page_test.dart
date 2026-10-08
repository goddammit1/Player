// CachePage: общая карточка аудио-кэша (стриминговый + Soulseek) —
// суммарный размер, переход к списку треков, раздельные лимиты.

import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rxdart/rxdart.dart';

import 'package:player/core/artwork_helper.dart';
import 'package:player/core/cached_tracks_service.dart';
import 'package:player/core/player_service_interface.dart';
import 'package:player/core/providers.dart';
import 'package:player/core/soulseek_settings_repository.dart';
import 'package:player/core/youtube_cache.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/soulseek_models.dart';
import 'package:player/ui/pages/cache_page.dart';
import 'package:player/ui/pages/cached_tracks_page.dart';

import '../setup/test_harness.dart';

/// Плеер-заглушка: страницам нужны только mediaItem-поток и setQueue.
class _FakePlayer extends Fake implements PlayerServiceInterface {
  @override
  Stream<MediaItem?> get mediaItem => BehaviorSubject<MediaItem?>.seeded(null);
}

SoulseekCacheEntry _slsk(String key) => SoulseekCacheEntry(
      cacheKey: key,
      localPath: '/data/cache/$key.flac',
      sizeBytes: 3 * 1024 * 1024,
      complete: true,
      pinned: false,
      title: 'Soul $key',
      artist: 'Peer',
      cachedAt: DateTime.now(),
    );

void main() {
  TestHarness.ensureInitialized();

  late Directory tempDir;
  const methods = MethodChannel('soulseek/methods');

  setUp(() async {
    await TestHarness.setUpDb();
    ArtworkHelper.disableDbReadsForTesting = true;
    tempDir = Directory.systemTemp.createTempSync('cache_page_');
    final audio = Directory(p.join(tempDir.path, 'audio'))..createSync();
    final art = Directory(p.join(tempDir.path, 'art'))..createSync();
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setAudioDirForTesting(audio);
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setArtworkDirForTesting(art);
    File(p.join(audio.path, 'muzmo_1.mp3'))
        .writeAsBytesSync(List.filled(1024 * 1024, 0));
    // syncToNative лимита Soulseek уходит в натив — глушим канал.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (_) async => true);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, null);
    ArtworkHelper.disableDbReadsForTesting = false;
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.cancelPendingEvictionForTesting();
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setAudioDirForTesting(null);
    // ignore: invalid_use_of_visible_for_testing_member
    YoutubeCache.instance.setArtworkDirForTesting(null);
    await TestHarness.tearDownDb();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget host() {
    final service = CachedTracksService(
      loadSoulseekEntries: () async => [_slsk('ck1')],
      removeSoulseekEntry: (_) async => true,
      pinSoulseekEntry: (_, _) async {},
      soulseekTrackFor: (e) => Track(
        id: e.cacheKey,
        sourceId: 'soulseek',
        title: e.title ?? '',
        artist: e.artist ?? '',
      ),
      knownTracks: () => const [],
    );
    return ProviderScope(
      overrides: [
        playerServiceProvider.overrideWithValue(_FakePlayer()),
        cachedTracksServiceProvider.overrideWithValue(service),
        vibrationEnabledProvider
            .overrideWith((ref) => VibrationNotifier.seeded(false)),
      ],
      child: const MaterialApp(home: CachePage()),
    );
  }

  /// Страница считает размеры реальным I/O — ждём в runAsync.
  Future<void> pumpLoaded(WidgetTester tester, {String until = '2 tracks'}) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(host());
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.textContaining(until).evaluate().isNotEmpty) break;
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('общая карточка: сумма обоих кэшей и два лимита', (tester) async {
    await pumpLoaded(tester);

    expect(find.text('Cached tracks'), findsOneWidget);
    expect(find.text('4.0 MB • 2 tracks'), findsOneWidget);
    expect(find.text('Streaming size limit'), findsOneWidget);
    expect(find.text('Soulseek size limit'), findsOneWidget);
    expect(find.text('1.0 MB of 5 GB'), findsOneWidget);
    expect(find.text('3.0 MB of 1 GB'), findsOneWidget);
  });

  testWidgets('лимит Soulseek сохраняется в настройках Soulseek',
      (tester) async {
    await pumpLoaded(tester);

    await tester.runAsync(() async {
      await tester.tap(find.text('2 GB'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    final settings = await tester
        .runAsync(() => SoulseekSettingsRepository.instance.loadAll());
    expect(settings!.cacheLimitMB, 2048);
    expect(find.text('3.0 MB of 2 GB'), findsOneWidget);
  });

  testWidgets('тап по карточке открывает список кэш-треков', (tester) async {
    await pumpLoaded(tester);

    await tester.runAsync(() async {
      await tester.tap(find.text('Cached tracks'));
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.text('Soul ck1').evaluate().isNotEmpty) break;
      }
    });
    await tester.pumpAndSettle();

    expect(find.byType(CachedTracksPage), findsOneWidget);
    expect(find.text('Soul ck1'), findsOneWidget);
    expect(find.text('muzmo_1'), findsOneWidget);
  });

  testWidgets('без Android лимита Soulseek нет', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpLoaded(tester);
      expect(find.text('Streaming size limit'), findsOneWidget);
      expect(find.text('Soulseek size limit'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
