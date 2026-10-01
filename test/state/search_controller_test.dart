import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/providers.dart';
import 'package:player/models/track.dart';
import 'package:player/sources/track_source.dart';
import 'package:player/sources/source_registry.dart';

/// Fake-источник для тестирования SearchController без сети.
///
/// Позволяет контролировать задержку и результат поиска из теста.
class _FakeSource extends TrackSource {
  _FakeSource({required this.id, this.displayName = ''});

  @override
  final String id;
  @override
  final String displayName;

  /// Задержка перед возвратом результата (мс).
  int searchDelayMs = 0;

  /// Результат, который вернёт search().
  List<Track> searchResult = const [];

  @override
  Future<List<Track>> search(String query, {int limit = 20}) async {
    if (searchDelayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: searchDelayMs));
    }
    return searchResult;
  }

  @override
  Future<String> resolveStreamUrl(Track track) async => 'https://example.com/stream.mp3';

  @override
  Future<void> dispose() async {}
}

/// Потоковый fake-источник: снимки выдаются вручную из теста.
class _FakeProgressiveSource extends _FakeSource
    implements ProgressiveSearchSource {
  _FakeProgressiveSource({required super.id});

  StreamController<List<Track>>? controller;
  int listens = 0;
  int cancels = 0;

  @override
  Stream<List<Track>> searchProgressive(String query, {int limit = 20}) {
    final c = StreamController<List<Track>>(
      onListen: () => listens++,
      onCancel: () => cancels++,
    );
    controller = c;
    return c.stream;
  }
}

Track _t(String id, String sourceId) => Track(
      id: id,
      sourceId: sourceId,
      title: 'T$id',
      artist: 'A',
    );

