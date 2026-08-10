import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/app_database.dart';
import 'package:player/core/providers.dart';
import 'package:player/core/history_repository.dart';
import '../setup/test_harness.dart';

/// Ждёт завершения асинхронной инициализации нотифаера через его
/// `@visibleForTesting ready` Future. Заменяет тайминговый хак с
/// `Future.delayed(Duration.zero)`.
Future<T> _readyNotifier<T extends StateNotifier>(T notifier) async {
  // Все нотифаеры имеют @visibleForTesting getter ready.
  // ignore: invalid_use_of_visible_for_testing_member
  await (notifier as dynamic).ready;
  return notifier;
}

void main() {
  TestHarness.ensureInitialized();

  setUp(() async => await TestHarness.setUpDb());
  tearDown(() async => await TestHarness.tearDownDb());

  group('SearchHistoryNotifier', () {
    late SearchHistoryNotifier notifier;

    setUp(() async {
      notifier = await _readyNotifier(SearchHistoryNotifier());
    });

    tearDown(() async {
      await AppDatabase.instance.clearSearchHistory();
    });

    test('add deduplicates case-insensitively', () async {
      await notifier.add('Hello');
      await notifier.add('hello');
      await notifier.add('HELLO');
      expect(notifier.state.length, 1);
      // Последнее добавленное значение сохраняется как есть
      expect(notifier.state.first, 'HELLO');
    });

    test('add respects max 12 items', () async {
      for (var i = 0; i < 20; i++) {
        await notifier.add('Query $i');
      }
      expect(notifier.state.length, 12);
      expect(notifier.state.first, 'Query 19');
      expect(notifier.state.last, 'Query 8');
    });

    test('remove deletes specific query', () async {
      await notifier.add('q1');
      await notifier.add('q2');
      await notifier.remove('q1');
      expect(notifier.state.length, 1);
      expect(notifier.state.first, 'q2');
    });

    test('clear removes everything', () async {
      await notifier.add('q1');
      await notifier.add('q2');
      await notifier.clear();
      expect(notifier.state, isEmpty);
    });

    test('add ignores empty query', () async {
      await notifier.add('');
      await notifier.add('   ');
      expect(notifier.state, isEmpty);
    });

    test('reload re-reads from DB', () async {
      await AppDatabase.instance.addSearchQuery('from_db');
      await notifier.reload();
      expect(notifier.state.length, 1);
      expect(notifier.state.first, 'from_db');
    });
  });

  group('HistoryLimitNotifier', () {
    late HistoryLimitNotifier notifier;

    setUp(() async {
      notifier = await _readyNotifier(HistoryLimitNotifier());
    });

    test('initial limit is default', () {
      expect(notifier.state, HistoryRepository.defaultLimit);
    });

    test('setLimit updates value', () async {
      await notifier.setLimit(50);
      expect(notifier.state, 50);
    });

    test('reload re-reads from DB', () async {
      await notifier.setLimit(77);
      expect(notifier.state, 77);
      // Проверяем что значение сохранилось в БД
      expect(await AppDatabase.instance.getSetting('history_limit_v1'), '77');
    });
  });

  group('VibrationNotifier', () {
    late VibrationNotifier notifier;

    setUp(() async {
      notifier = await _readyNotifier(VibrationNotifier());
    });

    test('toggle flips value', () async {
      final before = notifier.state;
      await notifier.toggle();
      expect(notifier.state, !before);
      await notifier.toggle();
      expect(notifier.state, before);
    });

    test('setEnabled updates', () async {
      await notifier.setEnabled(false);
      expect(notifier.state, false);
      await notifier.setEnabled(true);
      expect(notifier.state, true);
    });

    test('reload re-reads from DB', () async {
      await AppDatabase.instance.setSetting('vibration_enabled', 'false');
      await notifier.reload();
      expect(notifier.state, false);
    });
  });

  group('SearchViewModeNotifier', () {
    late SearchViewModeNotifier notifier;

    setUp(() async {
      notifier = await _readyNotifier(SearchViewModeNotifier());
    });

    test('default is grid', () {
      expect(notifier.state, SearchViewMode.grid);
    });

    test('setMode switches grid/list', () async {
      await notifier.setMode(SearchViewMode.list);
      expect(notifier.state, SearchViewMode.list);
      await notifier.setMode(SearchViewMode.grid);
      expect(notifier.state, SearchViewMode.grid);
    });

    test('reload re-reads from DB', () async {
      await AppDatabase.instance.setSetting('search_view_mode', 'list');
      await notifier.reload();
      expect(notifier.state, SearchViewMode.list);
    });
  });

  group('AppThemeModeNotifier', () {
    late AppThemeModeNotifier notifier;

    setUp(() async {
      notifier = await _readyNotifier(AppThemeModeNotifier());
    });

    test('default is fixed (design contract: gray palette)', () {
      expect(notifier.state, AppThemeMode.fixed);
    });

    test('toggle switches fixed/dynamic', () async {
      await notifier.toggle();
      expect(notifier.state, AppThemeMode.dynamic);
      await notifier.toggle();
      expect(notifier.state, AppThemeMode.fixed);
    });

    test('setMode updates', () async {
      await notifier.setMode(AppThemeMode.fixed);
      expect(notifier.state, AppThemeMode.fixed);
      await notifier.setMode(AppThemeMode.dynamic);
      expect(notifier.state, AppThemeMode.dynamic);
    });

    test('reload re-reads from DB', () async {
      await AppDatabase.instance.setSetting('app_theme_mode', 'fixed');
      await notifier.reload();
      expect(notifier.state, AppThemeMode.fixed);
    });
  });
}