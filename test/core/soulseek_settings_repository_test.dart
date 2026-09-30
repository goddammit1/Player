// test/core/soulseek_settings_repository_test.dart
//
// Фаза A (SQLite-миграция настроек Soulseek) — тесты репозитория.
//
// Покрывает:
// - Дефолты при пустой БД (как в бывшем SoulseekPrefs)
// - Roundtrip save/load всех настроек через AppDatabase
// - loadAll после точечных set-методов
// - buildFilters / applyToSource: фильтры и таймаут применяются к
//   SoulseekSource (разрыв №2 устранён на уровне репозитория)
// - isEnabled / setEnabled (feature flag в БД)

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/database/app_database.dart';
import 'package:player/core/soulseek_settings_repository.dart';
import 'package:player/sources/soulseek_models.dart';
import 'package:player/sources/soulseek_source.dart';

import '../setup/test_harness.dart';

/// Минимальный фейковый канал: реальные вызовы не нужны, важно только,
/// чтобы конструктор SoulseekSource не тянул платформенный канал.
class _FakeChannel implements SoulseekChannel {
  @override
  bool get isAvailable => false;

  @override
  Future<List<SoulseekSearchResult>> search({
    required String requestId,
    required String query,
    required int timeoutMs,
    required int idleTimeoutMs,
    required int responseLimit,
    required int fileLimit,
    required SoulseekSearchFilters filters,
  }) async => const [];

  @override
  Future<SoulseekCacheEntry?> getCacheEntry(String cacheKey) async => null;

  @override
  Future<List<SoulseekCacheEntry>> getCacheEntries() async => const [];

  @override
  Future<SoulseekDownloadResult> startDownload({
    required String downloadId,
    required String peerUsername,
    required String remoteFilename,
    required int sizeBytes,
    required String cacheKey,
    required String fileExtension,
    String? title,
    String? artist,
    int? durationSeconds,
  }) => throw UnimplementedError();

  @override
  Future<SoulseekTransferInfo?> getTransfer(String downloadId) async => null;

  @override
  Stream<SoulseekTransferEvent> get transferEvents =>
      const Stream<SoulseekTransferEvent>.empty();
}