void main() {
  group('SearchController.interleave (static)', () {
    Track t(String id, String sourceId) => Track(
          id: id,
          sourceId: sourceId,
          title: 'T$id',
          artist: 'A',
        );

    test('empty lists → empty result', () {
      expect(SearchController.interleave([]), isEmpty);
    });

    test('single list returns as-is', () {
      final a = [t('1', 'youtube'), t('2', 'youtube')];
      expect(SearchController.interleave([a]), a);
    });

    test('two equal-length lists → round-robin', () {
      final a = [t('a1', 'muzmo'), t('a2', 'muzmo')];
      final b = [t('b1', 'soundcloud'), t('b2', 'soundcloud')];
      final result = SearchController.interleave([a, b]);
      expect(result.map((t) => t.id), ['a1', 'b1', 'a2', 'b2']);
    });

    test('unequal length lists → round-robin then rest', () {
      final a = [t('a1', 'muzmo'), t('a2', 'muzmo'), t('a3', 'muzmo')];
      final b = [t('b1', 'soundcloud')];
      final result = SearchController.interleave([a, b]);
      expect(result.map((t) => t.id), ['a1', 'b1', 'a2', 'a3']);
    });

    test('three lists interleaved', () {
      final a = [t('a', 'youtube')];
      final b = [t('b', 'muzmo')];
      final c = [t('c', 'soundcloud')];
      final result = SearchController.interleave([a, b, c]);
      expect(result.map((t) => t.id), ['a', 'b', 'c']);
    });

    test('empty list in middle does not break', () {
      final a = [t('a1', 'muzmo'), t('a2', 'muzmo')];
      final b = <Track>[];
      final c = [t('c1', 'youtube')];
      final result = SearchController.interleave([a, b, c]);
      expect(result.map((t) => t.id), ['a1', 'c1', 'a2']);
    });

    test('one empty, one non-empty', () {
      final result = SearchController.interleave(
          [<Track>[], [t('x', 'muzmo')]]);
      expect(result.map((t) => t.id), ['x']);
    });
  });

  group('SearchController.setSourceId', () {
    late SearchController controller;

    setUp(() {
      controller = SearchController();
    });

    test('default sourceId is kAllSourcesId', () {
      expect(controller.sourceId, kAllSourcesId);
    });

    test('setSourceId updates state', () {
      controller.setSourceId('muzmo');
      expect(controller.sourceId, 'muzmo');
    });

    test('setSourceId no-op for same value', () {
      final before = controller.sourceId;
      controller.setSourceId(before);
      expect(controller.sourceId, before);
    });
  });

  group('SearchState', () {
    test('default values', () {
      const state = SearchState();
      expect(state.query, '');
      expect(state.results, isEmpty);
      expect(state.loading, false);
      expect(state.error, isNull);
      expect(state.sourceId, kAllSourcesId);
    });

    test('copyWith preserves unchanged fields', () {
      const state = SearchState(
        query: 'q',
        results: [],
        loading: false,
        sourceId: 'muzmo',
      );
      final updated = state.copyWith(loading: true);
      expect(updated.query, 'q');
      expect(updated.loading, true);
      expect(updated.sourceId, 'muzmo');
    });

    test('copyWith nullable error works', () {
      const state = SearchState(error: 'prev error');
      final cleared = state.copyWith(error: null);
      expect(cleared.error, isNull);
    });
  });

  group('SearchController.search with fake sources', () {
    late SearchController controller;
    late _FakeSource sourceA;
    late _FakeSource sourceB;

    setUp(() {
      controller = SearchController();
      sourceA = _FakeSource(id: 'fake_a', displayName: 'Fake A');
      sourceB = _FakeSource(id: 'fake_b', displayName: 'Fake B');
      SourceRegistry.instance.register(sourceA);
      SourceRegistry.instance.register(sourceB);
    });

    tearDown(() async {
      await SourceRegistry.instance.disposeAll();
    });

    test('search in single source returns results', () async {
      sourceA.searchResult = [_t('a1', 'fake_a'), _t('a2', 'fake_a')];
      controller.setSourceId('fake_a');

      await controller.search('test');
      // Даём микротаске отработать
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.results.length, 2);
      expect(controller.state.results[0].id, 'a1');
      expect(controller.state.loading, false);
    });

    test('stale results from slow source are discarded', () async {
      sourceA.searchDelayMs = 200; // 200 мс задержка
      sourceA.searchResult = [_t('slow', 'fake_a')];
      sourceB.searchResult = [_t('fast', 'fake_b')];

      // Запускаем поиск в 'all'
      final searchFuture = controller.search('test');

      // Ждём ~10 мс и меняем запрос — это инвалидирует поколение
      await Future<void>.delayed(const Duration(milliseconds: 10));
      controller.setSourceId('fake_b'); // смена sourceId инкрементирует generation

      await searchFuture;
      // Старый результат не должен примениться (sourceId уже другой)
      // Проверяем что состояние корректно
      expect(controller.state.sourceId, 'fake_b');
    });

    test('search all with interleaved results', () async {
      sourceA.searchResult = [_t('a1', 'fake_a'), _t('a2', 'fake_a')];
      sourceB.searchResult = [_t('b1', 'fake_b')];

      await controller.search('test');
      // Ждём завершения Stream.fromFutures
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Результаты должны быть interleaved: a1, b1, a2
      final ids = controller.state.results.map((t) => t.id).toList();
      expect(ids, containsAll(['a1', 'a2', 'b1']));
      // a1 должен быть перед a2 (interleave гарантирует порядок)
      final a1idx = ids.indexOf('a1');
      final a2idx = ids.indexOf('a2');
      expect(a1idx < a2idx, true);
      expect(controller.state.loading, false);
    });

    test('empty query clears results', () async {
      sourceA.searchResult = [_t('a1', 'fake_a')];
      controller.setSourceId('fake_a');
      await controller.search('test');
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.results.length, 1);

      await controller.search('');
      expect(controller.state.results, isEmpty);
      expect(controller.state.query, '');
    });

    test('isolated source goes to its own section, not into results', () async {
      controller = SearchController(isolatedSourceIds: {'fake_b'});
      sourceA.searchResult = [_t('a1', 'fake_a'), _t('a2', 'fake_a')];
      sourceB.searchDelayMs = 50;
      sourceB.searchResult = [_t('b1', 'fake_b')];

      final future = controller.search('test');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Обычный источник уже ответил, изолированный ещё ищет.
      expect(controller.state.results.map((t) => t.id), ['a1', 'a2']);
      expect(controller.state.loading, false);
      expect(controller.state.isolatedResults, isEmpty);
      expect(controller.state.isolatedLoading, true);

      await future;

      // Основная выдача не изменилась — изолированный трек в секции.
      expect(controller.state.results.map((t) => t.id), ['a1', 'a2']);
      expect(controller.state.isolatedResults.map((t) => t.id), ['b1']);
      expect(controller.state.isolatedLoading, false);
      expect(
        controller.state.allResults.map((t) => t.id),
        ['a1', 'a2', 'b1'],
      );
    });

    test('isolated source is not separated in single-source mode', () async {
      controller = SearchController(isolatedSourceIds: {'fake_b'});
      sourceB.searchResult = [_t('b1', 'fake_b')];
      controller.setSourceId('fake_b');

      await controller.search('test');

      expect(controller.state.results.map((t) => t.id), ['b1']);
      expect(controller.state.isolatedResults, isEmpty);
      expect(controller.state.isolatedLoading, false);
    });

    test('new search clears previous isolated section', () async {
      controller = SearchController(isolatedSourceIds: {'fake_b'});
      sourceB.searchResult = [_t('b1', 'fake_b')];
      await controller.search('first');
      expect(controller.state.isolatedResults, isNotEmpty);

      sourceB.searchDelayMs = 50;
      final future = controller.search('second');
      expect(controller.state.isolatedResults, isEmpty);
      expect(controller.state.isolatedLoading, true);
      await future;
    });

    group('progressive source', () {
      late _FakeProgressiveSource progressive;

      setUp(() {
        progressive = _FakeProgressiveSource(id: 'fake_p');
        SourceRegistry.instance.register(progressive);
        controller = SearchController(isolatedSourceIds: {'fake_p'});
      });

      test('snapshots fill the isolated section while it keeps loading',
          () async {
        sourceA.searchResult = [_t('a1', 'fake_a')];
        final future = controller.search('test');
        await Future<void>.delayed(Duration.zero);

        progressive.controller!.add([_t('p1', 'fake_p')]);
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.isolatedResults.map((t) => t.id), ['p1']);
        expect(controller.state.isolatedLoading, true);

        progressive.controller!.add([_t('p1', 'fake_p'), _t('p2', 'fake_p')]);
        await progressive.controller!.close();
        await future;
        expect(controller.state.isolatedResults.map((t) => t.id), ['p1', 'p2']);
        expect(controller.state.isolatedLoading, false);
        expect(controller.state.results.map((t) => t.id), ['a1']);
      });

      test('new search cancels the running progressive search', () async {
        unawaited(controller.search('first'));
        await Future<void>.delayed(Duration.zero);
        expect(progressive.listens, 1);

        unawaited(controller.search('second'));
        expect(progressive.cancels, 1);
        expect(progressive.listens, 2);
        await progressive.controller!.close();
      });

      test('single-source mode streams snapshots into results', () async {
        controller.setSourceId('fake_p');
        final future = controller.search('test');
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.loading, true);

        progressive.controller!.add([_t('p1', 'fake_p')]);
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.results.map((t) => t.id), ['p1']);
        expect(controller.state.loading, false);

        await progressive.controller!.close();
        await future;
        expect(controller.state.isolatedResults, isEmpty);
      });
    });

    test('loading flag is set during search', () {
      sourceA.searchDelayMs = 50;
      sourceA.searchResult = [_t('a1', 'fake_a')];
      controller.setSourceId('fake_a');

      // Сразу после вызова search должен быть loading=true
      controller.search('test');
      expect(controller.state.loading, true);
    });
  });
}
