import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/app_database.dart';
import 'package:player/core/history_repository.dart';
import 'package:player/models/track.dart';
import '../setup/test_harness.dart';

Track _t(String id) => Track(
      id: id, sourceId: 'youtube',
      title: 'Song $id', artist: 'Artist $id',
      duration: const Duration(seconds: 180),
      artworkUrl: 'https://img.example.com/$id.jpg',
    );

void main() {
  TestHarness.ensureInitialized();
  setUp(() async { await TestHarness.setUpDb(); await HistoryRepository.instance.reload(); });
  tearDown(() async => await TestHarness.tearDownDb());

  group('HistoryRepository', () {
    test('add inserts at beginning', () async {
      await HistoryRepository.instance.add(_t('1'));
      await HistoryRepository.instance.add(_t('2'));
      final l = HistoryRepository.instance.current;
      expect(l.length, 2);
      expect(l.first.track.id, '2');
      expect(l.last.track.id, '1');
    });

    test('add deduplicates by globalId', () async {
      await HistoryRepository.instance.add(_t('1'));
      await HistoryRepository.instance.add(_t('2'));
      await HistoryRepository.instance.add(_t('1'));
      final l = HistoryRepository.instance.current;
      expect(l.length, 2);
      expect(l.first.track.id, '1');
      expect(l.last.track.id, '2');
    });

    test('add respects limit', () async {
      await HistoryRepository.instance.setLimit(3);
      for (var i = 1; i <= 5; i++) { await HistoryRepository.instance.add(_t('$i')); }
      final l = HistoryRepository.instance.current;
      expect(l.length, 3);
      expect(l.first.track.id, '5');
      expect(l.last.track.id, '3');
    });

    test('add is idempotent', () async {
      await HistoryRepository.instance.add(_t('1'));
      await HistoryRepository.instance.add(_t('1'));
      await HistoryRepository.instance.add(_t('1'));
      expect(HistoryRepository.instance.current.length, 1);
    });

    test('remove deletes entry', () async {
      await HistoryRepository.instance.add(_t('1'));
      await HistoryRepository.instance.add(_t('2'));
      final t = HistoryRepository.instance.current.firstWhere((e) => e.track.id == '1');
      await HistoryRepository.instance.remove(t);
      expect(HistoryRepository.instance.current.length, 1);
      expect(HistoryRepository.instance.current.first.track.id, '2');
    });

    test('clear removes all', () async {
      await HistoryRepository.instance.add(_t('1'));
      await HistoryRepository.instance.add(_t('2'));
      await HistoryRepository.instance.clear();
      expect(HistoryRepository.instance.current, isEmpty);
    });

    test('clear no-op when empty', () async {
      await HistoryRepository.instance.clear();
      expect(HistoryRepository.instance.current, isEmpty);
    });

    test('setLimit decrease trims', () async {
      await HistoryRepository.instance.setLimit(100);
      for (var i = 1; i <= 10; i++) { await HistoryRepository.instance.add(_t('$i')); }
      expect(HistoryRepository.instance.current.length, 10);
      await HistoryRepository.instance.setLimit(5);
      expect(HistoryRepository.instance.current.length, 5);
      expect(HistoryRepository.instance.limit, 5);
    });

    test('setLimit increase no-op on list', () async {
      await HistoryRepository.instance.setLimit(3);
      for (var i = 1; i <= 3; i++) { await HistoryRepository.instance.add(_t('$i')); }
      await HistoryRepository.instance.setLimit(100);
      expect(HistoryRepository.instance.current.length, 3);
    });

    test('setLimit persists to DB', () async {
      await HistoryRepository.instance.setLimit(42);
      expect(await AppDatabase.instance.getSetting('history_limit_v1'), '42');
    });

    test('setLimit clamps', () async {
      await HistoryRepository.instance.setLimit(0);
      expect(HistoryRepository.instance.limit, 1);
      await HistoryRepository.instance.setLimit(9999);
      expect(HistoryRepository.instance.limit, HistoryRepository.maxLimit);
    });

    test('stream emits on add', () async {
      await HistoryRepository.instance.ensureLoaded();
      final out = <List<HistoryEntry>>[];
      final sub = HistoryRepository.instance.stream.listen(out.add);
      // Ждём микротаск чтобы получить начальное значение стрима
      await Future.microtask(() {});
      await HistoryRepository.instance.add(_t('1'));
      await HistoryRepository.instance.add(_t('2'));
      await Future.microtask(() {});
      await sub.cancel();
      // Должны получить минимум 2 снимка (по одному на каждый add)
      expect(out.length, greaterThanOrEqualTo(2));
      // Последний снимок содержит оба трека
      expect(out.last.length, 2);
    });

    test('stream emits on clear', () async {
      await HistoryRepository.instance.add(_t('1'));
      final out = <List<HistoryEntry>>[];
      final sub = HistoryRepository.instance.stream.listen(out.add);
      await Future.microtask(() {});
      await HistoryRepository.instance.clear();
      await Future.microtask(() {});
      await sub.cancel();
      expect(out.isNotEmpty, isTrue);
      expect(out.last, isEmpty);
    });

    test('reload after backup import', () async {
      await HistoryRepository.instance.add(_t('1'));
      await HistoryRepository.instance.add(_t('2'));
      final b = await AppDatabase.instance.exportFullBackup();
      await AppDatabase.instance.close();
      await TestHarness.setUpDb();
      await AppDatabase.instance.importFullBackup(b);
      await HistoryRepository.instance.reload();
      final l = HistoryRepository.instance.current;
      expect(l.length, 2);
      expect(l.first.track.id, '2');
    });

    test('data survives DB reopen', () async {
      await HistoryRepository.instance.add(_t('1'));
      await HistoryRepository.instance.add(_t('2'));
      await AppDatabase.instance.close();
      await TestHarness.setUpDb();
      await HistoryRepository.instance.reload();
      final l = HistoryRepository.instance.current;
      expect(l.length, 2);
      expect(l.first.track.id, '2');
      expect(l.last.track.id, '1');
    });

    test('null artwork does not crash', () async {
      const t = Track(id: 'min', sourceId: 'sc', title: 'T', artist: 'A');
      await HistoryRepository.instance.add(t);
      expect(HistoryRepository.instance.current.first.track.artworkUrl, isNull);
    });

    test('unicode title/artist', () async {
      const t = Track(id: 'ru1', sourceId: 'muzmo', title: 'Исчезаю', artist: 'Psychosis');
      await HistoryRepository.instance.add(t);
      final l = HistoryRepository.instance.current;
      expect(l.first.track.title, 'Исчезаю');
      expect(l.first.track.artist, 'Psychosis');
    });
  });
}