import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/providers/global_theme_provider.dart';
import 'package:player/ui/pages/player/mesh_background.dart';

/// Ждёт загрузки шейдера: ввод-вывод и компиляция идут вне fake-async зоны,
/// поэтому реальное время отпускается порциями, пока фон не появится.
Future<void> _load(WidgetTester tester) async {
  for (var i = 0; i < 100 && _meshPaint().evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 20),
        ));
    await tester.pump();
  }
}

/// Отпускает реальное время, чтобы заведомо упавшая загрузка завершилась.
Future<void> _settleFailure(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 50),
      ));
  await tester.pump();
}

Widget _host({bool tickers = true, List<Color>? colors}) {
  return MaterialApp(
    home: TickerMode(
      enabled: tickers,
      child: MeshBackground(colors: colors ?? AppColors.fixed.meshColors),
    ),
  );
}

Finder _meshPaint() => find.descendant(
      of: find.byType(MeshBackground),
      matching: find.byType(CustomPaint),
    );

void main() {
  tearDown(MeshBackground.resetForTesting);

  testWidgets('шейдер грузится и рисует фон', (tester) async {
    await tester.pumpWidget(_host());
    await _load(tester);

    expect(_meshPaint(), findsOneWidget);
    // Кадр с шейдером рисуется без исключений.
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);
  });

  testWidgets('пока шейдер грузится, ничего не рисуется', (tester) async {
    await tester.pumpWidget(_host());

    expect(_meshPaint(), findsNothing);
  });

  testWidgets('ошибка загрузки шейдера: фон не рисуется, без падения',
      (tester) async {
    MeshBackground.loadProgram = () async => throw Exception('no shader');
    await tester.pumpWidget(_host());
    await _settleFailure(tester);

    expect(_meshPaint(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('анимация идёт, пока тикеры включены', (tester) async {
    await tester.pumpWidget(_host());
    await _load(tester);

    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('с выключенным TickerMode тикер не тикает', (tester) async {
    await tester.pumpWidget(_host(tickers: false));
    await _load(tester);
    await tester.pump();

    expect(_meshPaint(), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('смена цветов не перезагружает шейдер',
      (tester) async {
    var loads = 0;
    final load = MeshBackground.loadProgram;
    MeshBackground.loadProgram = () {
      loads++;
      return load();
    };
    await tester.pumpWidget(_host());
    await _load(tester);

    const other = [
      Color(0xFF102040),
      Color(0xFF203050),
      Color(0xFF304060),
      Color(0xFF405070),
    ];
    await tester.pumpWidget(_host(colors: other));
    await tester.pump();

    expect(loads, 1);
    expect(_meshPaint(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('неудачная загрузка кэшируется, повторов нет', (tester) async {
    var loads = 0;
    MeshBackground.loadProgram = () async {
      loads++;
      throw Exception('no shader');
    };
    await tester.pumpWidget(_host());
    await _settleFailure(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_host());
    await _settleFailure(tester);

    expect(loads, 1);
    expect(_meshPaint(), findsNothing);
  });

  testWidgets('размонтирование до конца загрузки не падает', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpWidget(const SizedBox());
    await _settleFailure(tester);
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 200),
        ));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  group('meshBlobCenters', () {
    test('цикл замкнут: в 0 и 2π центры совпадают', () {
      final start = meshBlobCenters(0);
      final end = meshBlobCenters(2 * math.pi);
      for (var i = 0; i < start.length; i++) {
        expect((start[i] - end[i]).distance, lessThan(1e-9));
      }
    });

    test('центры не уходят далеко за экран', () {
      for (var i = 0; i <= 100; i++) {
        for (final c in meshBlobCenters(i / 100 * 2 * math.pi)) {
          expect(c.dx, inInclusiveRange(-0.1, 1.1));
          expect(c.dy, inInclusiveRange(-0.1, 1.1));
        }
      }
    });
  });

  group('advanceMeshPhase', () {
    test('фаза растёт со временем и заворачивается в [0, 2π)', () {
      final next = advanceMeshPhase(1, const Duration(milliseconds: 16));
      expect(next, greaterThan(1));
      final wrapped =
          advanceMeshPhase(2 * math.pi - 1e-6, const Duration(milliseconds: 16));
      expect(wrapped, inInclusiveRange(0, 0.01));
    });

    test('после паузы (свёрнутый плеер) пятна не прыгают', () {
      final afterPause = advanceMeshPhase(1, const Duration(minutes: 5));
      final oneFrame = advanceMeshPhase(1, const Duration(milliseconds: 100));
      expect(afterPause, oneFrame);
    });
  });
}
