// Юнит-тесты версионной логики UpdateService:
//   1. Semver-компаратор [UpdateService.compareVersions] с поддержкой
//      prerelease-тегов (база требований релиза 3.0.0-beta).
//   2. Детектор бета-релизов [AppRelease.isBeta] по суффиксу версии.
//
// Сетевые вызовы (GitHub API) не затрагиваются: сравнение версий и
// детект isBeta — чистые функции.

import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/update_service.dart';

AppRelease _release(String version) => AppRelease(
      version: version,
      name: 'test',
      notes: 'notes',
      apkUrl: 'https://example.com/app-release.apk',
      pageUrl: 'https://example.com/release',
    );

void main() {
  group('UpdateService.compareVersions', () {
    test('3.0.0-beta > 2.5.2 (бета мажорного релиза старше stable-минора)', () {
      expect(UpdateService.compareVersions('3.0.0-beta', '2.5.2'), greaterThan(0));
    });

    test('3.0.0 > 3.0.0-beta (stable старше своей prerelease-версии)', () {
      expect(UpdateService.compareVersions('3.0.0', '3.0.0-beta'), greaterThan(0));
      expect(UpdateService.compareVersions('3.0.0-beta', '3.0.0'), lessThan(0));
    });

    test('3.0.0-beta.2 > 3.0.0-beta.1 (нумерация бета-итераций)', () {
      expect(
        UpdateService.compareVersions('3.0.0-beta.2', '3.0.0-beta.1'),
        greaterThan(0),
      );
      expect(
        UpdateService.compareVersions('3.0.0-beta.1', '3.0.0-beta.2'),
        lessThan(0),
      );
      expect(UpdateService.compareVersions('3.0.0-beta.2', '3.0.0-beta.2'), 0);
    });

    test('равенство и базовое сравнение stable-версий не изменилось', () {
      expect(UpdateService.compareVersions('2.5.2', '2.5.2'), 0);
      expect(UpdateService.compareVersions('2.6.0', '2.5.2'), greaterThan(0));
      expect(UpdateService.compareVersions('2.5.1', '2.5.2'), lessThan(0));
    });

    test('ведущий «v» и build-метаданные («+31») игнорируются', () {
      expect(UpdateService.compareVersions('v3.0.0-beta', '3.0.0-beta'), 0);
      expect(UpdateService.compareVersions('3.0.0+31', '3.0.0'), 0);
      expect(UpdateService.compareVersions('v3.0.0+31', '3.0.0'), 0);
    });

    test('короткие версии дополняются нулями (3 > 2.5.2, 3.0 = 3.0.0)', () {
      expect(UpdateService.compareVersions('3', '2.5.2'), greaterThan(0));
      expect(UpdateService.compareVersions('3.0', '3.0.0'), 0);
    });
  });

  group('AppRelease.isBeta', () {
    test('детектирует beta-суффиксы манифеста', () {
      expect(_release('3.0.0-beta').isBeta, isTrue);
      expect(_release('3.0.0-b').isBeta, isTrue);
      expect(_release('3.0.0-beta.2').isBeta, isTrue);
      expect(_release('v3.0.0-BETA').isBeta, isTrue); // без учёта регистра
    });

    test('не срабатывает на stable и чужих суффиксах', () {
      expect(_release('3.0.0').isBeta, isFalse);
      expect(_release('2.5.2').isBeta, isFalse);
      expect(_release('3.0.0-rc.1').isBeta, isFalse);
      expect(_release('3.0.0-alpha').isBeta, isFalse);
    });

    test('суффикс «beta» не матчится внутри слов/ревизий', () {
      // «1.0.0-rebeta» — не бета-маркировка, а произвольный тег;
      // «beta» должен быть отдельным сегментом после дефиса.
      expect(_release('1.0.0-rebeta').isBeta, isFalse);
      expect(_release('1.0.0-betaflight').isBeta, isFalse);
    });
  });
}
