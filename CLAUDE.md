# CLAUDE.md

Flutter-плеер (Android основная платформа, Windows рабочая, iOS собирается без
подписи). Возможности, источники, сборка и подпись описаны в [README.md](README.md),
здесь только то, что нужно для работы с кодом.

## Команды

```powershell
flutter analyze                          # должен быть чистым перед коммитом
flutter test                             # live-тесты пропускаются (dart_test.yaml)
flutter test test/sources/soulseek_source_test.dart   # один файл
flutter test --tags live                 # сетевые тесты источников, нужен интернет
tools\run.ps1                            # flutter run с env.json (Android)
tools\run_windows.ps1                    # то же для -d windows
```

Ручной `flutter run`/`flutter build` без `--dart-define-from-file=env.json`
даёт сборку без токена Genius. Release-сборки (`tools\build_release.ps1`,
`tools\build_windows.ps1`) запускать только по просьбе.

## Архитектура

- **Источники**: `TrackSource` в [lib/sources/track_source.dart](lib/sources/track_source.dart),
  регистрация в `SourceRegistry.registerDefaults()`. Медленные источники
  дополнительно реализуют `ProgressiveSearchSource`. YouTube отключён для поиска,
  но остаётся зарегистрированным ради старых треков в плейлистах, не удалять.
- **Стрим-URL временные**: в БД хранятся только метаданные трека, ссылка
  резолвится при воспроизведении. Не сохранять URL в БД.
- **Плеер**: `PlayerServiceFactory` выбирает `PlayerService` (audio_service +
  just_audio, Android/iOS) или `DesktopPlayerService` (just_audio, Windows).
  Общий контракт в `player_service_interface.dart`, менять обе реализации.
- **Состояние**: flutter_riverpod 2.x, `StateNotifier`/`StateNotifierProvider`,
  без кодогенерации. Провайдеры в `lib/core/providers.dart` и `lib/core/providers/`.
- **БД**: sqflite, `AppDatabase` + DAO в `lib/core/database/`. Изменение схемы
  = поднять `dbVersion` и дописать миграцию в `AppDatabaseSchema.upgrade`
  ([database_schema.dart](lib/core/database/database_schema.dart)) плюс тест на
  апгрейд со старой версии.
- **Soulseek** (только Android), три слоя:
  Dart `lib/sources/soulseek_*.dart` → MethodChannel `soulseek/methods` /
  EventChannel (JSON-строки) → Kotlin `android/app/src/main/kotlin/com/player/player/Soulseek*.kt`
  → .NET-обёртка `soulseek-wrapper/` (готовый AAR в `android/app/libs/`).
  Изменение контракта канала правится с обеих сторон, Dart и Kotlin. AAR
  пересобирать (`soulseek-wrapper\build_aar.ps1`) только после правок в C#.

## Тесты

- `test/` зеркалит `lib/`.
- Тесты с БД: `TestHarness.setUpDb()` / `tearDownDb()` из
  [test/setup/test_harness.dart](test/setup/test_harness.dart) (sqflite_common_ffi,
  временный файл).
- HTTP через dio мокается `http_mock_adapter`. Тесты, которым нужна сеть,
  помечаются `@Tags(['live'])`.

## Соглашения

- Комментарии и документация на русском, идентификаторы на английском.
- Коммиты в стиле Conventional Commits со scope: `feat(soulseek): …`,
  `fix(player): …`, `perf(…)`, `build(android): …`, `docs(plans): …`.
- [CHANGELOG.md](CHANGELOG.md) ведётся по Keep a Changelog на русском, записи
  добавляются вместе с фичей/фиксом. Релиз = отдельный коммит
  `chore(release): bump version to X.Y.Z` с версией в `pubspec.yaml`,
  CHANGELOG и строке «Текущая версия» в README.
- **Не запускать `dart format` по папкам**: код не отформатирован под текущий
  `dart format`, и он перепишет большую часть файлов. Форматировать только по просьбе.
- `.ps1` в `tools/` держать ASCII-only: Windows PowerShell 5.1 читает их как ANSI.
- Логи на устройстве: `print` → `adb logcat` (тег `flutter`), с
  `// ignore: avoid_print`. Временную диагностику после замеров убирать.

## Секреты

`env.json` (токен Genius), `android/key.properties`, `android/app/player-release.jks`,
`cookies.txt` в `.gitignore`. Не коммитить, не выводить содержимое, не
подставлять в команды. Шаблон: `env.json.example`.

## Подводные камни

- Сеть Soulseek молча отбрасывает часть запросов (например «lady gaga»): ноль
  ответов от пиров при поиске — не обязательно баг. Обход: wildcard `*ady *aga`.
- `plans/`, `docs/` и `REFACTORING_PLAN.md` — исторические планы, часть уже
  выполнена или устарела (например, `app_database.dart` уже в `lib/core/database/`).
  Сверяться с кодом, а не с планом.
- `experimental_member_use` отключён в `analysis_options.yaml` намеренно:
  используется `LockCachingAudioSource` из just_audio.
