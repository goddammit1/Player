# Player

Музыкальный плеер на Flutter: поиск и стриминг треков с нескольких площадок,
плейлисты, история и офлайн-кэш. Проект для личного использования.

Текущая версия: **3.1.0** · история изменений в [CHANGELOG.md](CHANGELOG.md).

## Возможности

- Поиск по всем источникам сразу или по одному. Результаты приходят по мере
  готовности, медленный Soulseek выводится отдельной секцией.
- Плейлисты с ручной сортировкой, история прослушивания, история поиска.
- Импорт и экспорт плейлистов в JSON.
- Офлайн-кэш аудио с лимитом по размеру и кэширование плейлиста целиком.
- Обложки: от источника, через Genius API или iTunes, плюс свои обложки.
- Динамическая цветовая схема по обложке, светлая и тёмная темы.
- Фоновое воспроизведение и управление с экрана блокировки на мобильных.
- Очередь, таймер сна, детали трека (битрейт, источник, качество).
- Проверка обновлений через GitHub Releases, включая бета-релизы.

## Платформы

| Платформа | Статус | Особенности |
|-----------|--------|-------------|
| Android   | основная | `audio_service`, уведомления, Soulseek |
| Windows   | рабочая  | десктопный UI, `just_audio_windows` |
| iOS       | сборка без подписи | собирается в Codemagic, Soulseek недоступен |

Логика (источники, репозитории, плеер) общая. Различаются UI и реализация
плеера: на мобильных `PlayerService` (audio_service + just_audio), на
десктопе `DesktopPlayerService` (только just_audio). Выбор делает
`PlayerServiceFactory`.

## Источники

| Источник | Поиск | Как работает |
|----------|:-----:|--------------|
| Muzmo (`rmr.muzmo.cc`) | да | HTML-парсинг выдачи, прямой MP3 320 kbps |
| SoundCloud | да | публичный API `api-v2`, `client_id` берётся из JS-бандлов сайта |
| Soulseek | по флагу | P2P через нативную обёртку над Soulseek.NET, только Android |
| YouTube | нет | отключён: `youtube_explode_dart` не проходит проверку PoToken |

YouTube остаётся зарегистрированным, чтобы старые треки в плейлистах не
ломали загрузку. Soulseek включается в настройках и требует учётную запись
Soulseek.

Стрим-URL временные, поэтому в БД хранятся только метаданные трека, а
ссылка получается при воспроизведении.

### Добавление источника

Источник реализует `TrackSource` ([track_source.dart](lib/sources/track_source.dart))
и регистрируется в `SourceRegistry.registerDefaults()`
([source_registry.dart](lib/sources/source_registry.dart)):

```dart
abstract class TrackSource {
  String get id;
  String get displayName;
  Future<List<Track>> search(String query, {int limit = 20});
  Future<String> resolveStreamUrl(Track track);
  // createAudioSource, prefetch, resolveBitrate, resolveArtwork, dispose
  // имеют реализации по умолчанию
}
```

Для потоковой выдачи источник дополнительно реализует `ProgressiveSearchSource`.

## Обложки

Muzmo и Soulseek обложек не отдают, их ищет `ArtworkProvider`:

1. **Genius API** — основной поиск, нужен токен (см. ниже).
2. **iTunes Search API** — запасной вариант без токена.

Метки версий в скобках (`(Remix)`, `[Slowed + Reverb]`) уходят в запрос, чтобы
найти обложку именно этой версии. Результаты кэшируются в памяти и SQLite с
TTL 7 дней. Обложки ищутся лениво, когда плитка появляется на экране. Найденная
обложка применяется к треку сразу в плейлистах и в истории.

## Быстрый старт

Нужны Flutter (stable, Dart ≥ 3.11) и Android SDK. Для Windows-сборки ещё
Visual Studio Build Tools 2022 с Windows 10/11 SDK.

1. Скопировать `env.json.example` в `env.json` (файл в `.gitignore`) и вписать
   токен Genius:

   ```json
   { "GENIUS_TOKEN": "<Client Access Token>" }
   ```

   Нужен именно **Client Access Token** со страницы
   <https://genius.com/api-clients>, не Client Secret. Без токена Genius
   пропускается и работает только iTunes.

2. Установить зависимости:

   ```bash
   flutter pub get
   ```

