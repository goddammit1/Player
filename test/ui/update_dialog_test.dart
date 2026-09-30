// Widget-тесты диалога обновлений (update_dialog.dart):
//   1. Бета-релиз: показывается бейдж «BETA», баннер-предупреждение и
//      кнопка «Скачать и установить (бета)».
//   2. Stable-релиз: бета-маркировка отсутствует, кнопка обычная —
//      поведение для stable не изменилось.
//
// GitHub API подменяется через checkOverride (без сети). Палитра —
// AppColors.fixed, как в остальных UI-тестах проекта.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:player/core/providers/global_theme_provider.dart';
import 'package:player/core/update_service.dart';
import 'package:player/ui/widgets/update_dialog.dart';

UpdateCheckResult _result(AppRelease release) => UpdateCheckResult(
      currentVersion: '2.5.2',
      release: release,
      updateAvailable: true,
    );

AppRelease _release(String version) => AppRelease(
      version: version,
      name: 'Player $version',
      notes: '- Soulseek integration\n- Cache improvements',
      apkUrl: 'https://example.com/app-release.apk',
      pageUrl: 'https://example.com/release',
    );

Future<void> _pumpFlow(
  WidgetTester tester,
  Future<UpdateCheckResult> Function() check,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () =>
                  showUpdateFlow(context, AppColors.fixed, checkOverride: check),
              child: const Text('check'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('check'));
  // Прогоняем: открытие спиннера → await check → переход к диалогу.
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('бета-релиз: бейдж, баннер и кнопка с пометкой (бета)',
      (tester) async {
    await _pumpFlow(tester, () async => _result(_release('3.0.0-beta')));

    expect(find.text('Update 3.0.0-beta'), findsOneWidget);
    // Бейдж «BETA» рядом с версией.
    expect(find.text('BETA'), findsOneWidget);
    // Баннер-предупреждение о бета-статусе.
    expect(
      find.text('Это бета-версия: возможны ошибки и нестабильная работа'),
      findsOneWidget,
    );
    // Контекстная кнопка переименована для беты.
    expect(find.text('Скачать и установить (бета)'), findsOneWidget);
    expect(find.text('Скачать и установить'), findsNothing);
    // Строка установленной версии сохраняется.
    expect(find.text('Installed: 2.5.2'), findsOneWidget);
  });

  testWidgets('stable-релиз: без бета-маркировки, обычная кнопка',
      (tester) async {
    await _pumpFlow(tester, () async => _result(_release('2.6.0')));

    expect(find.text('Update 2.6.0'), findsOneWidget);
    expect(find.text('BETA'), findsNothing);
    expect(
      find.text('Это бета-версия: возможны ошибки и нестабильная работа'),
      findsNothing,
    );
    expect(find.text('Скачать и установить'), findsOneWidget);
    expect(find.text('Скачать и установить (бета)'), findsNothing);
  });

  testWidgets('нет обновления: диалог «You are up to date» без бета-элементов',
      (tester) async {
    await _pumpFlow(
      tester,
      () async => UpdateCheckResult(
        currentVersion: '2.5.2',
        release: _release('2.5.2'),
        updateAvailable: false,
      ),
    );

    expect(find.text('You are up to date'), findsOneWidget);
    expect(find.text('BETA'), findsNothing);
  });
}
