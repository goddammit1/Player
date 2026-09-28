// test/sources/soulseek_source_filters_test.dart
//
// Фаза 4 (Part E) — unit-тесты для SoulseekSearchFilters.matches().
//
// Покрывает:
// - Пустые фильтры пропускают всё
// - Фильтр по расширениям (extensions)
// - losslessOnly
// - minSizeBytes / maxSizeBytes
// - minBitrate (включая null bitrate → отклонение)
// - minPeerUploadSpeed
// - maxPeerQueueLength
// - Комбинированные фильтры

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/soulseek_models.dart';

/// Создаёт [SoulseekSearchResult] с заданными значениями для тестов фильтров.
SoulseekSearchResult _result({
  String extension = 'mp3',
  int sizeBytes = 10000000,
  int? bitrate = 320,
  int? sampleRate,
  int? bitDepth,
  int? durationSeconds,
  int queueLength = 0,
  int freeUploadSlots = 1,
  int uploadSpeed = 100,
}) {
  return SoulseekSearchResult(
    resultId: 'test',
    username: 'peer',
    filename: 'Artist - Title.$extension',
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

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  Пустые фильтры
  // ═══════════════════════════════════════════════════════════════════
  group('empty filters', () {
    test('match any result', () {
      final r = _result(extension: 'flac', sizeBytes: 999999999);
      expect(SoulseekSearchFilters.empty.matches(r), isTrue);
    });

    test('match result with null bitrate', () {
      final r = _result(bitrate: null);
      expect(SoulseekSearchFilters.empty.matches(r), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  extensions
  // ═══════════════════════════════════════════════════════════════════
  group('extensions filter', () {
    test('matches when extension is in list', () {
      const filters = SoulseekSearchFilters(extensions: ['flac', 'mp3']);
      expect(filters.matches(_result(extension: 'flac')), isTrue);
      expect(filters.matches(_result(extension: 'mp3')), isTrue);
    });

    test('rejects when extension is NOT in list', () {
      const filters = SoulseekSearchFilters(extensions: ['flac']);
      expect(filters.matches(_result(extension: 'mp3')), isFalse);
      expect(filters.matches(_result(extension: 'aac')), isFalse);
    });

    test('case-insensitive extension matching', () {
      const filters = SoulseekSearchFilters(extensions: ['FLAC']);
      expect(filters.matches(_result(extension: 'flac')), isTrue);
    });

    test('empty extensions list is ignored (matches all)', () {
      const filters = SoulseekSearchFilters(extensions: []);
      expect(filters.matches(_result(extension: 'mp3')), isTrue);
      expect(filters.matches(_result(extension: 'flac')), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  losslessOnly
  // ═══════════════════════════════════════════════════════════════════
  group('losslessOnly filter', () {
    test('matches lossless extensions', () {
      const filters = SoulseekSearchFilters(losslessOnly: true);
      for (final ext in SoulseekSearchFilters.losslessExtensions) {
        expect(
          filters.matches(_result(extension: ext)),
          isTrue,
          reason: 'losslessOnly should match .$ext',
        );
      }
    });

    test('rejects lossy extensions', () {
      const filters = SoulseekSearchFilters(losslessOnly: true);
      expect(filters.matches(_result(extension: 'mp3')), isFalse);
      expect(filters.matches(_result(extension: 'aac')), isFalse);
      expect(filters.matches(_result(extension: 'ogg')), isFalse);
      expect(filters.matches(_result(extension: 'opus')), isFalse);
    });

    test('case-insensitive', () {
      const filters = SoulseekSearchFilters(losslessOnly: true);
      expect(filters.matches(_result(extension: 'FLAC')), isTrue);
      expect(filters.matches(_result(extension: 'WAV')), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  minSizeBytes / maxSizeBytes
  // ═══════════════════════════════════════════════════════════════════
  group('size filters', () {
    test('minSizeBytes rejects smaller files', () {
      const filters = SoulseekSearchFilters(minSizeBytes: 5000000);
      expect(filters.matches(_result(sizeBytes: 5000000)), isTrue);
      expect(filters.matches(_result(sizeBytes: 4999999)), isFalse);
    });

    test('maxSizeBytes rejects larger files', () {
      const filters = SoulseekSearchFilters(maxSizeBytes: 100000000);
      expect(filters.matches(_result(sizeBytes: 100000000)), isTrue);
      expect(filters.matches(_result(sizeBytes: 100000001)), isFalse);
    });

    test('both min and max define a range', () {
      const filters = SoulseekSearchFilters(
        minSizeBytes: 1000000,
        maxSizeBytes: 50000000,
      );
      expect(filters.matches(_result(sizeBytes: 500000)), isFalse);
      expect(filters.matches(_result(sizeBytes: 1000000)), isTrue);
      expect(filters.matches(_result(sizeBytes: 25000000)), isTrue);
      expect(filters.matches(_result(sizeBytes: 50000000)), isTrue);
      expect(filters.matches(_result(sizeBytes: 50000001)), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  minBitrate
  // ═══════════════════════════════════════════════════════════════════
  group('minBitrate filter', () {
    test('matches when bitrate >= minBitrate', () {
      const filters = SoulseekSearchFilters(minBitrate: 320);
      expect(filters.matches(_result(bitrate: 320)), isTrue);
      expect(filters.matches(_result(bitrate: 500)), isTrue);
    });

    test('rejects when bitrate < minBitrate', () {
      const filters = SoulseekSearchFilters(minBitrate: 320);
      expect(filters.matches(_result(bitrate: 128)), isFalse);
      expect(filters.matches(_result(bitrate: 319)), isFalse);
    });

    test('rejects when bitrate is null', () {
      const filters = SoulseekSearchFilters(minBitrate: 320);
      expect(filters.matches(_result(bitrate: null)), isFalse);
    });

    test('minBitrate=0 is treated as no filter (null in practice)', () {
      // minBitrate != null && result.bitrate == null → false
      const filters = SoulseekSearchFilters(minBitrate: 0);
      expect(filters.matches(_result(bitrate: 0)), isTrue);
      expect(filters.matches(_result(bitrate: null)), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  minPeerUploadSpeed
  // ═══════════════════════════════════════════════════════════════════
  group('minPeerUploadSpeed filter', () {
    test('matches when uploadSpeed >= min', () {
      const filters = SoulseekSearchFilters(minPeerUploadSpeed: 100);
      expect(filters.matches(_result(uploadSpeed: 100)), isTrue);
      expect(filters.matches(_result(uploadSpeed: 200)), isTrue);
    });

    test('rejects when uploadSpeed < min', () {
      const filters = SoulseekSearchFilters(minPeerUploadSpeed: 100);
      expect(filters.matches(_result(uploadSpeed: 50)), isFalse);
      expect(filters.matches(_result(uploadSpeed: 99)), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  maxPeerQueueLength
  // ═══════════════════════════════════════════════════════════════════
  group('maxPeerQueueLength filter', () {
    test('matches when queueLength <= max', () {
      const filters = SoulseekSearchFilters(maxPeerQueueLength: 10);
      expect(filters.matches(_result(queueLength: 0)), isTrue);
      expect(filters.matches(_result(queueLength: 10)), isTrue);
    });

    test('rejects when queueLength > max', () {
      const filters = SoulseekSearchFilters(maxPeerQueueLength: 10);
      expect(filters.matches(_result(queueLength: 11)), isFalse);
      expect(filters.matches(_result(queueLength: 100)), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  Комбинированные фильтры
  // ═══════════════════════════════════════════════════════════════════
  group('combined filters', () {
    const filters = SoulseekSearchFilters(
      extensions: ['flac', 'mp3'],
      losslessOnly: false,
      minSizeBytes: 1000000,
      maxSizeBytes: 100000000,
      minBitrate: 256,
      minPeerUploadSpeed: 50,
      maxPeerQueueLength: 20,
    );

    test('matches result satisfying all criteria', () {
      final r = _result(
        extension: 'flac',
        sizeBytes: 50000000,
        bitrate: 1411,
        uploadSpeed: 100,
        queueLength: 5,
      );
      expect(filters.matches(r), isTrue);
    });

    test('rejects on wrong extension even if rest matches', () {
      final r = _result(
        extension: 'aac',
        sizeBytes: 50000000,
        bitrate: 320,
        uploadSpeed: 100,
        queueLength: 5,
      );
      expect(filters.matches(r), isFalse);
    });

    test('rejects on too small size', () {
      final r = _result(
        extension: 'mp3',
        sizeBytes: 500000,
        bitrate: 320,
        uploadSpeed: 100,
        queueLength: 5,
      );
      expect(filters.matches(r), isFalse);
    });

    test('rejects on too large size', () {
      final r = _result(
        extension: 'mp3',
        sizeBytes: 200000000,
        bitrate: 320,
        uploadSpeed: 100,
        queueLength: 5,
      );
      expect(filters.matches(r), isFalse);
    });

    test('rejects on low bitrate', () {
      final r = _result(
        extension: 'mp3',
        sizeBytes: 50000000,
        bitrate: 128,
        uploadSpeed: 100,
        queueLength: 5,
      );
      expect(filters.matches(r), isFalse);
    });

    test('rejects on null bitrate', () {
      final r = _result(
        extension: 'mp3',
        sizeBytes: 50000000,
        bitrate: null,
        uploadSpeed: 100,
        queueLength: 5,
      );
      expect(filters.matches(r), isFalse);
    });

    test('rejects on low upload speed', () {
      final r = _result(
        extension: 'mp3',
        sizeBytes: 50000000,
        bitrate: 320,
        uploadSpeed: 10,
        queueLength: 5,
      );
      expect(filters.matches(r), isFalse);
    });

    test('rejects on queue too long', () {
      final r = _result(
        extension: 'mp3',
        sizeBytes: 50000000,
        bitrate: 320,
        uploadSpeed: 100,
        queueLength: 50,
      );
      expect(filters.matches(r), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  losslessOnly + extensions комбинация
  // ═══════════════════════════════════════════════════════════════════
  group('losslessOnly + extensions', () {
    test('extensions restricts further within lossless', () {
      const filters = SoulseekSearchFilters(
        losslessOnly: true,
        extensions: ['flac'],
      );
      expect(filters.matches(_result(extension: 'flac')), isTrue);
      // wav is lossless but not in extensions
      expect(filters.matches(_result(extension: 'wav')), isFalse);
      expect(filters.matches(_result(extension: 'mp3')), isFalse);
    });
  });
}