3. Запустить или собрать через скрипты из `tools/`. Они сами передают
   `--dart-define-from-file=env.json`:

   | Команда | Что делает |
   |---------|------------|
   | `tools\run.ps1` | `flutter run`, аргументы пробрасываются (`-d windows` и т.п.) |
   | `tools\build_release.ps1` | release APK, падает при пустом токене |
   | `tools\install_release.ps1` | установка собранного APK на устройство |
   | `tools\build_windows.ps1 [-Zip]` | release-сборка `player.exe`, опционально zip |
   | `tools\backup_keystore.ps1` | резервная копия ключа подписи |

   В VS Code конфигурации из `.vscode/launch.json` уже передают `env.json`.
   При ручном запуске флаг указывается явно:

   ```bash
   flutter run --dart-define-from-file=env.json
   ```

### Тесты

```bash
flutter test
```

## Soulseek-обёртка

Нативная часть Soulseek лежит в [`soulseek-wrapper/`](soulseek-wrapper): C#-проект
поверх Soulseek.NET, который собирается в `android/app/libs/soulseek-wrapper.aar`.
Готовый AAR лежит в репозитории, пересобирать его нужно только после изменений
в обёртке. Требуются .NET 9 SDK и workload `android`:

```powershell
soulseek-wrapper\build_aar.ps1                     # Release, arm64-v8a
soulseek-wrapper\build_aar.ps1 -Abis arm64-v8a,x64 # с эмулятором x86_64
```

Kotlin-слой (плагин, foreground service, загрузки, кэш) находится в
`android/app/src/main/kotlin/com/player/player/Soulseek*.kt`, Dart-API в `lib/sources/soulseek_*.dart`.

## Подпись Android

Release APK подписывается постоянным ключом из `android/key.properties`.
Этот файл и keystore исключены из git.

```
android/app/player-release.jks
android/key.properties
```

```properties
storePassword=<пароль>
keyPassword=<пароль>
keyAlias=player
storeFile=app/player-release.jks
```

Создание ключа (один раз):

```bash
keytool -genkeypair -v -keystore android/app/player-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias player
```

Потеря ключа означает, что обновить уже установленное приложение не получится:
APK с другой подписью Android поверх не ставит. После создания ключа сделайте
копию через `tools\backup_keystore.ps1` (сохраняет в
`Documents\Player-Keystore-Backup\<дата>`).

Play Protect может пометить локально собранный самоподписанный APK как
«высокий риск». Для установки временно отключите сканирование в
Play Маркет → Play Protect → настройки, установите APK и включите обратно.

## Релизы и CI

- **Android / Windows** — собираются локально, APK публикуется в
  [GitHub Releases](https://github.com/goddammit1/Player/releases).
  Приложение проверяет релизы через GitHub API. Теги с суффиксом `-beta`
  считаются бета-версиями.
- **iOS** — [codemagic.yaml](codemagic.yaml), запускается пушем тега `ios-*`,
  собирает `Runner.app` без подписи. `GENIUS_TOKEN` задаётся в Codemagic:
  App settings → Environment variables → группа `player_credentials`.

## Структура

```
lib/
├── main.dart          инициализация и выбор корня (HomePage / DesktopShell)
├── core/              плеер, провайдеры Riverpod, кэш, обновления
│   ├── database/      SQLite: схема и DAO
│   ├── repositories/  плейлисты и история
│   ├── providers/     тема и цветовая схема
│   ├── platform/      десктопный плеер, фабрика, хаптика
│   └── backup/        импорт и экспорт плейлистов
├── models/            Track, Playlist
├── search/            контроллер поиска по источникам
├── sources/           источники, реестр, ArtworkProvider, Soulseek-канал
└── ui/
    ├── pages/         мобильные экраны
    ├── widgets/       общие виджеты и шторки
    └── desktop/       десктопная оболочка, панель плеера, очередь
test/                  тесты (зеркалят структуру lib/)
tools/                 скрипты запуска, сборки и установки
soulseek-wrapper/      .NET-обёртка Soulseek для Android
plans/, docs/          планы и заметки по отдельным задачам
```

## Лицензия

Проект для личного использования, лицензия на код не выдаётся.
Soulseek.NET и обёртка в `soulseek-wrapper/` распространяются под GPLv3,
подробности в [`soulseek-wrapper/THIRD_PARTY_NOTICES.md`](soulseek-wrapper/THIRD_PARTY_NOTICES.md).
