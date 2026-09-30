// test/sources/soulseek_models_test.dart
//
// Фаза 4 (Part E) — unit-тесты для Dart-моделей Soulseek.
//
// Покрывает:
// - SoulseekTransferState.fromString (case-insensitive + fallbacks)
// - SoulseekConnectionState.fromString (case-insensitive + fallbacks)
// - isTerminal / isActive геттеры
// - SoulseekSearchResult.fromMap
// - SoulseekTransferInfo.fromMap / progress / toMap
// - SoulseekCacheEntry.fromMap
// - SoulseekDownloadResult.fromMap
// - SoulseekConnectionInfo.fromMap
// - SoulseekEvent.fromMap / fromJsonString (sealed-иерархия)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/soulseek_models.dart';

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  SoulseekTransferState
  // ═══════════════════════════════════════════════════════════════════
  group('SoulseekTransferState', () {
    group('fromString — direct match (case-insensitive)', () {
      for (final state in SoulseekTransferState.values) {
        test('"${state.name}" → $state', () {
          expect(SoulseekTransferState.fromString(state.name), state);
        });
        test('"${state.name.toUpperCase()}" → $state', () {
          expect(
            SoulseekTransferState.fromString(state.name.toUpperCase()),
            state,
          );
        });
      }
    });

    test('null → idle', () {
      expect(SoulseekTransferState.fromString(null), SoulseekTransferState.idle);
    });

    test('empty → idle', () {
      expect(SoulseekTransferState.fromString(''), SoulseekTransferState.idle);
    });

    group('fromString — C# fallbacks', () {
      test('SUCCEEDED → completed', () {
        expect(
          SoulseekTransferState.fromString('SUCCEEDED'),
          SoulseekTransferState.completed,
        );
      });

      test('CANCELLED → cancelled', () {
        expect(
          SoulseekTransferState.fromString('CANCELLED'),
          SoulseekTransferState.cancelled,
        );
      });

      test('ABORTED → cancelled', () {
        expect(
          SoulseekTransferState.fromString('ABORTED'),
          SoulseekTransferState.cancelled,
        );
      });

      test('TIMEDOUT → failed', () {
        expect(
          SoulseekTransferState.fromString('TIMEDOUT'),
          SoulseekTransferState.failed,
        );
      });

      test('ERRORED → failed', () {
        expect(
          SoulseekTransferState.fromString('ERRORED'),
          SoulseekTransferState.failed,
        );
      });

      test('REJECTED → failed', () {
        expect(
          SoulseekTransferState.fromString('REJECTED'),
          SoulseekTransferState.failed,
        );
      });

      test('TRANSFERRING → downloading', () {
        expect(
          SoulseekTransferState.fromString('TRANSFERRING'),
          SoulseekTransferState.downloading,
        );
      });

      test('NEGOTIATING → connecting', () {
        expect(
          SoulseekTransferState.fromString('NEGOTIATING'),
          SoulseekTransferState.connecting,
        );
      });

      test('INITIALIZING → connecting', () {
        expect(
          SoulseekTransferState.fromString('INITIALIZING'),
          SoulseekTransferState.connecting,
        );
      });

      test('INITIALIZED → connecting', () {
        expect(
          SoulseekTransferState.fromString('INITIALIZED'),
          SoulseekTransferState.connecting,
        );
      });

      test('REQUESTED → queued', () {
        expect(
          SoulseekTransferState.fromString('REQUESTED'),
          SoulseekTransferState.queued,
        );
      });
    });

    test('unknown string → idle', () {
      expect(
        SoulseekTransferState.fromString('SOME_WEIRD_STATE'),
        SoulseekTransferState.idle,
      );
    });

    group('isTerminal', () {
      test('completed is terminal', () {
        expect(SoulseekTransferState.completed.isTerminal, isTrue);
      });
      test('failed is terminal', () {
        expect(SoulseekTransferState.failed.isTerminal, isTrue);
      });
      test('cancelled is terminal', () {
        expect(SoulseekTransferState.cancelled.isTerminal, isTrue);
      });
      test('downloading is NOT terminal', () {
        expect(SoulseekTransferState.downloading.isTerminal, isFalse);
      });
      test('queued is NOT terminal', () {
        expect(SoulseekTransferState.queued.isTerminal, isFalse);
      });
      test('idle is NOT terminal', () {
        expect(SoulseekTransferState.idle.isTerminal, isFalse);
      });
    });

    group('isActive', () {
      test('queued is active', () {
        expect(SoulseekTransferState.queued.isActive, isTrue);
      });
      test('downloading is active', () {
        expect(SoulseekTransferState.downloading.isActive, isTrue);
      });
      test('connecting is active', () {
        expect(SoulseekTransferState.connecting.isActive, isTrue);
      });
      test('completed is NOT active', () {
        expect(SoulseekTransferState.completed.isActive, isFalse);
      });
      test('idle is NOT active', () {
        expect(SoulseekTransferState.idle.isActive, isFalse);
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  SoulseekConnectionState
  // ═══════════════════════════════════════════════════════════════════
  group('SoulseekConnectionState', () {
    group('fromString — direct match (case-insensitive)', () {
      for (final state in SoulseekConnectionState.values) {
        test('"${state.name}" → $state', () {
          expect(SoulseekConnectionState.fromString(state.name), state);
        });
        test('"${state.name.toUpperCase()}" → $state', () {
          expect(
            SoulseekConnectionState.fromString(state.name.toUpperCase()),
            state,
          );
        });
      }
    });

    test('null → disconnected', () {
      expect(
        SoulseekConnectionState.fromString(null),
        SoulseekConnectionState.disconnected,
      );
    });

    test('empty → disconnected', () {
      expect(
        SoulseekConnectionState.fromString(''),
        SoulseekConnectionState.disconnected,
      );
    });

    group('fromString — C# fallbacks', () {
      test('LOGGEDIN → connected', () {
        expect(
          SoulseekConnectionState.fromString('LOGGEDIN'),
          SoulseekConnectionState.connected,
        );
      });

      test('LOGGED_IN → connected', () {
        expect(
          SoulseekConnectionState.fromString('LOGGED_IN'),
          SoulseekConnectionState.connected,
        );
      });

      test('CONNECTED → connected (no DIS prefix)', () {
        expect(
          SoulseekConnectionState.fromString('CONNECTED'),
          SoulseekConnectionState.connected,
        );
      });

      test('DISCONNECTED → disconnected', () {
        expect(
          SoulseekConnectionState.fromString('DISCONNECTED'),
          SoulseekConnectionState.disconnected,
        );
      });

      test('DISCONNECTING → reconnecting', () {
        expect(
          SoulseekConnectionState.fromString('DISCONNECTING'),
          SoulseekConnectionState.reconnecting,
        );
      });

      test('RECONNECT → reconnecting', () {
        expect(
          SoulseekConnectionState.fromString('RECONNECT'),
          SoulseekConnectionState.reconnecting,
        );
      });

      test('LOGGING → connecting', () {
        expect(
          SoulseekConnectionState.fromString('LOGGING'),
          SoulseekConnectionState.connecting,
        );
      });

      test('FAIL → failed', () {
        expect(
          SoulseekConnectionState.fromString('FAIL'),
          SoulseekConnectionState.failed,
        );
      });

      test('FAILED → failed', () {
        expect(
          SoulseekConnectionState.fromString('FAILED'),
          SoulseekConnectionState.failed,
        );
      });
    });

    test('unknown string → disconnected', () {
      expect(
        SoulseekConnectionState.fromString('WEIRD'),
        SoulseekConnectionState.disconnected,
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  SoulseekSearchResult
  // ═══════════════════════════════════════════════════════════════════
  group('SoulseekSearchResult', () {
    test('fromMap parses all fields', () {
      final result = SoulseekSearchResult.fromMap({
        'resultId': 'r1',
        'username': 'user1',
        'filename': 'Music/Artist - Title.flac',
        'sizeBytes': 50000000,
        'extension': 'flac',
        'bitrate': 1411,
        'sampleRate': 44100,
        'bitDepth': 16,
        'durationSeconds': 240,
        'queueLength': 5,
        'freeUploadSlots': 1,
        'uploadSpeed': 500,
      });

      expect(result.resultId, 'r1');
      expect(result.username, 'user1');
      expect(result.filename, 'Music/Artist - Title.flac');
      expect(result.sizeBytes, 50000000);
      expect(result.extension, 'flac');
      expect(result.bitrate, 1411);
      expect(result.sampleRate, 44100);
      expect(result.bitDepth, 16);
      expect(result.durationSeconds, 240);
      expect(result.queueLength, 5);
      expect(result.freeUploadSlots, 1);
      expect(result.uploadSpeed, 500);
    });

    test('fromMap with missing optional fields defaults to null', () {
      final result = SoulseekSearchResult.fromMap({
        'resultId': 'r2',
        'username': 'user2',
        'filename': 'track.mp3',
        'sizeBytes': 8000000,
        'extension': 'mp3',
        'queueLength': 0,
        'freeUploadSlots': 0,
        'uploadSpeed': 100,
      });

      expect(result.bitrate, isNull);
      expect(result.sampleRate, isNull);
      expect(result.bitDepth, isNull);
      expect(result.durationSeconds, isNull);
    });

    test('fromMap with missing required fields defaults to empty/zero', () {
      final result = SoulseekSearchResult.fromMap({});

      expect(result.resultId, '');
      expect(result.username, '');
      expect(result.filename, '');
      expect(result.sizeBytes, 0);
      expect(result.extension, '');
      expect(result.queueLength, 0);
      expect(result.freeUploadSlots, 0);
      expect(result.uploadSpeed, 0);
    });

    test('fromMap handles double values for int fields', () {
      final result = SoulseekSearchResult.fromMap({
        'sizeBytes': 50000000.0,
        'bitrate': 320.0,
        'queueLength': 3.0,
        'freeUploadSlots': 1.0,
        'uploadSpeed': 200.0,
      });

      expect(result.sizeBytes, 50000000);
      expect(result.bitrate, 320);
      expect(result.queueLength, 3);
      expect(result.freeUploadSlots, 1);
      expect(result.uploadSpeed, 200);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  SoulseekTransferInfo
  // ═══════════════════════════════════════════════════════════════════
  group('SoulseekTransferInfo', () {
    test('fromMap parses all fields', () {
      final info = SoulseekTransferInfo.fromMap({
        'downloadId': 'dl_abc',
        'state': 'downloading',
        'bytesReceived': 1000,
        'totalBytes': 5000,
        'bytesPerSecond': 500,
        'localPath': '/cache/file.flac',
        'errorCode': null,
        'retryable': true,
        'message': 'in progress',
      });

      expect(info.downloadId, 'dl_abc');
      expect(info.state, SoulseekTransferState.downloading);
      expect(info.bytesReceived, 1000);
      expect(info.totalBytes, 5000);
      expect(info.bytesPerSecond, 500);
      expect(info.localPath, '/cache/file.flac');
      expect(info.errorCode, isNull);
      expect(info.retryable, isTrue);
      expect(info.message, 'in progress');
    });

    test('fromMap with empty map defaults safely', () {
      final info = SoulseekTransferInfo.fromMap({});

      expect(info.downloadId, '');
      expect(info.state, SoulseekTransferState.idle);
      expect(info.bytesReceived, 0);
      expect(info.totalBytes, 0);
      expect(info.bytesPerSecond, 0);
      expect(info.localPath, isNull);
      expect(info.errorCode, isNull);
      expect(info.retryable, isFalse);
      expect(info.message, isNull);
    });

    group('progress', () {
      test('returns null when totalBytes is 0', () {
        const info = SoulseekTransferInfo(
          downloadId: 'dl',
          state: SoulseekTransferState.queued,
          bytesReceived: 0,
          totalBytes: 0,
        );
        expect(info.progress, isNull);
      });

      test('returns null when totalBytes is negative', () {
        const info = SoulseekTransferInfo(
          downloadId: 'dl',
          state: SoulseekTransferState.queued,
          bytesReceived: 0,
          totalBytes: -1,
        );
        expect(info.progress, isNull);
      });

      test('returns fraction for valid values', () {
        const info = SoulseekTransferInfo(
          downloadId: 'dl',
          state: SoulseekTransferState.downloading,
          bytesReceived: 2500,
          totalBytes: 5000,
        );
        expect(info.progress, 0.5);
      });

      test('returns 0 when nothing received', () {
        const info = SoulseekTransferInfo(
          downloadId: 'dl',
          state: SoulseekTransferState.queued,
          bytesReceived: 0,
          totalBytes: 5000,
        );
        expect(info.progress, 0.0);
      });

      test('returns 1.0 when fully received', () {
        const info = SoulseekTransferInfo(
          downloadId: 'dl',
          state: SoulseekTransferState.completed,
          bytesReceived: 5000,
          totalBytes: 5000,
        );
        expect(info.progress, 1.0);
      });

      test('clamps to 1.0 when bytesReceived > totalBytes', () {
        const info = SoulseekTransferInfo(
          downloadId: 'dl',
          state: SoulseekTransferState.completed,
          bytesReceived: 6000,
          totalBytes: 5000,
        );
        expect(info.progress, 1.0);
      });
    });

    test('toMap roundtrips key fields', () {
      const original = SoulseekTransferInfo(
        downloadId: 'dl_xyz',
        state: SoulseekTransferState.paused,
        bytesReceived: 300,
        totalBytes: 900,
        bytesPerSecond: 150,
        localPath: '/data/file.mp3',
        errorCode: 'ERR',
        retryable: true,
        message: 'paused',
      );
      final map = original.toMap();

      expect(map['downloadId'], 'dl_xyz');
      expect(map['state'], 'PAUSED');
      expect(map['bytesReceived'], 300);
      expect(map['totalBytes'], 900);
      expect(map['bytesPerSecond'], 150);
      expect(map['localPath'], '/data/file.mp3');
      expect(map['errorCode'], 'ERR');
      expect(map['retryable'], isTrue);
      expect(map['message'], 'paused');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  SoulseekCacheEntry
  // ═══════════════════════════════════════════════════════════════════
  group('SoulseekCacheEntry', () {
    test('fromMap parses all fields', () {
      final entry = SoulseekCacheEntry.fromMap({
        'cacheKey': 'key123',
        'localPath': '/cache/abc.flac',
        'sizeBytes': 50000000,
        'complete': true,
        'pinned': false,
        'title': 'Song',
        'artist': 'Artist',
        'durationSeconds': 240,
        'extension': 'flac',
      });

      expect(entry.extension, 'flac');

      expect(entry.cacheKey, 'key123');
      expect(entry.localPath, '/cache/abc.flac');
      expect(entry.sizeBytes, 50000000);
      expect(entry.complete, isTrue);
      expect(entry.pinned, isFalse);
      expect(entry.title, 'Song');
      expect(entry.artist, 'Artist');
      expect(entry.durationSeconds, 240);
    });

    test('NEW-3: fromMap parses metadata fields (v2 records)', () {
      final entry = SoulseekCacheEntry.fromMap({
        'cacheKey': 'k2',
        'localPath': '/cache/x.mp3',
        'sizeBytes': 1000,
        'complete': true,
        'pinned': true,
        'title': 'Название',
        'artist': 'Исполнитель',
        'durationSeconds': 195,
      });

      expect(entry.title, 'Название');
      expect(entry.artist, 'Исполнитель');
      expect(entry.durationSeconds, 195);
    });

    test('NEW-3: fromMap metadata null for pre-v2 records', () {
      final entry = SoulseekCacheEntry.fromMap({
        'cacheKey': 'k',
        'localPath': '/p',
        'sizeBytes': 100,
      });

      expect(entry.title, isNull);
      expect(entry.artist, isNull);
      expect(entry.durationSeconds, isNull);
    });

    test('Этап 2.3: fromMap parses extension field', () {
      final entry = SoulseekCacheEntry.fromMap({
        'cacheKey': 'k',
        'localPath': '/p/x.mp3',
        'sizeBytes': 100,
        'extension': 'mp3',
      });

      expect(entry.extension, 'mp3');
    });

    test('Этап 2.3: extension null for старых записей без поля', () {
      final entry = SoulseekCacheEntry.fromMap({
        'cacheKey': 'k',
        'localPath': '/p',
        'sizeBytes': 100,
      });

      expect(entry.extension, isNull);
    });

    test('Этап 2.3: extension нормализуется (trim + lower + без точки)', () {
      final entry = SoulseekCacheEntry.fromMap({
        'cacheKey': 'k',
        'localPath': '/p',
        'sizeBytes': 100,
        'extension': ' .FLAC ',
      });

      expect(entry.extension, 'flac');
    });

    test('fromMap defaults complete/pinned to false when missing', () {
      final entry = SoulseekCacheEntry.fromMap({
        'cacheKey': 'k',
        'localPath': '/p',
        'sizeBytes': 100,
      });

      expect(entry.complete, isFalse);
      expect(entry.pinned, isFalse);
    });

    test('fromMap with empty map defaults safely', () {
      final entry = SoulseekCacheEntry.fromMap({});

      expect(entry.cacheKey, '');
      expect(entry.localPath, '');
      expect(entry.sizeBytes, 0);
      expect(entry.complete, isFalse);
      expect(entry.pinned, isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  SoulseekException.isServiceBindRace (P3)
  // ═══════════════════════════════════════════════════════════════════
  group('SoulseekException.isServiceBindRace', () {
    test('SERVICE_BIND_TIMEOUT → true', () {
      const e = SoulseekException('SERVICE_BIND_TIMEOUT', 'bind timed out');
      expect(e.isServiceBindRace, isTrue);
    });

    test('SERVICE_UNAVAILABLE → true', () {
      const e = SoulseekException('SERVICE_UNAVAILABLE', 'null binding');
      expect(e.isServiceBindRace, isTrue);
    });

    test('NOT_CONNECTED "Service not bound" → true', () {
      const e = SoulseekException('NOT_CONNECTED', 'Service not bound');
      expect(e.isServiceBindRace, isTrue);
    });

    test('NOT_CONNECTED "service NOT BOUND" (case-insensitive) → true', () {
      const e = SoulseekException('NOT_CONNECTED', 'Service NOT BOUND yet');
      expect(e.isServiceBindRace, isTrue);
    });

    test('NOT_CONNECTED with other message → false', () {
      const e = SoulseekException('NOT_CONNECTED', 'Soulseek client offline');
      expect(e.isServiceBindRace, isFalse);
    });

    test('other codes → false', () {
      expect(
        const SoulseekException('INVALID_ARGS', 'Service not bound-ish')
            .isServiceBindRace,
        isFalse,
      );
      expect(
        const SoulseekException('INTERNAL_ERROR', 'boom').isServiceBindRace,
        isFalse,
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  SoulseekDownloadResult
  // ═══════════════════════════════════════════════════════════════════
  group('SoulseekDownloadResult', () {
    test('fromMap with cacheHit=true', () {
      final result = SoulseekDownloadResult.fromMap({
        'downloadId': 'dl_1',
        'result': '/cache/file.flac',
        'cacheHit': true,
      });

      expect(result.downloadId, 'dl_1');
      expect(result.result, '/cache/file.flac');
      expect(result.cacheHit, isTrue);
    });

    test('fromMap with cacheHit=false', () {
      final result = SoulseekDownloadResult.fromMap({
        'downloadId': 'dl_2',
        'result': 'dl_2',
        'cacheHit': false,
      });

      expect(result.cacheHit, isFalse);
    });

    test('fromMap defaults cacheHit to false when missing', () {
      final result = SoulseekDownloadResult.fromMap({
        'downloadId': 'dl_3',
        'result': 'dl_3',
      });

      expect(result.cacheHit, isFalse);
    });

    test('fromMap with empty map defaults safely', () {
      final result = SoulseekDownloadResult.fromMap({});

      expect(result.downloadId, '');
      expect(result.result, '');
      expect(result.cacheHit, isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  SoulseekConnectionInfo
  // ═══════════════════════════════════════════════════════════════════
  group('SoulseekConnectionInfo', () {
    test('fromMap parses username and state', () {
      final info = SoulseekConnectionInfo.fromMap({
        'username': 'myuser',
        'state': 'connected',
      });

      expect(info.username, 'myuser');
      expect(info.state, SoulseekConnectionState.connected);
    });

    test('fromMap with missing state defaults to disconnected', () {
      final info = SoulseekConnectionInfo.fromMap({
        'username': 'u',
      });

      expect(info.state, SoulseekConnectionState.disconnected);
    });

    test('fromMap with empty map defaults safely', () {
      final info = SoulseekConnectionInfo.fromMap({});

      expect(info.username, '');
      expect(info.state, SoulseekConnectionState.disconnected);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  SoulseekEvent (sealed hierarchy)
  // ═══════════════════════════════════════════════════════════════════
  group('SoulseekEvent', () {
    test('fromMap type=transfer → SoulseekTransferEvent', () {
      final event = SoulseekEvent.fromMap({
        'eventType': 'transfer',
        'downloadId': 'dl_1',
        'state': 'downloading',
        'bytesReceived': 100,
        'totalBytes': 1000,
        'bytesPerSecond': 50,
      });

      expect(event, isA<SoulseekTransferEvent>());
      final transferEvent = event as SoulseekTransferEvent;
      expect(transferEvent.downloadId, 'dl_1');
      expect(transferEvent.state, SoulseekTransferState.downloading);
      expect(transferEvent.bytesReceived, 100);
      expect(transferEvent.totalBytes, 1000);
      expect(transferEvent.bytesPerSecond, 50);
    });

    test('fromMap type=connection → SoulseekConnectionEvent', () {
      final event = SoulseekEvent.fromMap({
        'eventType': 'connection',
        'state': 'connected',
        'message': 'Login successful',
      });

      expect(event, isA<SoulseekConnectionEvent>());
      final connEvent = event as SoulseekConnectionEvent;
      expect(connEvent.state, SoulseekConnectionState.connected);
      expect(connEvent.message, 'Login successful');
    });

    test('fromMap type=transferSnapshot → SoulseekTransferSnapshot', () {
      final event = SoulseekEvent.fromMap({
        'eventType': 'transferSnapshot',
        'transfers': [
          {'downloadId': 'dl_a', 'state': 'queued'},
          {'downloadId': 'dl_b', 'state': 'downloading'},
        ],
      });

      expect(event, isA<SoulseekTransferSnapshot>());
      final snapshot = event as SoulseekTransferSnapshot;
      expect(snapshot.transfers.length, 2);
      expect(snapshot.transfers[0].downloadId, 'dl_a');
      expect(snapshot.transfers[0].state, SoulseekTransferState.queued);
      expect(snapshot.transfers[1].downloadId, 'dl_b');
      expect(snapshot.transfers[1].state, SoulseekTransferState.downloading);
    });

    test('fromMap type=transferSnapshot with missing transfers → empty list', () {
      final event = SoulseekEvent.fromMap({
        'eventType': 'transferSnapshot',
      });

      expect(event, isA<SoulseekTransferSnapshot>());
      final snapshot = event as SoulseekTransferSnapshot;
      expect(snapshot.transfers, isEmpty);
    });

    test('fromMap with unknown type → SoulseekUnknownEvent', () {
      final event = SoulseekEvent.fromMap({
        'eventType': 'somethingNew',
        'data': 42,
      });

      expect(event, isA<SoulseekUnknownEvent>());
      final unknown = event as SoulseekUnknownEvent;
      expect(unknown.type, 'somethingNew');
      expect(unknown.raw['data'], 42);
    });

    test('fromMap with missing eventType → SoulseekUnknownEvent', () {
      final event = SoulseekEvent.fromMap({'foo': 'bar'});

      expect(event, isA<SoulseekUnknownEvent>());
      final unknown = event as SoulseekUnknownEvent;
      expect(unknown.type, '');
    });

    test('fromJsonString parses transfer event', () {
      final json = jsonEncode({
        'eventType': 'transfer',
        'downloadId': 'dl_json',
        'state': 'completed',
        'localPath': '/cache/done.flac',
      });
      final event = SoulseekEvent.fromJsonString(json);

      expect(event, isA<SoulseekTransferEvent>());
      final transferEvent = event as SoulseekTransferEvent;
      expect(transferEvent.downloadId, 'dl_json');
      expect(transferEvent.state, SoulseekTransferState.completed);
      expect(transferEvent.localPath, '/cache/done.flac');
    });

    test('fromJsonString parses connection event', () {
      final json = jsonEncode({
        'eventType': 'connection',
        'state': 'failed',
        'message': 'Login failed',
      });
      final event = SoulseekEvent.fromJsonString(json);

      expect(event, isA<SoulseekConnectionEvent>());
      final connEvent = event as SoulseekConnectionEvent;
      expect(connEvent.state, SoulseekConnectionState.failed);
      expect(connEvent.message, 'Login failed');
    });

    test('fromJsonString with non-Map JSON → SoulseekUnknownEvent', () {
      final event = SoulseekEvent.fromJsonString('"just a string"');

      expect(event, isA<SoulseekUnknownEvent>());
      final unknown = event as SoulseekUnknownEvent;
      expect(unknown.type, 'raw');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  SoulseekSearchFilters.toMap
  // ═══════════════════════════════════════════════════════════════════
  group('SoulseekSearchFilters.toMap', () {
    test('empty filters → only losslessOnly=false', () {
      final map = SoulseekSearchFilters.empty.toMap();
      expect(map['losslessOnly'], isFalse);
      expect(map.containsKey('extensions'), isFalse);
      expect(map.containsKey('minSizeBytes'), isFalse);
      expect(map.containsKey('maxSizeBytes'), isFalse);
      expect(map.containsKey('minBitrate'), isFalse);
      expect(map.containsKey('minPeerUploadSpeed'), isFalse);
      expect(map.containsKey('maxPeerQueueLength'), isFalse);
    });

    test('populated filters → all fields present', () {
      const filters = SoulseekSearchFilters(
        extensions: ['flac', 'mp3'],
        minSizeBytes: 1000,
        maxSizeBytes: 50000000,
        minBitrate: 320,
        losslessOnly: true,
        minPeerUploadSpeed: 100,
        maxPeerQueueLength: 10,
      );
      final map = filters.toMap();

      expect(map['extensions'], ['flac', 'mp3']);
      expect(map['minSizeBytes'], 1000);
      expect(map['maxSizeBytes'], 50000000);
      expect(map['minBitrate'], 320);
      expect(map['losslessOnly'], isTrue);
      expect(map['minPeerUploadSpeed'], 100);
      expect(map['maxPeerQueueLength'], 10);
    });
  });
}
