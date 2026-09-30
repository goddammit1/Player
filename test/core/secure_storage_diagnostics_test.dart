// Диагностика secure storage (Soulseek → Troubleshooting).
//
// Главный инвариант: отчёт уходит разработчику через мессенджеры, поэтому
// в нём не должно быть значений учётных данных — только факт их наличия.
// Второе: пробный ключ не должен задевать реальные данные, а сбой нативной
// части — ронять сборку отчёта.

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:player/core/secure_storage_diagnostics.dart';
import 'package:player/core/soulseek_credentials.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const username = 'alice_unique_username';
  const password = 'hunter2_unique_password';
  const channel = MethodChannel('player/diagnostics');

  void mockNative(Future<Object?>? Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'soulseek_username': username,
      'soulseek_password': password,
    });
    PackageInfo.setMockInitialValues(
      appName: 'Player',
      packageName: 'com.player.player',
      version: '3.0.1',
      buildNumber: '32',
      buildSignature: '',
    );
  });

  tearDown(() => mockNative(null));

  test('round-trip reports presence of credentials, never their values',
      () async {
    final report = await SoulseekCredentials.diagnosticRoundTrip();

    expect(report, contains('username present, password present'));
    expect(report, contains('[OK]   write probe'));
    expect(report, contains('[OK]   read probe back'));
    expect(report, contains('[OK]   delete probe'));
    expect(report, isNot(contains(username)));
    expect(report, isNot(contains(password)));
  });

  test('probe key is removed and credentials stay intact', () async {
    await SoulseekCredentials.diagnosticRoundTrip();

    final creds = await SoulseekCredentials.load();
    expect(creds?.username, username);
    expect(creds?.password, password);
    expect(
      await const FlutterSecureStorage()
          .containsKey(key: '__diagnostics_probe__'),
      isFalse,
    );
  });

  test('full report includes the native section', () async {
    mockNative((call) async =>
        call.method == 'secureStorageReport' ? '== Device ==\nnative ok' : null);

    final report = await SecureStorageDiagnostics.buildReport();

    expect(report, contains('Version: 3.0.1+32'));
    expect(report, contains('== flutter_secure_storage round-trip =='));
    expect(report, contains('native ok'));
    expect(report, isNot(contains(password)));
  });

  test('native failure is reported instead of thrown', () async {
    mockNative((call) async => throw PlatformException(code: 'boom'));

    final report = await SecureStorageDiagnostics.buildReport();

    expect(report, contains('Native report failed'));
    expect(report, contains('[OK]   write probe'));
  });
}
