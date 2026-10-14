@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/sources/soulseek_desktop/soulseek_native_bridge.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('soulseek_bridge_test');
    // Пустые файлы: isInstalled == true, но hostfxr.dll не загрузится.
    File('${dir.path}/soulseek-desktop.dll').writeAsBytesSync(const []);
    File('${dir.path}/hostfxr.dll').writeAsBytesSync(const []);
  });

  tearDown(() => dir.delete(recursive: true));

  test('runtime start runs in an isolate without capturing the bridge',
      () async {
    final bridge = SoulseekNativeBridge(directory: dir.path);
    // Как DesktopSoulseekChannel: подписчик событий держит живые Future —
    // если замыкание Isolate.run захватит мост, отправка в изолят упадёт.
    final pending = Completer<void>();
    final sub = bridge.events.listen((_) => pending.complete());
    addTearDown(sub.cancel);

    Object? error;
    try {
      await bridge.call('connect', '{}');
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull);
    expect(error.toString(), isNot(contains('unsendable')));
    expect(error.toString(), contains('hostfxr'));
  });
}
