import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/providers/appearance_provider.dart';
import 'package:player/core/providers/global_theme_provider.dart';
import 'package:player/ui/pages/player/mesh_background.dart';
import 'package:player/ui/pages/player/player_background.dart';

/// PNG 8×8, залитый одним цветом.
Future<MemoryImage> _png(WidgetTester tester) async {
  final bytes = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 8, 8),
      Paint()..color = const Color(0xFFFF8A1E),
    );
    final image = await recorder.endRecording().toImage(8, 8);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return png!.buffer.asUint8List();
  });
  return MemoryImage(bytes!);
}

/// Даёт картинкам декодироваться (декодер работает вне fake-async зоны).
Future<void> _decode(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 100),
      ));
  await tester.pump();
}

Widget _host(
  PlayerBackgroundStyle style, {
  ImageProvider? artwork,
  bool animate = true,
}) {
  return MaterialApp(
    home: PlayerBackground(
      style: style,
      colors: AppColors.fixed,
      artwork: artwork,
      animate: animate,
      child: const _Content(),
    ),
  );
}

class _Content extends StatefulWidget {
  const _Content();

  @override
  State<_Content> createState() => _ContentState();
}

class _ContentState extends State<_Content> {
  @override
  Widget build(BuildContext context) => const Text('content');
}

Finder _gradient() => find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).gradient is LinearGradient,
    );

/// Затемнение поверх обложки.
Finder _scrim() => find.byWidgetPredicate(
      (w) => w is ColoredBox && w.color.a > 0 && w.color.r == 0,
    );

void main() {
  testWidgets('gradient: градиент из палитры, без обложки', (tester) async {
    await tester.pumpWidget(_host(PlayerBackgroundStyle.gradient));

    expect(_gradient(), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets('blur: размытая уменьшенная обложка с затемнением',
      (tester) async {
    final artwork = await _png(tester);
    await tester.pumpWidget(
      _host(PlayerBackgroundStyle.blur, artwork: artwork),
    );
    await _decode(tester);

    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(_scrim(), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<ResizeImage>());
    expect((image.image as ResizeImage).width, lessThanOrEqualTo(64));
    expect(image.fit, BoxFit.cover);
    // Градиент остаётся подложкой.
    expect(_gradient(), findsOneWidget);
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets('blur: пока обложка не загрузилась, затемнения нет',
      (tester) async {
    final artwork = await _png(tester);
    await tester.pumpWidget(
      _host(PlayerBackgroundStyle.blur, artwork: artwork),
    );

    expect(_scrim(), findsNothing);
    expect(_gradient(), findsOneWidget);
  });

  testWidgets('blur: битая обложка оставляет чистый градиент', (tester) async {
    final broken = MemoryImage(Uint8List.fromList([1, 2, 3, 4]));
    await tester.pumpWidget(_host(PlayerBackgroundStyle.blur, artwork: broken));
    await _decode(tester);

    expect(_scrim(), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(_gradient(), findsOneWidget);
  });

  testWidgets('blur без обложки падает на градиент', (tester) async {
    await tester.pumpWidget(_host(PlayerBackgroundStyle.blur));

    expect(_gradient(), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('blur: смена обложки идёт плавно через AnimatedSwitcher',
      (tester) async {
    final first = await _png(tester);
    await tester.pumpWidget(_host(PlayerBackgroundStyle.blur, artwork: first));

    final second = MemoryImage(Uint8List.fromList(first.bytes));
    await tester.pumpWidget(_host(PlayerBackgroundStyle.blur, artwork: second));
    await tester.pump(const Duration(milliseconds: 500));

    // Посередине перехода на экране обе обложки.
    expect(find.byType(Image), findsNWidgets(2));

    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('blur: та же обложка новым объектом не запускает переход',
      (tester) async {
    final first = await _png(tester);
    await tester.pumpWidget(_host(PlayerBackgroundStyle.blur, artwork: first));

    final same = MemoryImage(first.bytes);
    await tester.pumpWidget(_host(PlayerBackgroundStyle.blur, artwork: same));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('свёрнутый плеер: смена обложек мгновенная, слои не копятся',
      (tester) async {
    final first = await _png(tester);
    await tester.pumpWidget(
      _host(PlayerBackgroundStyle.blur, artwork: first, animate: false),
    );
    for (var i = 0; i < 3; i++) {
      final next = MemoryImage(Uint8List.fromList(first.bytes));
      await tester.pumpWidget(
        _host(PlayerBackgroundStyle.blur, artwork: next, animate: false),
      );
      await tester.pump();
    }

    expect(find.byType(Image), findsOneWidget);
    // Анимации контента не глушатся.
    expect(
      TickerMode.valuesOf(tester.element(find.byType(_Content))).enabled,
      isTrue,
    );
  });

  testWidgets('контент не пересоздаётся при смене обложки и стиля',
      (tester) async {
    final artwork = await _png(tester);
    await tester.pumpWidget(_host(PlayerBackgroundStyle.gradient));
    final state = tester.state(find.byType(_Content));

    await tester.pumpWidget(_host(PlayerBackgroundStyle.blur, artwork: artwork));
    await tester.pumpWidget(_host(PlayerBackgroundStyle.blur));
    await tester.pumpAndSettle();

    expect(tester.state(find.byType(_Content)), same(state));
  });

  testWidgets('mesh: шейдер поверх градиента из цветов палитры',
      (tester) async {
    await tester.pumpWidget(_host(PlayerBackgroundStyle.mesh));

    final mesh = tester.widget<MeshBackground>(find.byType(MeshBackground));
    expect(mesh.colors, AppColors.fixed.meshColors);
    expect(_gradient(), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('mesh: в свёрнутом плеере тикер шейдера стоит', (tester) async {
    await tester.pumpWidget(
      _host(PlayerBackgroundStyle.mesh, animate: false),
    );

    expect(
      TickerMode.valuesOf(tester.element(find.byType(MeshBackground))).enabled,
      isFalse,
    );
  });
}
