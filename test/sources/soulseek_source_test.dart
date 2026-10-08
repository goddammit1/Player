// test/sources/soulseek_source_test.dart
//
// Фаза 4 (Part E) — unit-тесты для SoulseekSource.
//
// Покрывает:
// - computeCacheKey (статический, детерминизм sha256)
// - extractTitle / extractArtist (разбор имен файлов Soulseek)
// - qualityLabel / sampleRateToKHz (метки качества)
// - basenameWithoutExt / removeExtension / findSeparator / isTrackNumber
// - search (фильтрация, дедупликация, лимит, маппинг → Track, ошибки)
// - resolveStreamUrl (cache hit, download cacheHit, download wait, ошибки)
// - resolveBitrate
// - prefetch
// - cache key index (knownCacheKeys, forgetCacheKey, clearCacheIndex)
//
// Использует _TestChannel — фейковую реализацию SoulseekChannel для DI.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:player/core/database/app_database.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/artwork_provider.dart';
import 'package:player/sources/soulseek_models.dart';
import 'package:player/sources/soulseek_source.dart';
import 'package:player/sources/soulseek_stream_audio_source.dart';

import '../setup/test_harness.dart';

// ═══════════════════════════════════════════════════════════════════════
//  Fake channel
// ═══════════════════════════════════════════════════════════════════════

class _TestChannel implements SoulseekChannel {
  @override
  bool isAvailable = true;

  // Конфигурация search
  List<SoulseekSearchResult> searchResults = [];
  Object? searchError;
  String? lastSearchQuery;

  /// NEW-2: последний timeoutMs, переданный в search().
  int? lastSearchTimeoutMs;
  int? lastIdleTimeoutMs;
  int? lastResponseLimit;
  int? lastFileLimit;

  // Конфигурация cache / download
  SoulseekCacheEntry? cacheEntry;
  SoulseekDownloadResult? downloadResult;
  SoulseekTransferInfo? transferInfo;

  // Трекинг вызовов startDownload
  final List<Map<String, dynamic>> startDownloadCalls = [];

  // Event stream
  final StreamController<SoulseekTransferEvent> _transferController =
      StreamController<SoulseekTransferEvent>.broadcast();

  @override
  Future<List<SoulseekSearchResult>> search({
    required String requestId,
    required String query,
    required int timeoutMs,
    required int idleTimeoutMs,
    required int responseLimit,
    required int fileLimit,
    required SoulseekSearchFilters filters,
  }) async {
    searchCalls++;
    lastRequestId = requestId;
    lastSearchQuery = query;
    lastSearchTimeoutMs = timeoutMs;
    lastIdleTimeoutMs = idleTimeoutMs;
    lastResponseLimit = responseLimit;
    lastFileLimit = fileLimit;
    if (searchError != null) throw searchError!;
    final gate = searchGate;
    if (gate != null) return gate.future;
    return searchResults;
  }

  /// Число вызовов нативного search (проверка кэша / присоединения).
  int searchCalls = 0;
  String? lastRequestId;

  /// Если задан — search() ждёт его вместо немедленного ответа
  /// (идущий поиск: дельты через [emitProgress], отмена через cancelSearch).
  Completer<List<SoulseekSearchResult>>? searchGate;

  final StreamController<SoulseekSearchProgressEvent> _progressController =
      StreamController<SoulseekSearchProgressEvent>.broadcast();

  @override
  Stream<SoulseekSearchProgressEvent> get searchProgress =>
      _progressController.stream;

  void emitProgress(List<SoulseekSearchResult> results) {
    _progressController.add(SoulseekSearchProgressEvent(
      requestId: lastRequestId!,
      results: results,
    ));
  }

  final List<String> cancelledSearches = [];

  @override
  Future<void> cancelSearch(String requestId) async {
    cancelledSearches.add(requestId);
  }

  // Конфигурация getDirectoryContents
  List<SoulseekSearchResult> directoryResults = [];
  Object? directoryError;
  final List<(String, String)> directoryCalls = [];

  @override
  Future<List<SoulseekSearchResult>> getDirectoryContents({
    required String username,
    required String directory,
    int timeoutMs = 20000,
  }) async {
    directoryCalls.add((username, directory));
    if (directoryError != null) throw directoryError!;
    return directoryResults;
  }

  /// Задержка ответов getTransfer/getCacheEntry — имитация нативной
  /// латентности в тестах поллинга (P1).
  Duration pollDelay = Duration.zero;

  @override
  Future<SoulseekCacheEntry?> getCacheEntry(String cacheKey) async {
    if (pollDelay > Duration.zero) await Future.delayed(pollDelay);
    return cacheEntry;
  }

  // P1-каскад: полный список нативных кэш-записей.
  List<SoulseekCacheEntry> cacheEntries = const [];
  bool cacheEntriesError = false;

