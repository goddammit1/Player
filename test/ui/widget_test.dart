// Smoke-С‚РµСЃС‚: РїСЂРѕРІРµСЂСЏРµС‚, С‡С‚Рѕ РіР»Р°РІРЅС‹Рµ РїСЂРѕРІР°Р№РґРµСЂС‹ РёРЅРёС†РёР°Р»РёР·РёСЂСѓСЋС‚СЃСЏ
// Р±РµР· РѕС€РёР±РѕРє. РџРѕР»РЅРѕС†РµРЅРЅС‹Рµ widget-С‚РµСЃС‚С‹ РґРѕР±Р°РІР»СЏСЋС‚СЃСЏ РїРѕ РјРµСЂРµ РїРѕРєСЂС‹С‚РёСЏ UI.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/providers.dart';
import 'package:player/sources/source_registry.dart';

import '../setup/test_harness.dart';

void main() {
  TestHarness.ensureInitialized();

  setUp(() async => await TestHarness.setUpDb());
  tearDown(() async => await TestHarness.tearDownDb());

  test('ProviderScope creates without errors', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // РџСЂРѕРІР°Р№РґРµСЂС‹ РґРѕР»Р¶РЅС‹ СЃРѕР·РґР°РІР°С‚СЊСЃСЏ Р±РµР· РёСЃРєР»СЋС‡РµРЅРёР№.
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
