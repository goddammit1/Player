// Юнит-тесты UpdateService:
//   1. Semver-компаратор [UpdateService.compareVersions] с поддержкой
//      prerelease-тегов (база требований релиза 3.0.0-beta).
//   2. Детектор бета-релизов [AppRelease.isBeta] по суффиксу версии.
//   3. Обнаружение релизов: список /releases (включая помеченные
//      GitHub-флагом prerelease) вместо releases/latest, который их
//      скрывает — регрессия бага «3.0.0-beta не виден апдейтером».
//
// Сеть подменяется mock-Dio (http_mock_adapter): реальный GitHub API
// не затрагивается; сравнение версий и isBeta — чистые функции.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:player/core/update_service.dart';

AppRelease _release(String version) => AppRelease(
      version: version,
      name: 'test',
      notes: 'notes',
      apkUrl: 'https://example.com/app-release.apk',
      pageUrl: 'https://example.com/release',
    );

void _mockPackageInfo(String version) {
  PackageInfo.setMockInitialValues(
    appName: 'Player',
    packageName: 'com.player.player',
    version: version,
    buildNumber: '30',
    buildSignature: '',
  );
}

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

  group('UpdateService.check (list endpoint)', () {
    late Dio dio;
    late DioAdapter adapter;

    setUp(() {
      dio = Dio();
      adapter = DioAdapter(dio: dio);
      UpdateService.setDioForTesting(dio);
      _mockPackageInfo('2.5.2');
    });

    tearDown(() {
      UpdateService.setDioForTesting(null);
    });

    Map<String, dynamic> ghRelease({
      required String tag,
      String name = '',
      String body = '',
      bool draft = false,
      bool prerelease = false,
      List<Map<String, Object>> assets = const [],
    }) =>
        {
          'tag_name': tag,
          'name': name,
          'body': body,
          'draft': draft,
          'prerelease': prerelease,
          'html_url': 'https://github.com/goddammit1/Player/releases/tag/$tag',
          'assets': assets,
        };

    Map<String, Object> apkAsset([String name = 'app-release.apk']) => {
          'name': name,
          'browser_download_url':
              'https://github.com/goddammit1/Player/releases/download/x/$name',
        };

    test('дёргает список /releases, а не releases/latest', () async {
      adapter.onGet(
        'https://api.github.com/repos/goddammit1/Player/releases?per_page=10',
        (server) => server.reply(200, [
          ghRelease(
            tag: 'v3.0.0-beta',
            prerelease: true,
            assets: [apkAsset()],
          ),
        ]),
      );
      // Если бы сервис ходил в releases/latest — мок не ответил бы на этот
      // путь и тест упал бы по DioException (no route was found).
      final result = await UpdateService.check();
      expect(result.release.version, '3.0.0-beta');
    });

    test('prerelease-релиз из списка виден апдейтеру', () async {
      adapter.onGet(
        'https://api.github.com/repos/goddammit1/Player/releases?per_page=10',
        (server) => server.reply(200, [
          ghRelease(
            tag: 'v3.0.0-beta',
            name: '3.0.0-beta',
            body: 'beta notes',
            prerelease: true,
            assets: [apkAsset()],
          ),
          ghRelease(tag: 'v2.5.2', assets: [apkAsset()]),
        ]),
      );

      final result = await UpdateService.check();
      expect(result.currentVersion, '2.5.2');
      expect(result.updateAvailable, isTrue);
      expect(result.release.version, '3.0.0-beta');
      expect(result.release.isBeta, isTrue);
      expect(result.release.notes, 'beta notes');
      expect(
        result.release.apkUrl,
        'https://github.com/goddammit1/Player/releases/download/x/app-release.apk',
      );
      expect(
        result.release.pageUrl,
        'https://github.com/goddammit1/Player/releases/tag/v3.0.0-beta',
      );
    });

    test('draft-релизы пропускаются, берётся свежий не-draft', () async {
      adapter.onGet(
        'https://api.github.com/repos/goddammit1/Player/releases?per_page=10',
        (server) => server.reply(200, [
          ghRelease(
            tag: 'v3.1.0-draft',
            draft: true,
            assets: [apkAsset()],
          ),
          ghRelease(tag: 'v3.0.0-beta', prerelease: true, assets: [apkAsset()]),
        ]),
      );

      final result = await UpdateService.check();
      expect(result.release.version, '3.0.0-beta');
    });

    test('пустой список — прежнее поведение ошибки', () async {
      adapter.onGet(
        'https://api.github.com/repos/goddammit1/Player/releases?per_page=10',
        (server) => server.reply(200, <Map<String, dynamic>>[]),
      );

      expect(
        () => UpdateService.check(),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('no published releases'),
        )),
      );
    });

    test('ассет с другим именем не берётся', () async {
      adapter.onGet(
        'https://api.github.com/repos/goddammit1/Player/releases?per_page=10',
        (server) => server.reply(200, [
          ghRelease(
            tag: 'v3.0.0-beta',
            prerelease: true,
            assets: [apkAsset('player-windows-x64.zip')],
          ),
        ]),
      );

      expect(
        () => UpdateService.check(),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('app-release.apk'),
        )),
      );
    });
  });
}
