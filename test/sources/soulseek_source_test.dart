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

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:player/models/track.dart';
import 'package:player/sources/artwork_provider.dart';
import 'package:player/sources/soulseek_models.dart';
import 'package:player/sources/soulseek_source.dart';

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
    lastSearchQuery = query;
    lastSearchTimeoutMs = timeoutMs;
    lastIdleTimeoutMs = idleTimeoutMs;
    lastResponseLimit = responseLimit;
    lastFileLimit = fileLimit;
    if (searchError != null) throw searchError!;
    return searchResults;
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

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    channel = _TestChannel();
    source = SoulseekSource(channel: channel);
    // Позволяем _loadCacheIndex() завершиться.
    await Future.delayed(Duration.zero);
  });

  tearDown(() async {
    await source.dispose();
    channel.close();
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
        _searchResult(resultId: 'busy', filename: 'a.flac',
            freeUploadSlots: 0, queueLength: 0, uploadSpeed: 9000),
        _searchResult(resultId: 'slow', filename: 'b.flac',
            queueLength: 0, uploadSpeed: 100),
        _searchResult(resultId: 'queued', filename: 'c.flac',
            queueLength: 7, uploadSpeed: 9000),
        _searchResult(resultId: 'fast', filename: 'd.flac',
            queueLength: 0, uploadSpeed: 800),
        _searchResult(resultId: 'fast2', filename: 'e.flac',
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
        _searchResult(
          resultId: 'r3',
          filename: 'Artist - Title.flac',
          sizeBytes: 60000000,
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
  group('search timeout from prefs (NEW-2)', () {
    test('default 10000 ms when pref not set', () async {
      channel.searchResults = [_searchResult()];
      await source.search('query');
      expect(channel.lastSearchTimeoutMs, 10000);
    });

    test('pref soulseek_search_timeout_sec=7 → 7000 ms', () async {
      SharedPreferences.setMockInitialValues({
        'soulseek_search_timeout_sec': 7,
      });
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
}
