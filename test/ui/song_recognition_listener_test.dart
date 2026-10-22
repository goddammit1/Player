// Канал MainActivity → Dart для «Find in Player» из уведомления о
// распознанной песне (SongRecognitionListener).
//
// Холодный старт: запрос лежит в MainActivity и забирается через
// takePendingSearch. Приложение уже открыто: MainActivity сам вызывает
// `search`. В обоих случаях запрос должен дойти до поиска ровно один раз.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:player/ui/widgets/song_recognition_listener.dart';

const _channel = MethodChannel('player/song_recognition');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> searches;
  late String? pending;

  setUp(() {
    searches = [];
    pending = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method != 'takePendingSearch') return null;
          final query = pending;
          pending = null;
          return query;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<void> pumpListener(WidgetTester tester, {bool enabled = true}) =>
      tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: SongRecognitionListener(
              enabled: enabled,
              onSearch: searches.add,
              child: const SizedBox(),
            ),
          ),
        ),
      );

  /// Как MainActivity.onNewIntent: native → Dart `search`.
  Future<void> sendSearch(String query) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channel.name,
          _channel.codec.encodeMethodCall(MethodCall('search', query)),
          (_) {},
        );
  }

  testWidgets('cold start: pending query from MainActivity is searched once', (
    tester,
  ) async {
    pending = 'Halsey Gasoline';
    await pumpListener(tester);
    await tester.pump();
    await tester.pump();

    expect(searches, ['Halsey Gasoline']);
  });

  testWidgets('no pending query: nothing is searched', (tester) async {
    await pumpListener(tester);
    await tester.pump();
    await tester.pump();

    expect(searches, isEmpty);
  });

  testWidgets('app already open: native search call is forwarded', (
    tester,
  ) async {
    await pumpListener(tester);
    await tester.pump();

    await sendSearch('Mia Boyka Eksponat');
    await tester.pump();
    await tester.pump();

    expect(searches, ['Mia Boyka Eksponat']);
  });

  testWidgets('disabled (not Android): channel is not touched', (tester) async {
    pending = 'Halsey Gasoline';
    await pumpListener(tester, enabled: false);
    await tester.pump();
    await tester.pump();

    expect(searches, isEmpty);
    expect(pending, 'Halsey Gasoline'); // takePendingSearch не вызывался
  });
}