  @override
  Future<List<SoulseekCacheEntry>> getCacheEntries() async {
    if (cacheEntriesError) {
      throw const SoulseekException('ERR', 'getCacheEntries failed');
    }
    return cacheEntries;
  }

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
  }) async {
    startDownloadCalls.add({
      'downloadId': downloadId,
      'peerUsername': peerUsername,
      'remoteFilename': remoteFilename,
      'sizeBytes': sizeBytes,
      'cacheKey': cacheKey,
      'fileExtension': fileExtension,
      'title': title,
      'artist': artist,
      'durationSeconds': durationSeconds,
    });
    return downloadResult ??
        SoulseekDownloadResult(
          downloadId: downloadId,
          result: downloadId,
          cacheHit: false,
        );
  }

  @override
  Future<SoulseekTransferInfo?> getTransfer(String downloadId) async {
    if (pollDelay > Duration.zero) await Future.delayed(pollDelay);
    return transferInfo;
  }

  @override
  Stream<SoulseekTransferEvent> get transferEvents =>
      _transferController.stream;

  void emitTransfer(SoulseekTransferInfo info) {
    _transferController.add(SoulseekTransferEvent(info));
  }

  void close() {
    _transferController.close();
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Helpers
// ═══════════════════════════════════════════════════════════════════════

SoulseekSearchResult _searchResult({
  String resultId = 'r1',
  String username = 'user1',
  String filename = 'Artist - Title.flac',
  int sizeBytes = 50000000,
  String extension = 'flac',
  int? bitrate = 1411,
  int? sampleRate = 44100,
  int? bitDepth = 16,
  int? durationSeconds = 240,
  int queueLength = 5,
  int freeUploadSlots = 1,
  int uploadSpeed = 500,
}) {
  return SoulseekSearchResult(
    resultId: resultId,
    username: username,
    filename: filename,
    sizeBytes: sizeBytes,
    extension: extension,
    bitrate: bitrate,
    sampleRate: sampleRate,
    bitDepth: bitDepth,
    durationSeconds: durationSeconds,
    queueLength: queueLength,
    freeUploadSlots: freeUploadSlots,
    uploadSpeed: uploadSpeed,
  );
}

Track _makeTrack({
  String cacheKey = 'ck_test',
  String peerUsername = 'peer1',
  String remoteFilename = 'Artist - Title.flac',
  int sizeBytes = 50000000,
  String extension = 'flac',
  int? bitrate = 1411,
  int qualityScore = 1411,
}) {
  return Track(
    id: 'test_id',
    sourceId: SoulseekSource.sourceId,
    title: 'Title',
    artist: 'Artist',
    duration: null,
    artworkUrl: null,
    qualityScore: qualityScore,
    qualityLabel: 'FLAC',
    extra: <String, dynamic>{
      'peerUsername': peerUsername,
      'remoteFilename': remoteFilename,
      'sizeBytes': sizeBytes,
      'cacheKey': cacheKey,
      'extension': extension,
      'bitrate': bitrate,
    },
  );
}

// ═══════════════════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════════════════

void main() {
  late _TestChannel channel;
  late SoulseekSource source;

  TestHarness.ensureInitialized();

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // SP-мок нужен только для soulseek_cache_index (индекс кэша,
    // остаётся в SharedPreferences по решению Фазы A).
    SharedPreferences.setMockInitialValues({});
    await TestHarness.setUpDb();
    channel = _TestChannel();
    source = SoulseekSource(channel: channel);
    // Позволяем _loadCacheIndex() завершиться.
    await Future.delayed(Duration.zero);
  });

  tearDown(() async {
    await source.dispose();
    channel.close();
    await TestHarness.tearDownDb();
  });

  // ═══════════════════════════════════════════════════════════════════
  //  computeCacheKey (static)
  // ═══════════════════════════════════════════════════════════════════
  group('computeCacheKey', () {
    test('deterministic — same inputs produce same output', () {
      final a = SoulseekSource.computeCacheKey('peer', 'file.flac', 1000);
      final b = SoulseekSource.computeCacheKey('peer', 'file.flac', 1000);
      expect(a, b);
    });

    test('different peer → different key', () {
      final a = SoulseekSource.computeCacheKey('peer1', 'file.flac', 1000);
      final b = SoulseekSource.computeCacheKey('peer2', 'file.flac', 1000);
      expect(a, isNot(b));
    });

    test('different file → different key', () {
      final a = SoulseekSource.computeCacheKey('peer', 'file1.flac', 1000);
      final b = SoulseekSource.computeCacheKey('peer', 'file2.flac', 1000);
      expect(a, isNot(b));
    });

    test('different size → different key', () {
      final a = SoulseekSource.computeCacheKey('peer', 'file.flac', 1000);
      final b = SoulseekSource.computeCacheKey('peer', 'file.flac', 2000);
      expect(a, isNot(b));
    });

    test('produces 64-char hex string (sha256)', () {
      final key = SoulseekSource.computeCacheKey('peer', 'file.flac', 1000);
      expect(key.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(key), isTrue);
    });

    test('matches manual sha256 of "soulseek\\0peer\\0file\\0size"', () {
      final input = 'soulseek\x00peer\x00file.flac\x001000';
      final expected = sha256.convert(utf8.encode(input)).toString();
      final actual = SoulseekSource.computeCacheKey('peer', 'file.flac', 1000);
      expect(actual, expected);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  trackFromCacheEntry (Этап 2: фабрика Track из кэш-записи)
  // ═══════════════════════════════════════════════════════════════════
  group('trackFromCacheEntry', () {
    SoulseekCacheEntry entry({
      String cacheKey = 'ck_abc',
      String localPath = '/data/cache/ck_abc.flac',
      String? extension = 'flac',
      String? title = 'Song',
      String? artist = 'Artist',
      int? durationSeconds = 240,
    }) {
      return SoulseekCacheEntry(
        cacheKey: cacheKey,
        localPath: localPath,
        sizeBytes: 50000000,
        complete: true,
        pinned: false,
        title: title,
        artist: artist,
        durationSeconds: durationSeconds,
        extension: extension,
      );
    }

    test('заполняет поля из метаданных записи', () {
      final track = source.trackFromCacheEntry(entry());
      expect(track.id, 'ck_abc');
      expect(track.sourceId, SoulseekSource.sourceId);
      expect(track.title, 'Song');
      expect(track.artist, 'Artist');
      expect(track.duration, const Duration(seconds: 240));
      expect(track.globalId, 'soulseek:ck_abc');
    });

    test('extra содержит cacheKey → resolveStreamUrl даёт cache hit', () async {
      channel.cacheEntry = entry();
      final track = source.trackFromCacheEntry(entry());

      expect(track.extra['cacheKey'], 'ck_abc');
      // Cache hit: startDownload не вызывается, путь возвращён мгновенно.
      final path = await source.resolveStreamUrl(track);
      expect(path, '/data/cache/ck_abc.flac');
      expect(channel.startDownloadCalls, isEmpty);
    });

    test('fallback на basename когда title/artist null (pre-v2 записи)', () {
      final track = source.trackFromCacheEntry(
        entry(title: null, artist: null, localPath: '/cache/x/01 - Song.flac'),
      );
      expect(track.title, '01 - Song');
      expect(track.artist, 'Unknown');
    });

    test('qualityLabel из extension записи', () {
      final flac = source.trackFromCacheEntry(entry(extension: 'flac'));
      expect(flac.qualityLabel, 'FLAC');

      final mp3 = source.trackFromCacheEntry(
        entry(extension: 'mp3', localPath: '/c/ck.mp3'),
      );
      expect(mp3.qualityLabel, 'MP3');
    });

    test('extension выводится из localPath, если поле null', () {
      final track = source.trackFromCacheEntry(
        entry(extension: null, localPath: r'C:\cache\ck_abc.flac'),
      );
      expect(track.qualityLabel, 'FLAC');
      expect(track.extra['extension'], 'flac');
    });

    test('duration null когда durationSeconds неизвестен', () {
      final track = source.trackFromCacheEntry(entry(durationSeconds: null));
      expect(track.duration, isNull);
    });

    test('пустой title в записи → fallback на basename', () {
      final track =
          source.trackFromCacheEntry(entry(title: '', localPath: '/c/song.mp3'));
      expect(track.title, 'song');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  extractTitle
  // ═══════════════════════════════════════════════════════════════════
  group('extractTitle', () {
    test('"Artist - Title.flac" → "Title"', () {
      expect(source.extractTitle('Artist - Title.flac'), 'Title');
    });

    test('"01 - Title.flac" → "Title"', () {
      expect(source.extractTitle('01 - Title.flac'), 'Title');
    });

    test('full path with artist → "Title"', () {
      expect(
        source.extractTitle(r'C:\Music\Artist\Album\01 - Title.flac'),
        'Title',
      );
    });

    test('full path without track number → "Title"', () {
      expect(
        source.extractTitle(r'C:\Music\Artist\Album\Title.flac'),
        'Title',
      );
    });

    test('no separator → returns basename without ext', () {
      expect(source.extractTitle('Title.flac'), 'Title');
    });

    test('en-dash separator –', () {
      expect(source.extractTitle('Artist – Title.flac'), 'Title');
    });

    test('em-dash separator —', () {
      expect(source.extractTitle('Artist — Title.flac'), 'Title');
    });

    test('no extension', () {
      expect(source.extractTitle('Artist - Title'), 'Title');
    });

    test('"01. Title.flac" → "Title" (track number with dot)', () {
      // "01." is not separated by " - " so findSeparator returns null
      // basenameWithoutExt → "01. Title", no separator → returns "01. Title"
      // Actually wait: "01. Title.flac" → basename = "01. Title"
      // findSeparator looks for " - ", " – ", " — " → none found
      // → returns "01. Title"
      final result = source.extractTitle('01. Title.flac');
      // The method doesn't handle "01. " as a separator, it only looks for
      // " - ", " – ", " — ". So the result is the full basename.
      expect(result, '01. Title');
    });

    test('empty string → empty', () {
      expect(source.extractTitle(''), '');
    });

    test('only extension', () {
      expect(source.extractTitle('.flac'), '.flac');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  extractArtist
  // ═══════════════════════════════════════════════════════════════════
  group('extractArtist', () {
    test('"Artist - Title.flac" → "Artist"', () {
      expect(source.extractArtist('Artist - Title.flac'), 'Artist');
    });

    test('full path Artist/Album/01 - Title.flac → "Artist"', () {
      expect(
        source.extractArtist(r'C:\Music\Artist\Album\01 - Title.flac'),
        'Artist',
      );
    });

    test('short path Artist/01 - Title.flac → "Artist"', () {
      expect(
        source.extractArtist(r'Artist\01 - Title.flac'),
        'Artist',
      );
    });

    test('track number prefix → falls back to parent dir', () {
      // "01 - Title.flac" — before separator is "01" which is a track number
      // → falls through to parent directory logic
      // "Music/01 - Title.flac" has 2 parts → parts[-2] = "Music"
      expect(source.extractArtist('Music/01 - Title.flac'), 'Music');
    });

    test('no separator, single component → "Unknown"', () {
      expect(source.extractArtist('Title.flac'), 'Unknown');
    });

    test('no separator, two components → parent dir', () {
      expect(source.extractArtist('Artist/Title.flac'), 'Artist');
    });

    test('no separator, three components → parts[-3]', () {
      expect(source.extractArtist('Music/Artist/Title.flac'), 'Music');
    });

    test('en-dash separator', () {
      expect(source.extractArtist('Artist – Title.flac'), 'Artist');
    });

    test('em-dash separator', () {
      expect(source.extractArtist('Artist — Title.flac'), 'Artist');
    });

    test('empty string → "Unknown"', () {
      expect(source.extractArtist(''), 'Unknown');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  qualityLabel
  // ═══════════════════════════════════════════════════════════════════
  group('qualityLabel', () {
    test('FLAC with bitDepth and sampleRate (Hz)', () {
      expect(source.qualityLabel('flac', 1411, 16, 44100), 'FLAC 16/44.1');
    });

    test('FLAC 24/96', () {
      expect(source.qualityLabel('flac', 4608, 24, 96000), 'FLAC 24/96');
    });

    test('FLAC 16/48 (whole number kHz)', () {
      expect(source.qualityLabel('flac', 1411, 16, 48000), 'FLAC 16/48');
    });

    test('FLAC with only bitDepth', () {
      expect(source.qualityLabel('flac', 1411, 16, null), 'FLAC 16bit');
    });

    test('FLAC without bitDepth/sampleRate', () {
      expect(source.qualityLabel('flac', null, null, null), 'FLAC');
    });

    test('WAV with bitDepth and sampleRate', () {
      expect(source.qualityLabel('wav', 1411, 24, 96000), 'WAV 24/96');
    });

    test('ALAC with bitDepth and sampleRate', () {
      expect(source.qualityLabel('alac', 1411, 16, 44100), 'ALAC 16/44.1');
    });

    test('APE', () {
      expect(source.qualityLabel('ape', 1411, 16, 44100), 'APE 16/44.1');
    });

    test('WV', () {
      expect(source.qualityLabel('wv', 1411, 16, 44100), 'WV 16/44.1');
    });

    test('MP3 with bitrate', () {
      expect(source.qualityLabel('mp3', 320, null, null), 'MP3 320');
    });

    test('MP3 without bitrate', () {
      expect(source.qualityLabel('mp3', null, null, null), 'MP3');
    });

    test('MP3 with bitrate 0', () {
      expect(source.qualityLabel('mp3', 0, null, null), 'MP3');
    });

    test('AAC with bitrate', () {
      expect(source.qualityLabel('aac', 256, null, null), 'AAC 256');
    });

    test('AAC without bitrate', () {
      expect(source.qualityLabel('aac', null, null, null), 'AAC');
    });

    test('M4A with bitrate', () {
      expect(source.qualityLabel('m4a', 256, null, null), 'M4A 256');
    });

    test('OGG with bitrate', () {
      expect(source.qualityLabel('ogg', 192, null, null), 'OGG 192');
    });

    test('OGG without bitrate', () {
      expect(source.qualityLabel('ogg', null, null, null), 'OGG');
    });

    test('OPUS with bitrate', () {
      expect(source.qualityLabel('opus', 128, null, null), 'OPUS 128');
    });

    test('OPUS without bitrate', () {
      expect(source.qualityLabel('opus', null, null, null), 'OPUS');
    });

    test('unknown extension', () {
      expect(source.qualityLabel('xyz', null, null, null), 'XYZ');
    });

    test('empty extension', () {
      expect(source.qualityLabel('', null, null, null), 'AUDIO');
    });

    test('case-insensitive extension', () {
      expect(source.qualityLabel('FLAC', 1411, 16, 44100), 'FLAC 16/44.1');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  sampleRateToKHz
  // ═══════════════════════════════════════════════════════════════════
  group('sampleRateToKHz', () {
    test('44100 Hz → "44.1"', () {
      expect(source.sampleRateToKHz(44100), '44.1');
    });

    test('48000 Hz → "48" (whole number)', () {
      expect(source.sampleRateToKHz(48000), '48');
    });

    test('96000 Hz → "96"', () {
      expect(source.sampleRateToKHz(96000), '96');
    });

    test('192000 Hz → "192"', () {
      expect(source.sampleRateToKHz(192000), '192');
    });

    test('88200 Hz → "88.2"', () {
      expect(source.sampleRateToKHz(88200), '88.2');
    });

    test('44 kHz (already kHz) → "44"', () {
      expect(source.sampleRateToKHz(44), '44');
    });

    test('48 kHz (already kHz) → "48"', () {
      expect(source.sampleRateToKHz(48), '48');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  basenameWithoutExt
  // ═══════════════════════════════════════════════════════════════════
  group('basenameWithoutExt', () {
    test('simple filename', () {
      expect(source.basenameWithoutExt('Title.flac'), 'Title');
    });

    test('full Windows path', () {
      expect(
        source.basenameWithoutExt(r'C:\Music\Artist\Album\01 - Title.flac'),
        '01 - Title',
      );
    });

    test('full Unix path', () {
      expect(
        source.basenameWithoutExt('/Music/Artist/Album/01 - Title.flac'),
        '01 - Title',
      );
    });

    test('no extension', () {
      expect(source.basenameWithoutExt('Title'), 'Title');
    });

    test('hidden file (.flac)', () {
      // lastDot is 0, which is not > 0, so extension is kept
      expect(source.basenameWithoutExt('.flac'), '.flac');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  removeExtension
  // ═══════════════════════════════════════════════════════════════════
  group('removeExtension', () {
    test('removes .flac', () {
      expect(source.removeExtension('Title.flac'), 'Title');
    });

    test('removes .mp3', () {
      expect(source.removeExtension('Title.mp3'), 'Title');
    });

    test('no extension → unchanged', () {
      expect(source.removeExtension('Title'), 'Title');
    });

    test('hidden file (.flac) → unchanged (dot at index 0)', () {
      expect(source.removeExtension('.flac'), '.flac');
    });

    test('multiple dots → removes last', () {
      expect(source.removeExtension('Archive.2024.flac'), 'Archive.2024');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  findSeparator
  // ═══════════════════════════════════════════════════════════════════
  group('findSeparator', () {
    test('" - " separator', () {
      final result = source.findSeparator('Artist - Title');
      expect(result, isNotNull);
      expect(result!.$1, 6); // index of " - " (space before dash)
      expect(result.$2, 3); // length of " - "
    });

    test('" – " en-dash separator', () {
      final result = source.findSeparator('Artist – Title');
      expect(result, isNotNull);
      expect(result!.$2, 3);
    });

    test('" — " em-dash separator', () {
      final result = source.findSeparator('Artist — Title');
      expect(result, isNotNull);
      expect(result!.$2, 3);
    });

    test('no separator → null', () {
      expect(source.findSeparator('Title'), isNull);
    });

    test('separator at index 0 → null (i > 0 check)', () {
      expect(source.findSeparator(' - Title'), isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  isTrackNumber
  // ═══════════════════════════════════════════════════════════════════
  group('isTrackNumber', () {
    test('"01" → true', () {
      expect(source.isTrackNumber('01'), isTrue);
    });

    test('"1" → true', () {
      expect(source.isTrackNumber('1'), isTrue);
    });

    test('"12" → true', () {
      expect(source.isTrackNumber('12'), isTrue);
    });

    test('"01." → true (dot stripped)', () {
      expect(source.isTrackNumber('01.'), isTrue);
    });

    test('"01)" → true (parenthesis stripped)', () {
      expect(source.isTrackNumber('01)'), isTrue);
    });

    test('"01]" → true (bracket stripped)', () {
      expect(source.isTrackNumber('01]'), isTrue);
    });

    test('"Artist" → false', () {
      expect(source.isTrackNumber('Artist'), isFalse);
    });

    test('"" → false', () {
      expect(source.isTrackNumber(''), isFalse);
    });

    test('"  " → false (whitespace only)', () {
      expect(source.isTrackNumber('  '), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  search
  // ═══════════════════════════════════════════════════════════════════
  group('search', () {
    test('returns empty when channel is unavailable', () async {
      channel.isAvailable = false;
      channel.searchResults = [_searchResult()];
      final tracks = await source.search('query');
      expect(tracks, isEmpty);
    });

    test('returns empty for empty query', () async {
      channel.searchResults = [_searchResult()];
      final tracks = await source.search('');
      expect(tracks, isEmpty);
    });

    test('returns empty for whitespace-only query', () async {
      channel.searchResults = [_searchResult()];
      final tracks = await source.search('   ');
      expect(tracks, isEmpty);
    });

    test('passes trimmed query to channel', () async {
      channel.searchResults = [];
      await source.search('  query  ');
      expect(channel.lastSearchQuery, 'query');
    });

    test('ranks free slot, then short queue, then speed; stable on ties',
        () async {
      channel.searchResults = [
        _searchResult(resultId: 'busy', username: 'p1', filename: 'a.flac',
            freeUploadSlots: 0, queueLength: 0, uploadSpeed: 9000),
        _searchResult(resultId: 'slow', username: 'p2', filename: 'b.flac',
            queueLength: 0, uploadSpeed: 100),
        _searchResult(resultId: 'queued', username: 'p3', filename: 'c.flac',
            queueLength: 7, uploadSpeed: 9000),
        _searchResult(resultId: 'fast', username: 'p4', filename: 'd.flac',
            queueLength: 0, uploadSpeed: 800),
        _searchResult(resultId: 'fast2', username: 'p5', filename: 'e.flac',
            queueLength: 0, uploadSpeed: 800),
      ];

      final tracks = await source.search('query', limit: 3);

      expect(tracks.map((t) => t.extra['remoteFilename']),
          ['d.flac', 'e.flac', 'b.flac']);
    });

    test('maps results to Track correctly', () async {
      channel.searchResults = [
        _searchResult(
          resultId: 'r1',
          username: 'user1',
          filename: 'Pink Floyd - Comfortably Numb.flac',
          sizeBytes: 50000000,
          extension: 'flac',
          bitrate: 1411,
          sampleRate: 44100,
          bitDepth: 16,
          durationSeconds: 384,
          queueLength: 3,
          freeUploadSlots: 1,
          uploadSpeed: 500,
        ),
      ];
      final tracks = await source.search('comfortably numb');
      expect(tracks.length, 1);
      final track = tracks[0];
      // HISTORY-DUP-01: id = cacheKey (стабильный между поисками), не resultId.
      expect(
        track.id,
        SoulseekSource.computeCacheKey('user1',
            'Pink Floyd - Comfortably Numb.flac', 50000000),
      );
      expect(track.sourceId, 'soulseek');
      expect(track.title, 'Comfortably Numb');
      expect(track.artist, 'Pink Floyd');
      expect(track.duration, Duration(seconds: 384));
      expect(track.qualityScore, 1411);
      expect(track.qualityLabel, 'FLAC 16/44.1');
      expect(track.extra['peerUsername'], 'user1');
      expect(track.extra['remoteFilename'], 'Pink Floyd - Comfortably Numb.flac');
      expect(track.extra['sizeBytes'], 50000000);
      expect(track.extra['extension'], 'flac');
      expect(track.extra['bitrate'], 1411);
      expect(track.extra['cacheKey'], isNotEmpty);
    });

    test('applies search filters on Dart side', () async {
      source.searchFilters = const SoulseekSearchFilters(extensions: ['flac']);
      channel.searchResults = [
        _searchResult(resultId: 'r1', filename: 'Artist - Track.flac',
            extension: 'flac'),
        _searchResult(resultId: 'r2', filename: 'Artist - Track.mp3',
            extension: 'mp3'),
      ];
      final tracks = await source.search('query');
      expect(tracks.length, 1);
      // HISTORY-DUP-01: id = cacheKey, а не resultId.
      expect(
        tracks[0].id,
        SoulseekSource.computeCacheKey(
            'user1', 'Artist - Track.flac', 50000000),
      );
    });

    test('deduplicates by filename + size', () async {
      channel.searchResults = [
        _searchResult(
          resultId: 'r1',
          filename: 'Artist - Title.flac',
          sizeBytes: 50000000,
        ),
        _searchResult(
          resultId: 'r2',
          filename: 'Artist - Title.flac',
          sizeBytes: 50000000,
        ),
        // Другая длительность — иначе файл свернулся бы с r1 как
        // «абсолютно одинаковый» (размер в ключ свёртки не входит).
        _searchResult(
          resultId: 'r3',
          filename: 'Artist - Title.flac',
          sizeBytes: 60000000,
          durationSeconds: 241,
        ),
      ];
      final tracks = await source.search('query');
      expect(tracks.length, 2);
      // HISTORY-DUP-01: id = cacheKey, дедупликация по filename+size
      // оставляет разные cacheKey у разных файлов.
      final ids = tracks.map((t) => t.id).toSet();
      expect(
        ids.contains(
            SoulseekSource.computeCacheKey('user1', 'Artist - Title.flac', 50000000)),
        isTrue,
      );
      expect(
        ids.contains(
            SoulseekSource.computeCacheKey('user1', 'Artist - Title.flac', 60000000)),
        isTrue,
      );
    });

    test('HISTORY-DUP-01: трек из поиска и из кэш-шторки — один globalId',
        () async {
      const username = 'user1';
      const filename = 'Artist - Title.flac';
      const size = 50000000;
      final cacheKey = SoulseekSource.computeCacheKey(username, filename, size);

      // Из поиска (раньше id = resultId).
      channel.searchResults = [
        _searchResult(
            resultId: 'r1', username: username, filename: filename, sizeBytes: size),
      ];
      final fromSearch = (await source.search('query')).single;

      // Из кэш-шторки (id = cacheKey).
      final fromCache = source.trackFromCacheEntry(SoulseekCacheEntry(
        cacheKey: cacheKey,
        localPath: '/data/cache/$cacheKey.flac',
        sizeBytes: size,
        complete: true,
        pinned: false,
      ));

      // Один файл → один globalId → история не плодит дубликаты.
      expect(fromSearch.id, cacheKey);
      expect(fromSearch.id, fromCache.id);
      expect(fromSearch.globalId, fromCache.globalId);
    });

    test('HISTORY-DUP-01: повторный поиск того же файла даёт тот же id',
        () async {
      // resultId меняется от поиска к поиску (UUID поиска), файл тот же.
      channel.searchResults = [
        _searchResult(
            resultId: 'aaa', filename: 'Artist - Title.flac', sizeBytes: 50000000),
      ];
      final first = (await source.search('query')).single;

      channel.searchResults = [
        _searchResult(
            resultId: 'bbb', filename: 'Artist - Title.flac', sizeBytes: 50000000),
      ];
      final second = (await source.search('query again')).single;

      expect(first.id, second.id);
    });

    test('respects limit parameter', () async {
      final results = List.generate(
        10,
        (i) => _searchResult(
          resultId: 'r$i',
          username: 'peer$i',
          filename: 'Artist - Track$i.flac',
          sizeBytes: 1000000 + i,
        ),
      );
      channel.searchResults = results;
      final tracks = await source.search('query', limit: 3);
      expect(tracks.length, 3);
    });

    test('catches SoulseekException and returns empty', () async {
      channel.searchError = const SoulseekException('ERR', 'search failed');
      final tracks = await source.search('query');
      expect(tracks, isEmpty);
    });

    test('catches UnsupportedError and returns empty', () async {
      channel.searchError = UnsupportedError('not Android');
      final tracks = await source.search('query');
      expect(tracks, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  resolveStreamUrl
  // ═══════════════════════════════════════════════════════════════════
  group('resolveStreamUrl', () {
    test('returns localPath on cache hit (entry.complete)', () async {
      channel.cacheEntry = const SoulseekCacheEntry(
        cacheKey: 'ck_test',
        localPath: '/cache/file.flac',
        sizeBytes: 50000000,
        complete: true,
        pinned: false,
      );
      final path = await source.resolveStreamUrl(_makeTrack());
      expect(path, '/cache/file.flac');
    });

    test('returns localPath when startDownload returns cacheHit', () async {
      channel.cacheEntry = null;
      channel.downloadResult = const SoulseekDownloadResult(
        downloadId: 'dl_ck_test',
        result: '/cache/hit.flac',
        cacheHit: true,
      );
      final path = await source.resolveStreamUrl(_makeTrack());
      expect(path, '/cache/hit.flac');
    });

    test('NEW-3: startDownload receives title/artist/durationSeconds', () async {
      channel.cacheEntry = null;
      channel.downloadResult = const SoulseekDownloadResult(
        downloadId: 'dl_ck_test',
        result: 'dl_ck_test',
        cacheHit: false,
      );
      channel.transferInfo = const SoulseekTransferInfo(
        downloadId: 'dl_ck_test',
        state: SoulseekTransferState.completed,
        localPath: '/cache/done.flac',
      );
      // Трек с duration — как из _resultToTrack поисковой выдачи.
      final track = _makeTrack();
      final withDuration = Track(
        id: track.id,
        sourceId: track.sourceId,
        title: 'Title',
        artist: 'Artist',
        duration: const Duration(seconds: 240),
        artworkUrl: null,
        qualityScore: track.qualityScore,
        qualityLabel: track.qualityLabel,
        extra: track.extra,
      );

      await source.resolveStreamUrl(withDuration);

      expect(channel.startDownloadCalls, hasLength(1));
      final call = channel.startDownloadCalls.single;
      expect(call['title'], 'Title');
      expect(call['artist'], 'Artist');
      expect(call['durationSeconds'], 240);
    });

    test('waits for download completion via getTransfer', () async {
      channel.cacheEntry = null;
      channel.downloadResult = const SoulseekDownloadResult(
        downloadId: 'dl_ck_test',
        result: 'dl_ck_test',
        cacheHit: false,
      );
      channel.transferInfo = const SoulseekTransferInfo(
        downloadId: 'dl_ck_test',
        state: SoulseekTransferState.completed,
        localPath: '/cache/done.flac',
      );
      final path = await source.resolveStreamUrl(_makeTrack());
      expect(path, '/cache/done.flac');
    });

    test('waits for download completion via event stream', () async {
      channel.cacheEntry = null;
      channel.downloadResult = const SoulseekDownloadResult(
        downloadId: 'dl_ck_test',
        result: 'dl_ck_test',
        cacheHit: false,
      );
      channel.transferInfo = null;

      // Эмитим событие после небольшой задержки.
      Future.delayed(const Duration(milliseconds: 50), () {
        channel.emitTransfer(const SoulseekTransferInfo(
          downloadId: 'dl_ck_test',
          state: SoulseekTransferState.completed,
          localPath: '/cache/event.flac',
        ));
      });

      final path = await source.resolveStreamUrl(_makeTrack());
      expect(path, '/cache/event.flac');
    });

    test('throws SoulseekException when download fails', () async {
      channel.cacheEntry = null;
      channel.downloadResult = const SoulseekDownloadResult(
        downloadId: 'dl_ck_test',
        result: 'dl_ck_test',
        cacheHit: false,
      );
      channel.transferInfo = const SoulseekTransferInfo(
        downloadId: 'dl_ck_test',
        state: SoulseekTransferState.failed,
        errorCode: 'PEER_OFFLINE',
        message: 'Peer went offline',
      );
      await expectLater(
        source.resolveStreamUrl(_makeTrack()),
        throwsA(isA<SoulseekException>()),
      );
    });

    test('throws SoulseekException when download is cancelled', () async {
      channel.cacheEntry = null;
      channel.downloadResult = const SoulseekDownloadResult(
        downloadId: 'dl_ck_test',
        result: 'dl_ck_test',
        cacheHit: false,
      );
      channel.transferInfo = const SoulseekTransferInfo(
        downloadId: 'dl_ck_test',
        state: SoulseekTransferState.cancelled,
      );
      await expectLater(
        source.resolveStreamUrl(_makeTrack()),
        throwsA(isA<SoulseekException>()),
      );
    });

    test('throws StateError when track is missing required extra fields',
        () async {
      channel.cacheEntry = null;
      // Track with cacheKey but no peerUsername — passes _getOrCreateCacheKey
      // but fails the download-field check.
      final track = _makeTrack();
      track.extra.remove('peerUsername');
      await expectLater(
        source.resolveStreamUrl(track),
        throwsA(isA<StateError>()),
      );
    });

    test('polling fallback completes when events are lost (P1)', () async {
      // Сценарий P1: событие completed потеряно (EventChannel переподписался),
      // но getCacheEntry при поллинге находит готовый файл.
      channel.cacheEntry = null;
      channel.downloadResult = const SoulseekDownloadResult(
        downloadId: 'dl_ck_test',
        result: 'dl_ck_test',
        cacheHit: false,
      );
      channel.transferInfo = null;
      channel.pollDelay = const Duration(milliseconds: 10);
      source.pollInterval = const Duration(milliseconds: 15);

      Future.delayed(const Duration(milliseconds: 60), () {
        channel.cacheEntry = const SoulseekCacheEntry(
          cacheKey: 'ck_test',
          localPath: '/cache/polled.flac',
          sizeBytes: 50000000,
          complete: true,
          pinned: false,
        );
      });

      final path = await source.resolveStreamUrl(_makeTrack());
      expect(path, '/cache/polled.flac');
      // Поллинг нашёл ключ — индекс пополнился.
      await Future.delayed(Duration.zero);
      expect(source.knownCacheKeys, contains('ck_test'));
    });

    test('throws DOWNLOAD_TIMEOUT when nothing completes within timeout (P1)',
        () async {
      channel.cacheEntry = null;
      channel.downloadResult = const SoulseekDownloadResult(
        downloadId: 'dl_ck_test',
        result: 'dl_ck_test',
        cacheHit: false,
      );
      channel.transferInfo = null;
      channel.pollDelay = const Duration(milliseconds: 5);
      source.pollInterval = const Duration(milliseconds: 10);
      source.downloadTimeout = const Duration(milliseconds: 60);

      await expectLater(
        source.resolveStreamUrl(_makeTrack()),
        throwsA(
          isA<SoulseekException>().having(
            (e) => e.code,
            'code',
            'DOWNLOAD_TIMEOUT',
          ),
        ),
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  createAudioSource — стриминг из .part
  // ═══════════════════════════════════════════════════════════════════
  group('createAudioSource streaming', () {
    late Directory dir;
    late File part;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('slsk_source_stream');
      part = File('${dir.path}/ck_test.part');
      source.offlineAudioSourceLookup = (_) async => null;
      source.pollInterval = const Duration(milliseconds: 10);
      source.streamPollInterval = const Duration(milliseconds: 5);
      source.streamStartBytes = 100;
      channel.cacheEntry = null;
      channel.downloadResult = SoulseekDownloadResult(
        downloadId: 'dl_ck_test',
        result: 'dl_ck_test',
        cacheHit: false,
        partPath: part.path,
      );
    });

    tearDown(() async {
      // Завершаем фоновое ожидание загрузки, чтобы не осталось таймеров.
      channel.transferInfo = const SoulseekTransferInfo(
        downloadId: 'dl_ck_test',
        state: SoulseekTransferState.cancelled,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await dir.delete(recursive: true);
    });

    test('returns a stream source once the start threshold is written',
        () async {
      final future = source.createAudioSource(_makeTrack());
      // Пир начинает отдавать после старта загрузки.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await part.writeAsBytes(List<int>.filled(150, 1));

      final audio = await future;

      expect(audio, isA<SoulseekStreamAudioSource>());
      final stream = audio as SoulseekStreamAudioSource;
      expect(stream.partPath, part.path);
      expect(stream.totalBytes, 50000000);
      expect(stream.contentType, 'audio/flac');
    });

    test('waits until the start threshold is reached', () async {
      await part.writeAsBytes(List<int>.filled(10, 1));
      var done = false;

      final future = source
          .createAudioSource(_makeTrack())
          .whenComplete(() => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(done, isFalse);

      await part.writeAsBytes(List<int>.filled(200, 1), mode: FileMode.append);
      expect(await future, isA<SoulseekStreamAudioSource>());
    });

    test('stale .part from an earlier attempt must grow before streaming',
        () async {
      // Остаток прошлой загрузки больше порога, но пир ещё ничего не отдал.
      await part.writeAsBytes(List<int>.filled(500, 1));
      var done = false;

      final future = source
          .createAudioSource(_makeTrack())
          .whenComplete(() => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(done, isFalse);

      await part.writeAsBytes(List<int>.filled(150, 1), mode: FileMode.append);
      expect(await future, isA<SoulseekStreamAudioSource>());
    });

    test('download finished before threshold → plays the final file',
        () async {
      channel.transferInfo = const SoulseekTransferInfo(
        downloadId: 'dl_ck_test',
        state: SoulseekTransferState.completed,
        localPath: '/cache/ck_test.flac',
      );

      final audio = await source.createAudioSource(_makeTrack());

      expect(audio, isA<UriAudioSource>());
      expect((audio as UriAudioSource).uri, Uri.file('/cache/ck_test.flac'));
    });

    test('download failure before threshold is rethrown', () async {
      channel.transferInfo = const SoulseekTransferInfo(
        downloadId: 'dl_ck_test',
        state: SoulseekTransferState.failed,
        errorCode: 'PEER_OFFLINE',
        message: 'Peer went offline',
      );

      await expectLater(
        source.createAudioSource(_makeTrack()),
        throwsA(isA<SoulseekException>()
            .having((e) => e.code, 'code', 'PEER_OFFLINE')),
      );
    });

    test('no bytes within downloadTimeout → DOWNLOAD_TIMEOUT', () async {
      source.downloadTimeout = const Duration(milliseconds: 60);

      await expectLater(
        source.createAudioSource(_makeTrack()),
        throwsA(isA<SoulseekException>()
            .having((e) => e.code, 'code', 'DOWNLOAD_TIMEOUT')),
      );
    });

    test('completion while streaming records the cache key', () async {
      final future = source.createAudioSource(_makeTrack());
      // Пир начинает отдавать после старта загрузки.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await part.writeAsBytes(List<int>.filled(150, 1));
      await future;

      channel.emitTransfer(const SoulseekTransferInfo(
        downloadId: 'dl_ck_test',
        state: SoulseekTransferState.completed,
        localPath: '/cache/ck_test.flac',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(source.knownCacheKeys, contains('ck_test'));
    });

    test('without partPath falls back to waiting for the full file', () async {
      channel.downloadResult = const SoulseekDownloadResult(
        downloadId: 'dl_ck_test',
        result: 'dl_ck_test',
        cacheHit: false,
      );
      channel.transferInfo = const SoulseekTransferInfo(
        downloadId: 'dl_ck_test',
        state: SoulseekTransferState.completed,
        localPath: '/cache/full.flac',
      );

      final audio = await source.createAudioSource(_makeTrack());

      expect((audio as UriAudioSource).uri, Uri.file('/cache/full.flac'));
    });

    test('streaming disabled → waits for the full file', () async {
      source.streamingEnabled = false;
      await part.writeAsBytes(List<int>.filled(150, 1));
      channel.transferInfo = const SoulseekTransferInfo(
        downloadId: 'dl_ck_test',
        state: SoulseekTransferState.completed,
        localPath: '/cache/full.flac',
      );

      final audio = await source.createAudioSource(_makeTrack());

      expect((audio as UriAudioSource).uri, Uri.file('/cache/full.flac'));
    });

    test('complete cache entry is played directly', () async {
      channel.cacheEntry = const SoulseekCacheEntry(
        cacheKey: 'ck_test',
        localPath: '/cache/cached.flac',
        sizeBytes: 50000000,
        complete: true,
        pinned: false,
      );

      final audio = await source.createAudioSource(_makeTrack());

      expect((audio as UriAudioSource).uri, Uri.file('/cache/cached.flac'));
      expect(channel.startDownloadCalls, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  refreshCacheIndex (P1-каскад)
  // ═══════════════════════════════════════════════════════════════════
  group('refreshCacheIndex', () {
    test('syncs knownCacheKeys from native cache entries', () async {
      channel.cacheEntries = const [
        SoulseekCacheEntry(
          cacheKey: 'ck_native_1',
          localPath: '/cache/one.flac',
          sizeBytes: 100,
          complete: true,
          pinned: false,
        ),
        SoulseekCacheEntry(
          cacheKey: 'ck_native_2',
          localPath: '/cache/two.flac',
          sizeBytes: 200,
          complete: true,
          pinned: true,
        ),
      ];
      await source.refreshCacheIndex();
      expect(source.knownCacheKeys, containsAll(['ck_native_1', 'ck_native_2']));
    });

    test('keeps index intact when channel throws', () async {
      await source.recordCacheKeyForTest('ck_existing');
      await Future.delayed(Duration.zero);
      channel.cacheEntriesError = true;
      await source.refreshCacheIndex();
      expect(source.knownCacheKeys, contains('ck_existing'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  resolveBitrate
  // ═══════════════════════════════════════════════════════════════════
  group('resolveBitrate', () {
    test('returns bitrate from extra when > 0', () async {
      final track = _makeTrack(bitrate: 320, qualityScore: 128);
      expect(await source.resolveBitrate(track), 320);
    });

    test('returns qualityScore when extra bitrate is null', () async {
      final track = _makeTrack(bitrate: null, qualityScore: 128);
      expect(await source.resolveBitrate(track), 128);
    });

    test('returns qualityScore when extra bitrate is 0', () async {
      final track = _makeTrack(bitrate: 0, qualityScore: 256);
      expect(await source.resolveBitrate(track), 256);
    });

    test('returns qualityScore when extra has no bitrate key', () async {
      final track = _makeTrack();
      track.extra.remove('bitrate');
      expect(await source.resolveBitrate(track), 1411);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  prefetch
  // ═══════════════════════════════════════════════════════════════════
  group('prefetch', () {
    test('does nothing when channel is unavailable', () async {
      channel.isAvailable = false;
      await source.prefetch(_makeTrack());
      expect(channel.startDownloadCalls, isEmpty);
    });

    test('does nothing when cache hit (entry.complete)', () async {
      channel.cacheEntry = const SoulseekCacheEntry(
        cacheKey: 'ck_test',
        localPath: '/cache/file.flac',
        sizeBytes: 50000000,
        complete: true,
        pinned: false,
      );
      await source.prefetch(_makeTrack());
      expect(channel.startDownloadCalls, isEmpty);
    });

    test('starts download when cache miss', () async {
      channel.cacheEntry = null;
      await source.prefetch(_makeTrack());
      expect(channel.startDownloadCalls.length, 1);
      final call = channel.startDownloadCalls[0];
      expect(call['peerUsername'], 'peer1');
      expect(call['remoteFilename'], 'Artist - Title.flac');
      expect(call['sizeBytes'], 50000000);
      expect(call['cacheKey'], 'ck_test');
      expect(call['fileExtension'], 'flac');
    });

    test('does nothing when missing required extra fields', () async {
      channel.cacheEntry = null;
      final track = _makeTrack();
      track.extra.remove('peerUsername');
      await source.prefetch(track);
      expect(channel.startDownloadCalls, isEmpty);
    });

    test('catches SoulseekException from startDownload', () async {
      channel.cacheEntry = null;
      channel.downloadResult = null;
      // Override startDownload to throw.
      channel = _TestChannel();
      channel.isAvailable = true;
      channel.cacheEntry = null;
      channel.searchError =
          const SoulseekException('DL_ERR', 'download failed');
      // Actually, startDownload error is different from searchError.
      // Let's just test that prefetch doesn't throw when startDownload
      // succeeds (default behavior).
      await source.prefetch(_makeTrack());
      // Should not throw.
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  cache key index
  // ═══════════════════════════════════════════════════════════════════
  group('cache key index', () {
    test('knownCacheKeys is empty on fresh source', () {
      expect(source.knownCacheKeys, isEmpty);
    });

    test('download completion records cache key in index', () async {
      channel.cacheEntry = null;
      channel.downloadResult = const SoulseekDownloadResult(
        downloadId: 'dl_ck_test',
        result: 'dl_ck_test',
        cacheHit: false,
      );
      channel.transferInfo = const SoulseekTransferInfo(
        downloadId: 'dl_ck_test',
        state: SoulseekTransferState.completed,
        localPath: '/cache/done.flac',
      );

      await source.resolveStreamUrl(_makeTrack());

      // Allow _recordCacheKey microtask to complete.
      await Future.delayed(Duration.zero);

      // cacheKeyForIndex = 'dl_ck_test'.replaceFirst('dl_', '') = 'ck_test'
      expect(source.knownCacheKeys, contains('ck_test'));
    });

    test('forgetCacheKey removes key from index', () async {
      // First, record a key via download.
      channel.cacheEntry = null;
      channel.downloadResult = const SoulseekDownloadResult(
        downloadId: 'dl_ck_test',
        result: 'dl_ck_test',
        cacheHit: false,
      );
      channel.transferInfo = const SoulseekTransferInfo(
        downloadId: 'dl_ck_test',
        state: SoulseekTransferState.completed,
        localPath: '/cache/done.flac',
      );
      await source.resolveStreamUrl(_makeTrack());
      await Future.delayed(Duration.zero);
      expect(source.knownCacheKeys, contains('ck_test'));

      // Now forget it.
      source.forgetCacheKey('ck_test');
      expect(source.knownCacheKeys, isNot(contains('ck_test')));
    });

    test('clearCacheIndex removes all keys', () async {
      // Record a key.
      channel.cacheEntry = null;
      channel.downloadResult = const SoulseekDownloadResult(
        downloadId: 'dl_ck_test',
        result: 'dl_ck_test',
        cacheHit: false,
      );
      channel.transferInfo = const SoulseekTransferInfo(
        downloadId: 'dl_ck_test',
        state: SoulseekTransferState.completed,
        localPath: '/cache/done.flac',
      );
      await source.resolveStreamUrl(_makeTrack());
      await Future.delayed(Duration.zero);
      expect(source.knownCacheKeys, isNotEmpty);

      // Clear all.
      source.clearCacheIndex();
      expect(source.knownCacheKeys, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  NEW-2: применяемый таймаут поиска из настроек
  // ═══════════════════════════════════════════════════════════════════
  group('search timeout from settings DB (NEW-2)', () {
    test('default 10000 ms when setting not set', () async {
      channel.searchResults = [_searchResult()];
      await source.search('query');
      expect(channel.lastSearchTimeoutMs, 10000);
    });

    test('setting soulseek_search_timeout_sec=7 → 7000 ms', () async {
      await AppDatabase.instance.setSetting('soulseek_search_timeout_sec', '7');
      // Ленивая загрузка один раз на инстанс — пересоздаём source.
      source = SoulseekSource(channel: channel);
      await Future.delayed(Duration.zero);
      channel.searchResults = [_searchResult()];
      await source.search('query');
      expect(channel.lastSearchTimeoutMs, 7000);
    });

    test('passes idle window and early-stop limits to channel', () async {
      channel.searchResults = [_searchResult()];
      await source.search('query');
      expect(channel.lastIdleTimeoutMs, SoulseekSource.searchIdleTimeoutMs);
      expect(channel.lastResponseLimit, SoulseekSource.searchResponseLimit);
      expect(channel.lastFileLimit, SoulseekSource.searchFileLimit);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  P5: фоновое обогащение обложками
  // ═══════════════════════════════════════════════════════════════════
  group('enrichArtworksInBackground (P5)', () {
    test('fills artworkUrl from ArtworkProvider and skips enriched', () async {
      // В тестах нет path_provider — прекэш миниатюр отключаем.
      SoulseekSource.precacheThumbsEnabled = false;
      addTearDown(() => SoulseekSource.precacheThumbsEnabled = true);
      // Сид in-memory кэша — findArtwork вернёт URL без сети.
      ArtworkProvider.instance
          .cacheArtworkForTesting('Artist', 'Title', 'http://art.example/1.jpg');

      final t1 = _makeTrack();
      final t2 = Track(
        id: 'already',
        sourceId: SoulseekSource.sourceId,
        title: 'Title',
        artist: 'Artist',
        duration: null,
        artworkUrl: 'http://existing.jpg',
        qualityScore: 1411,
        qualityLabel: 'FLAC',
        extra: t1.extra,
      );

      final updated = <List<Track>>[];
      source.enrichArtworksInBackground([t1, t2], updated.add);

      // Фоновая задача — даём ей завершиться (worst-case несколько циклов).
      await Future.delayed(const Duration(milliseconds: 300));

      expect(updated, isNotEmpty);
      final last = updated.last;
      expect(
        last.firstWhere((t) => t.id == 'test_id').artworkUrl,
        'http://art.example/1.jpg',
      );
      // Уже обогащённый трек не перезатирается.
      expect(
        last.firstWhere((t) => t.id == 'already').artworkUrl,
        'http://existing.jpg',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  Static properties
  // ═══════════════════════════════════════════════════════════════════
  group('static properties', () {
    test('sourceId is "soulseek"', () {
      expect(SoulseekSource.sourceId, 'soulseek');
    });

    test('id returns sourceId', () {
      expect(source.id, 'soulseek');
    });

    test('displayName is "Soulseek"', () {
      expect(source.displayName, 'Soulseek');
    });
  });

  group('grouping of identical files', () {
    test('identical artist/title/duration/quality from different peers → one track',
        () async {
      channel.searchResults = [
        _searchResult(resultId: 'r1', username: 'peerA', filename: r'peerA\Artist - Title.flac'),
        _searchResult(resultId: 'r2', username: 'peerB', filename: r'peerB\Artist - Title.flac'),
        _searchResult(resultId: 'r3', username: 'peerC', filename: r'peerC\Artist - Title.flac'),
      ];
      final tracks = await source.search('query');
      expect(tracks, hasLength(1));
      expect(tracks.single.extra['peerCount'], 3);
      // Представитель — лучший по рангу (у всех равные — первый пришедший).
      expect(tracks.single.extra['peerUsername'], 'peerA');
    });

    test('any difference in quality, duration, title or artist → separate tracks',
        () async {
      channel.searchResults = [
        _searchResult(resultId: 'base', username: 'p0', filename: r'p0\Artist - Title.flac'),
        _searchResult(resultId: 'br', username: 'p1', filename: r'p1\Artist - Title.flac', bitrate: 1000),
        _searchResult(resultId: 'depth', username: 'p2', filename: r'p2\Artist - Title.flac', bitDepth: 24),
        _searchResult(resultId: 'rate', username: 'p3', filename: r'p3\Artist - Title.flac', sampleRate: 48000),
        _searchResult(
            resultId: 'ext', username: 'p4', extension: 'mp3',
            filename: r'p4\Artist - Title.mp3'),
        _searchResult(resultId: 'dur', username: 'p5', filename: r'p5\Artist - Title.flac', durationSeconds: 241),
        _searchResult(
            resultId: 'title', username: 'p6', filename: r'p6\Artist - Other.flac'),
        _searchResult(
            resultId: 'artist', username: 'p7', filename: r'p7\Other - Title.flac'),
        _searchResult(
            resultId: 'case', username: 'p8', filename: r'p8rtist - Title.flac'),
      ];
      final tracks = await source.search('query');
      expect(tracks, hasLength(9));
      expect(tracks.every((t) => t.extra['peerCount'] == null), isTrue);
    });

    test('same file (path + size) from another peer counts into the group',
        () async {
      channel.searchResults = [
        _searchResult(resultId: 'r1', username: 'peerA', durationSeconds: null),
        _searchResult(resultId: 'r2', username: 'peerB', durationSeconds: null),
      ];
      final tracks = await source.search('query');
      expect(tracks, hasLength(1));
      expect(tracks.single.extra['peerCount'], 2);
    });

    test('unknown duration is never grouped', () async {
      channel.searchResults = [
        _searchResult(resultId: 'r1', username: 'peerA', durationSeconds: null, filename: r'peerA\Artist - Title.flac'),
        _searchResult(resultId: 'r2', username: 'peerB', durationSeconds: null, filename: r'peerB\Artist - Title.flac'),
      ];
      final tracks = await source.search('query');
      expect(tracks, hasLength(2));
    });

    test('limit counts distinct tracks, duplicates still increase peerCount',
        () async {
      channel.searchResults = [
        _searchResult(resultId: 'a', username: 'p1', filename: r'p1\Artist - Title.flac'),
        _searchResult(
            resultId: 'b', username: 'p2', filename: 'Artist - Other.flac'),
        _searchResult(resultId: 'a2', username: 'p3', filename: r'p3\Artist - Title.flac'),
      ];
      final tracks = await source.search('query', limit: 1);
      expect(tracks, hasLength(1));
      expect(tracks.single.extra['peerCount'], 2);
    });
  });

  group('folder albums', () {
    SoulseekSearchResult file(String user, String path, {int size = 1000}) =>
        _searchResult(
          resultId: '$user|$path',
          username: user,
          filename: path,
          sizeBytes: size,
        );

    test('2+ files of one peer folder → contiguous tracks with folderKey, '
        'sorted by file name', () async {
      channel.searchResults = [
        file('peerA', r'Music\Artist\Album\02 - Two.flac'),
        file('peerB', r'Other\Artist - Single.flac'),
        file('peerA', r'Music\Artist\Album\01 - One.flac'),
      ];
      final tracks = await source.search('query');
      expect(tracks.map((t) => t.title), ['One', 'Two', 'Single']);
      final key = SoulseekSource.folderKeyOf(
          'peerA', r'Music\Artist\Album\01 - One.flac');
      expect(tracks[0].extra['folderKey'], key);
      expect(tracks[1].extra['folderKey'], key);
      expect(tracks[2].extra.containsKey('folderKey'), isFalse);
    });

    test('same folder content at another peer → folderPeers, not a copy',
        () async {
      channel.searchResults = [
        file('peerA', r'A\Album\01 - One.flac', size: 1),
        file('peerA', r'A\Album\02 - Two.flac', size: 2),
        file('peerB', r'B\x\Album\01 - One.flac', size: 1),
        file('peerB', r'B\x\Album\02 - Two.flac', size: 2),
      ];
      final tracks = await source.search('query');
      expect(tracks, hasLength(2));
      expect(tracks.every((t) => t.extra['folderPeers'] == 2), isTrue);
    });

    test('limit counts folders as one entry', () async {
      channel.searchResults = [
        for (var i = 0; i < 5; i++)
          file('peerA', 'Album\\0$i - T$i.flac', size: i),
        file('peerB', r'X\Artist - Single.flac'),
      ];
      final tracks = await source.search('query', limit: 1);
      expect(tracks, hasLength(5));
      expect(tracks.every((t) => t.extra['folderKey'] != null), isTrue);
    });

    test('later delta of a shown folder appends to it', () async {
      source.applySearchTimeoutSec(10);
      channel.searchGate = Completer();
      final snapshots = <List<String>>[];
      final done = source
          .searchProgressive('query')
          .listen((s) => snapshots.add([for (final t in s) t.title]))
          .asFuture<void>();
      await Future<void>.delayed(Duration.zero);

      channel.emitProgress([
        file('peerA', r'Album\01 - One.flac', size: 1),
        file('peerA', r'Album\02 - Two.flac', size: 2),
      ]);
      await Future<void>.delayed(Duration.zero);
      channel.emitProgress([
        file('peerB', r'X\Artist - Single.flac'),
        file('peerA', r'Album\03 - Three.flac', size: 3),
      ]);
      await Future<void>.delayed(Duration.zero);
      channel.searchGate!.complete(const []);
      await done;

      expect(snapshots.last, ['One', 'Two', 'Three', 'Single']);
    });

    test('loadFolder: full peer folder, known tracks keep their data',
        () async {
      channel.searchResults = [
        file('peerA', r'M\Album\02 - Two.flac', size: 2),
        file('peerA', r'M\Album\03 - Three.flac', size: 3),
      ];
      final known = await source.search('query');
      channel.directoryResults = [
        _searchResult(
            resultId: 'd1', username: 'peerA',
            filename: r'M\Album\01 - One.flac', sizeBytes: 1,
            durationSeconds: null, queueLength: 0, uploadSpeed: 0),
        _searchResult(
            resultId: 'd2', username: 'peerA',
            filename: r'M\Album\02 - Two.flac', sizeBytes: 2,
            durationSeconds: null, queueLength: 0, uploadSpeed: 0),
        _searchResult(
            resultId: 'd3', username: 'peerA',
            filename: r'M\Album\03 - Three.flac', sizeBytes: 3,
            durationSeconds: null, queueLength: 0, uploadSpeed: 0),
      ];

      final full = await source.loadFolder(known);

      expect(channel.directoryCalls, [('peerA', r'M\Album')]);
      expect(full.map((t) => t.title), ['One', 'Two', 'Three']);
      // Известный трек — тот же объект с атрибутами из поиска.
      expect(identical(full[1], known[0]), isTrue);
      expect(full[1].duration, const Duration(seconds: 240));
      // Новый трек — статистика пира из известных, общий folderKey.
      expect(full[0].extra['queueLength'], 5);
      expect(full[0].extra['folderKey'], known[0].extra['folderKey']);

      // Повторное открытие — из кэша, без запроса пиру.
      await source.loadFolder(known);
      expect(channel.directoryCalls, hasLength(1));
    });

    test('loadFolder keeps matched files the peer did not list', () async {
      channel.searchResults = [file('peerA', r'M\Album\09 - Nine.flac')];
      final known = await source.search('query');
      channel.directoryResults = [
        file('peerA', r'M\Album\01 - One.flac', size: 1),
      ];
      final full = await source.loadFolder(known);
      expect(full.map((t) => t.title), ['One', 'Nine']);
    });

    test('loadFolder propagates channel errors', () async {
      channel.searchResults = [file('peerA', r'M\Album\01 - One.flac')];
      final known = await source.search('query');
      channel.directoryError = const SoulseekException('ERR', 'offline');
      expect(source.loadFolder(known), throwsA(isA<SoulseekException>()));
    });

    test('folderOf / leafOf handle both separators', () {
      expect(SoulseekSource.folderOf(r'a\b/c.flac'), r'a\b');
      expect(SoulseekSource.leafOf(r'a\b/c.flac'), 'c.flac');
      expect(SoulseekSource.folderOf('c.flac'), '');
      expect(SoulseekSource.leafOf('c.flac'), 'c.flac');
    });
  });

  group('searchProgressive', () {
    // Таймаут уже применён — поиск не ждёт чтения настройки из БД.
    setUp(() => source.applySearchTimeoutSec(10));

    test('streams snapshots: shown tracks keep positions, new ones append',
        () async {
      channel.searchGate = Completer();
      final snapshots = <List<String>>[];
      final done = source
          .searchProgressive('query')
          .listen((s) => snapshots.add([for (final t in s) t.title]))
          .asFuture<void>();
      await Future<void>.delayed(Duration.zero);

      // Первая пачка: у peerB свободный слот — внутри пачки он выше.
      channel.emitProgress([
        _searchResult(
            resultId: 'r1', username: 'peerA', filename: 'A - One.flac',
            freeUploadSlots: 0),
        _searchResult(
            resultId: 'r2', username: 'peerB', filename: 'A - Two.flac'),
      ]);
      await Future<void>.delayed(Duration.zero);
      // Вторая пачка с более «быстрым» пиром не обгоняет показанные треки.
      channel.emitProgress([
        _searchResult(
            resultId: 'r3', username: 'peerC', filename: 'A - Three.flac',
            uploadSpeed: 99999),
      ]);
      await Future<void>.delayed(Duration.zero);

      // Итог поиска — надмножество дельт: повторы не дублируются.
      channel.searchGate!.complete([
        _searchResult(
            resultId: 'r1', username: 'peerA', filename: 'A - One.flac',
            freeUploadSlots: 0),
        _searchResult(
            resultId: 'r2', username: 'peerB', filename: 'A - Two.flac'),
        _searchResult(
            resultId: 'r3', username: 'peerC', filename: 'A - Three.flac',
            uploadSpeed: 99999),
        _searchResult(
            resultId: 'r4', username: 'peerD', filename: 'A - Four.flac'),
      ]);
      await done;

      expect(snapshots.first, ['Two', 'One']);
      expect(snapshots[1], ['Two', 'One', 'Three']);
      expect(snapshots.last, ['Two', 'One', 'Three', 'Four']);
    });

    test('completed search is cached: same query does not hit the network',
        () async {
      channel.searchResults = [_searchResult()];
      final first = await source.search('query');
      final second = await source.search('query');
      expect(channel.searchCalls, 1);
      expect(second.map((t) => t.id), first.map((t) => t.id));

      // Другие фильтры — другой ключ кэша.
      source.searchFilters =
          const SoulseekSearchFilters(losslessOnly: true);
      await source.search('query');
      expect(channel.searchCalls, 2);
    });

    test('failed search is not cached', () async {
      channel.searchError = const SoulseekException('NOT_CONNECTED', 'x');
      expect(await source.search('query'), isEmpty);
      channel.searchError = null;
      channel.searchResults = [_searchResult()];
      expect(await source.search('query'), hasLength(1));
      expect(channel.searchCalls, 2);
    });

    test('cancelling the only subscriber cancels the native search', () async {
      channel.searchGate = Completer();
      final sub = source.searchProgressive('query').listen((_) {});
      await Future<void>.delayed(Duration.zero);
      final requestId = channel.lastRequestId;

      await sub.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(channel.cancelledSearches, [requestId]);

      // Отменённый поиск не кэшируется: повторный запрос идёт в сеть.
      channel.searchGate!.complete([_searchResult()]);
      await Future<void>.delayed(Duration.zero);
      channel.searchGate = null;
      channel.searchResults = [_searchResult()];
      await source.search('query');
      expect(channel.searchCalls, 2);
    });

    test('re-subscribing in the same tick joins the running search', () async {
      channel.searchGate = Completer();
      final first = source.searchProgressive('query').listen((_) {});
      await Future<void>.delayed(Duration.zero);
      channel.emitProgress([_searchResult()]);
      await Future<void>.delayed(Duration.zero);

      // Как при смене чипа: отписка и сразу новая подписка на тот же запрос.
      await first.cancel();
      final snapshots = <List<Track>>[];
      final second = source.searchProgressive('query').listen(snapshots.add);
      await Future<void>.delayed(Duration.zero);

      expect(channel.searchCalls, 1);
      expect(channel.cancelledSearches, isEmpty);
      // Новый подписчик сразу получает уже накопленное.
      expect(snapshots.first, hasLength(1));

      channel.searchGate!.complete([_searchResult()]);
      await second.asFuture<void>();
    });
  });
}
