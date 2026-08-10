import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/providers.dart';
import 'package:player/models/track.dart';

/// Unit-тесты SearchController / SearchState (чистый Dart, без Flutter binding).
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
}