void main() {
  TestHarness.ensureInitialized();
  // Фаза B: set-методы натив-ключей зовут syncToNative → обращаются к
  // SoulseekPlatformChannel.instance (EventChannel требует binding).
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async => await TestHarness.setUpDb());
  tearDown(() async => await TestHarness.tearDownDb());

  group('SoulseekSettingsRepository - defaults', () {
    test('loadAll returns defaults when DB is empty', () async {
      final s = await SoulseekSettingsRepository.instance.loadAll();

      expect(s.enabled, isFalse);
      expect(s.listenPort, 24150);
      expect(s.cacheLimitMB, 1024);
      expect(s.maxParallelDownloads, 3);
      expect(s.preferLossless, isFalse);
      expect(s.allowedFormats, {'flac', 'wav', 'alac', 'mp3', 'aac', 'ogg'});
      expect(s.maxFileSizeMB, 0);
      expect(s.searchTimeoutSec, 10);
      expect(s.sharingDirectory, '');
    });

    test('isEnabled defaults to false when key is missing', () async {
      expect(await SoulseekSettingsRepository.instance.isEnabled(), isFalse);
    });
  });

  group('SoulseekSettingsRepository - roundtrip', () {
    test('save all → loadAll returns saved values', () async {
      final repo = SoulseekSettingsRepository.instance;

      await repo.setEnabled(true);
      await repo.setListenPort(12345);
      await repo.setCacheLimitMB(2048);
      await repo.setMaxParallelDownloads(5);
      await repo.setPreferLossless(true);
      await repo.setAllowedFormats({'flac', 'wav'});
      await repo.setMaxFileSizeMB(300);
      await repo.setSearchTimeoutSec(42);
      await repo.setSharingDirectory('/storage/emulated/0/Music');

      final s = await repo.loadAll();

      expect(s.enabled, isTrue);
      expect(s.listenPort, 12345);
      expect(s.cacheLimitMB, 2048);
      expect(s.maxParallelDownloads, 5);
      expect(s.preferLossless, isTrue);
      expect(s.allowedFormats, {'flac', 'wav'});
      expect(s.maxFileSizeMB, 300);
      expect(s.searchTimeoutSec, 42);
      expect(s.sharingDirectory, '/storage/emulated/0/Music');
    });

    test('overwrite works (last write wins)', () async {
      final repo = SoulseekSettingsRepository.instance;
      await repo.setSearchTimeoutSec(10);
      await repo.setSearchTimeoutSec(20);
      expect((await repo.loadAll()).searchTimeoutSec, 20);
    });

    test('empty allowed formats set → empty set on load', () async {
      final repo = SoulseekSettingsRepository.instance;
      await repo.setAllowedFormats({});
      // Пустая строка в БД → loadAll даёт пустой set (без ограничений).
      expect((await repo.loadAll()).allowedFormats, isEmpty);
    });

    test('values persist across DB reopen', () async {
      final repo = SoulseekSettingsRepository.instance;
      await repo.setListenPort(9999);
      await AppDatabase.instance.close();
      await TestHarness.setUpDb(); // переоткрытие того же файла
      expect((await repo.loadAll()).listenPort, 9999);
    });
  });

  group('SoulseekSettingsRepository - filters', () {
    test('buildFilters maps settings to SoulseekSearchFilters', () {
      final repo = SoulseekSettingsRepository.instance;
      final filters = repo.buildFilters(const SoulseekSettings(
        allowedFormats: {'flac', 'mp3'},
        maxFileSizeMB: 100,
        preferLossless: true,
      ));

      expect(filters.extensions, containsAll(['flac', 'mp3']));
      expect(filters.maxSizeBytes, 100 * 1024 * 1024);
      expect(filters.losslessOnly, isTrue);
    });

    test('buildFilters: no formats and unlimited size → no restrictions', () {
      final repo = SoulseekSettingsRepository.instance;
      final filters = repo.buildFilters(const SoulseekSettings(
        allowedFormats: {},
        maxFileSizeMB: 0,
      ));

      expect(filters.extensions, isNull);
      expect(filters.maxSizeBytes, isNull);
      expect(filters.losslessOnly, isFalse);
    });

    test('applyToSource sets searchFilters and timeout on source', () async {
      final repo = SoulseekSettingsRepository.instance;
      await repo.setAllowedFormats({'flac'});
      await repo.setMaxFileSizeMB(50);
      await repo.setPreferLossless(true);
      await repo.setSearchTimeoutSec(25);

      final source = SoulseekSource(channel: _FakeChannel());
      expect(source.searchFilters, same(SoulseekSearchFilters.empty));

      await repo.applyToSource(source);

      expect(source.searchFilters.extensions, ['flac']);
      expect(source.searchFilters.maxSizeBytes, 50 * 1024 * 1024);
      expect(source.searchFilters.losslessOnly, isTrue);
      expect(source.searchTimeoutMs, 25000);
    });

    test('applyToSource with explicit settings does not read DB', () async {
      final repo = SoulseekSettingsRepository.instance;
      // БД пуста — если бы applyToSource читал её, таймаут был бы 15 c.
      final source = SoulseekSource(channel: _FakeChannel());
      await repo.applyToSource(
        source,
        settings: const SoulseekSettings(searchTimeoutSec: 7),
      );
      expect(source.searchTimeoutMs, 7000);
    });
  });

  group('SoulseekSettingsRepository - native sync (Фаза B, разрыв №3)', () {
    // Мок MethodChannel по образцу soulseek_stage3_ui_test.dart: без него
    // реальный канал в тестах кидает MissingPluginException. isAvailable
    // у SoulseekPlatformChannel требует Android — переопределяем платформу.
    const methodsChannel = MethodChannel('soulseek/methods');

    test('set-методы натив-ключей шлют updateNativeSettings с актуальными значениями', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodsChannel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodsChannel, null);
      });

      final repo = SoulseekSettingsRepository.instance;
      await repo.setListenPort(24150);
      await repo.setCacheLimitMB(2048);
      await repo.setMaxParallelDownloads(5);

      // Каждый set-метод синкает независимо, но payload всегда полный
      // снапшот натив-релевантных настроек из БД.
      expect(calls, hasLength(3));
      expect(
        calls.every((c) => c.method == 'updateNativeSettings'),
        isTrue,
      );
      // arguments приходит как Map<Object?, Object?> — не кастуем напрямую.
      final args = calls.last.arguments as Map;
      expect(args['listenPort'], 24150);
      expect(args['cacheLimitMb'], 2048);
      expect(args['maxParallelDownloads'], 5);
    });

    test('syncToNative не бросает, когда натив отвечает ошибкой', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodsChannel, (call) async {
        throw PlatformException(code: 'SERVICE_BIND_TIMEOUT');
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodsChannel, null);
      });

      final repo = SoulseekSettingsRepository.instance;
      await repo.setListenPort(12345);
      // Значение сохранено в Dart-БД, ошибка синка проглочена.
      expect((await repo.loadAll()).listenPort, 12345);
    });

    test('на не-Android синк — no-op без вызова канала', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // Детерминированно: не-Android платформа независимо от хоста.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      var invoked = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodsChannel, (call) async {
        invoked = true;
        return true;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodsChannel, null);
      });

      // isAvailable == false → ранний return, канал не трогаем.
      await SoulseekSettingsRepository.instance.syncToNative();
      expect(invoked, isFalse);
    });
  });
}
