// Smoke-тест: проверяет, что главные провайдеры инициализируются
// без ошибок. Полноценные widget-тесты добавляются по мере покрытия UI.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/providers.dart';
import 'package:player/sources/source_registry.dart';

import 'setup/test_harness.dart';

void main() {
  TestHarness.ensureInitialized();

  setUp(() async => await TestHarness.setUpDb());
  tearDown(() async => await TestHarness.tearDownDb());

  test('ProviderScope creates without errors', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Провайдеры должны создаваться без исключений.
    expect(() => container.read(searchProvider), returnsNormally);
    expect(() => container.read(searchHistoryProvider), returnsNormally);
  });

  test('SourceRegistry registerDefaults has all sources', () {
    SourceRegistry.instance.registerDefaults();
    addTearDown(() async => await SourceRegistry.instance.disposeAll());

    expect(SourceRegistry.instance.all.length, 3);
    expect(SourceRegistry.instance.require('youtube').id, 'youtube');
    expect(SourceRegistry.instance.require('muzmo').id, 'muzmo');
    expect(SourceRegistry.instance.require('soundcloud').id, 'soundcloud');
  });
}
