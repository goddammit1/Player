// Правило ухода ручной загрузки к другому пиру ([SoulseekQueueWatch]) и
// сведения об очереди пира в модели/подписи.

import 'package:flutter_test/flutter_test.dart';

import 'package:player/sources/soulseek_models.dart';
import 'package:player/sources/soulseek_queue_watch.dart';
import 'package:player/ui/widgets/soulseek_transfer_tile.dart';

SoulseekTransferInfo _info(
  SoulseekTransferState state, {
  SoulseekQueueStatus? status,
  int? place,
  int bytes = 0,
  int speed = 0,
}) =>
    SoulseekTransferInfo(
      downloadId: 'dl_x',
      state: state,
      bytesReceived: bytes,
      bytesPerSecond: speed,
      queueStatus: status,
      placeInQueue: place,
    );

const _q = SoulseekTransferState.queuedRemotely;

void main() {
  late DateTime now;
  late SoulseekQueueWatch watch;

  setUp(() {
    now = DateTime(2026, 10, 19, 12);
    watch = SoulseekQueueWatch(clock: () => now);
  });

  void at(Duration offset, SoulseekTransferInfo info) {
    now = DateTime(2026, 10, 19, 12).add(offset);
    watch.observe(info);
  }

  group('SoulseekQueueWatch', () {
    test('no queue yet → waits', () {
      at(Duration.zero, _info(SoulseekTransferState.queued));
      now = now.add(const Duration(hours: 1));
      expect(watch.verdict(), isNull);
    });

    test('one offline answer is not enough, two in a row are', () {
      at(Duration.zero, _info(_q, status: SoulseekQueueStatus.offline));
      expect(watch.verdict(), isNull);
      at(const Duration(minutes: 1), _info(_q, status: SoulseekQueueStatus.ok, place: 3));
      at(const Duration(minutes: 2), _info(_q, status: SoulseekQueueStatus.offline));
      expect(watch.verdict(), isNull);
      at(const Duration(minutes: 3), _info(_q, status: SoulseekQueueStatus.offline));
      expect(watch.verdict(), SoulseekSwitchReason.peerOffline);
    });

    test('unreachable three times in a row', () {
      for (var i = 0; i < 2; i++) {
        at(Duration(minutes: i), _info(_q, status: SoulseekQueueStatus.unreachable));
      }
      expect(watch.verdict(), isNull);
      at(const Duration(minutes: 2), _info(_q, status: SoulseekQueueStatus.unreachable));
      expect(watch.verdict(), SoulseekSwitchReason.peerUnreachable);
    });

    test('a long queue switches at once', () {
      at(Duration.zero, _info(_q, status: SoulseekQueueStatus.ok, place: 19));
      expect(watch.verdict(), isNull);
      at(const Duration(minutes: 1), _info(_q, status: SoulseekQueueStatus.ok, place: 20));
      expect(watch.verdict(), SoulseekSwitchReason.queueTooLong);
    });

    test('a place that does not move for 10 minutes is stalled', () {
      at(Duration.zero, _info(_q, status: SoulseekQueueStatus.ok, place: 5));
      at(const Duration(minutes: 9), _info(_q, status: SoulseekQueueStatus.ok, place: 4));
      at(const Duration(minutes: 18), _info(_q, status: SoulseekQueueStatus.ok, place: 4));
      expect(watch.verdict(), isNull);
      at(const Duration(minutes: 19), _info(_q, status: SoulseekQueueStatus.ok, place: 4));
      expect(watch.verdict(), SoulseekSwitchReason.queueStalled);
    });

    test('never answering the place query → switch after 5 minutes', () {
      at(Duration.zero, _info(_q));
      at(const Duration(minutes: 4), _info(_q, status: SoulseekQueueStatus.noResponse));
      expect(watch.verdict(), isNull);
      now = now.add(const Duration(minutes: 1));
      expect(watch.verdict(), SoulseekSwitchReason.noReply);
    });

    test('a moving queue is still limited by the total wait', () {
      for (var m = 0; m < 20; m++) {
        at(Duration(minutes: m), _info(_q, status: SoulseekQueueStatus.ok, place: 19 - m % 19));
        expect(watch.verdict(), isNull, reason: 'minute $m');
      }
      at(const Duration(minutes: 20), _info(_q, status: SoulseekQueueStatus.ok, place: 1));
      expect(watch.verdict(), SoulseekSwitchReason.waitTooLong);
    });

    test('total wait survives a retry, the per-stint counters do not', () {
      at(Duration.zero, _info(_q, status: SoulseekQueueStatus.offline));
      at(const Duration(minutes: 1), _info(SoulseekTransferState.queued));
      at(const Duration(minutes: 2), _info(_q, status: SoulseekQueueStatus.offline));
      expect(watch.verdict(), isNull);
      at(const Duration(minutes: 20), _info(_q, status: SoulseekQueueStatus.ok, place: 1));
      expect(watch.verdict(), SoulseekSwitchReason.waitTooLong);
    });

    test('pause resets the wait', () {
      at(Duration.zero, _info(_q));
      at(const Duration(minutes: 1), _info(SoulseekTransferState.paused));
      now = now.add(const Duration(hours: 1));
      expect(watch.verdict(), isNull);
    });

    test('bytes flowing → no switch, a later failure still switches', () {
      at(Duration.zero, _info(_q, status: SoulseekQueueStatus.ok, place: 1));
      at(const Duration(minutes: 1),
          _info(SoulseekTransferState.downloading, bytes: 100, speed: 50));
      expect(watch.started, isTrue);
      now = now.add(const Duration(hours: 1));
      expect(watch.verdict(), isNull);
      at(const Duration(hours: 2), _info(SoulseekTransferState.failed, bytes: 100));
      expect(watch.verdict(), SoulseekSwitchReason.failed);
    });

    test('"downloading" without bytes is not a start (Android slot)', () {
      at(Duration.zero, _info(SoulseekTransferState.downloading, bytes: 40));
      expect(watch.started, isFalse);
      at(const Duration(seconds: 1), _info(_q, bytes: 40));
      expect(watch.started, isFalse);
    });

    test('custom limits', () {
      watch = SoulseekQueueWatch(
        clock: () => now,
        limits: const SoulseekQueueLimits(longQueuePlace: 5),
      );
      at(Duration.zero, _info(_q, status: SoulseekQueueStatus.ok, place: 5));
      expect(watch.verdict(), SoulseekSwitchReason.queueTooLong);
    });
  });

  group('queue info in SoulseekTransferInfo', () {
    test('fromMap / toMap round-trip', () {
      final info = SoulseekTransferInfo.fromMap({
        'downloadId': 'dl_x',
        'state': 'QUEUED_REMOTELY',
        'placeInQueue': 7,
        'queueStatus': 'ok',
      });
      expect(info.placeInQueue, 7);
      expect(info.queueStatus, SoulseekQueueStatus.ok);
      final back = SoulseekTransferInfo.fromMap(info.toMap());
      expect(back.placeInQueue, 7);
      expect(back.queueStatus, SoulseekQueueStatus.ok);
    });

    test('unknown or missing status → null', () {
      expect(SoulseekQueueStatus.tryParse('noResponse'),
          SoulseekQueueStatus.noResponse);
      expect(SoulseekQueueStatus.tryParse('weird'), isNull);
      expect(SoulseekQueueStatus.tryParse(null), isNull);
      final info = SoulseekTransferInfo.fromMap(
          {'downloadId': 'dl_x', 'state': 'QUEUED_REMOTELY'});
      expect(info.placeInQueue, isNull);
      expect(info.queueStatus, isNull);
    });
  });

  group('soulseekQueueLabel', () {
    String label(SoulseekQueueStatus? status, [int? place]) =>
        soulseekQueueLabel(_info(_q, status: status, place: place));

    test('labels', () {
      expect(label(null), 'Queued at peer');
      expect(label(SoulseekQueueStatus.ok, 12), 'Queued at peer · #12');
      // 0 — часть клиентов так отвечает «не знаю».
      expect(label(SoulseekQueueStatus.ok, 0), 'Queued at peer');
      expect(label(SoulseekQueueStatus.offline), 'Peer offline');
      expect(label(SoulseekQueueStatus.unreachable), 'Peer unreachable');
      expect(label(SoulseekQueueStatus.noResponse), 'Queued at peer · no reply');
    });
  });
}
