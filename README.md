# Player

Музыкальный плеер с поиском и стримингом треков с разных площадок.
Только для личного использования.

Поддерживаемые платформы:

- **Android / iOS** — мобильный UI (полноэкранный плеер, мини-плеер-оверлей, lock-screen контролы)
- **Windows / Linux / macOS** — десктопный UI (боковая навигация + контент + панель плеера снизу)

Логика (провайдеры, репозитории, источники, плеер) общая; отличается
только слой UI и реализация плеера.

## Стек

- **Flutter** (Android + iOS + Windows + Linux + macOS)
- **just_audio** + **audio_service** — воспроизведение, фон, lock-screen контролы (мобильные)
- **just_audio_windows** — нативная Windows-реализация для just_audio
- **sqflite_common_ffi** + **sqlite3_flutter_libs** — SQLite на десктопе
- **youtube_explode_dart** — парсинг YouTube
- **dio** + **dio_cookie_manager** + **cookie_jar** + **html** — парсинг
  HTML-источников (Muzmo, SoundCloud)
- **flutter_riverpod** — state management
- **sqflite** — локальная БД (библиотека / история / плейлисты)
- **shared_preferences** — кэш URL обложек и мелких настроек
- **path_provider** — офлайн-кэш аудио
- **cached_network_image** — кэширование обложек в UI
- **palette_generator** + **flutter_color_models** + **dynamic_colors** —
  генерация цветовой схемы из обложек
- **blur** + **figma_squircle** — визуальные эффекты
- **vibration** — тактильная отдача
- **permission_handler** — запросы разрешений
- **package_info_plus** — версия приложения (для автообновлений)
- **share_plus** + **file_picker** — импорт/экспорт плейлистов
- **uuid** — генерация ID плейлистов
- **rxdart** — реактивные потоки
- **marquee** — бегущая строка (длинные названия)

## Архитектура

```
lib/
├── main.dart                          выбор реализации плеера + root (моб. UI / DesktopShell)
├── core/
│   ├── player_service_interface.dart  общий контракт PlayerServiceInterface
│   ├── player_service.dart            мобильная реализация (audio_service + just_audio)
│   ├── player_service_desktop.dart    десктопная реализация (чистый just_audio)
│   ├── providers.dart                 Riverpod-провайдеры (плеер, поиск, UI)
│   ├── appearance_provider.dart       провайдер темы (светлая / тёмная / система)
│   ├── global_theme_provider.dart     генерация цветовой схемы из обложек
│   ├── dynamic_colors.dart            вычисление DynamicScheme (Material You)
│   ├── history_repository.dart        история прослушивания (SQLite)
│   ├── playlist_repository.dart       CRUD плейлистов (SQLite)
│   ├── playlist_backup.dart           импорт/экспорт плейлистов (JSON)
│   ├── update_service.dart            проверка обновлений (GitHub Releases)
│   ├── youtube_cache.dart             LRU-кэш скачанных треков (5 шт.)
│   ├── artwork_helper.dart            хелперы обложек (дефолтные иконки)
│   └── haptic_helper.dart             утилиты для тактильной отдачи
├── models/
│   ├── track.dart                     унифицированная модель трека
│   └── playlist.dart                  модель плейлиста
├── sources/                           ← плагинная система источников
│   ├── track_source.dart              интерфейс
│   ├── source_registry.dart           реестр
│   ├── youtube_source.dart            реализация для YouTube
│   ├── muzmo_source.dart              реализация для rmr.muzmo.cc
│   ├── soundcloud_source.dart         реализация для SoundCloud
│   └── artwork_provider.dart          обложки: Genius API + iTunes fallback
└── ui/
    ├── pages/                         ← мобильный UI (Android/iOS)
    │   ├── home_page.dart             главный экран
    │   ├── search_page.dart           поиск по источникам
    │   ├── player_page.dart           полноэкранный плеер
    │   ├── playlist_page.dart         содержимое плейлиста
    │   ├── history_page.dart          история прослушивания
    │   ├── settings_page.dart         настройки
    │   └── cache_page.dart            управление кэшем
    ├── widgets/
    │   ├── now_playing_overlay.dart   мини-плеер поверх контента (моб.)
    │   ├── desktop_layout.dart        isDesktop + адаптивные хелперы
    │   ├── artwork.dart               виджет обложки с эффектами
    │   ├── queue_sheet.dart           очередь воспроизведения
    │   ├── track_details_sheet.dart   детали трека (битрейт, источник)
    │   ├── track_settings_sheet.dart  настройки конкретного трека
    │   ├── add_to_playlist_sheet.dart добавление трека в плейлист
    │   ├── update_dialog.dart         диалог обновления приложения
    │   └── snack.dart                 снек-бары
    └── desktop/                       ← десктопный UI (Windows/Linux/macOS)
        ├── desktop_shell.dart         каркас: боковая панель + контент + плеер
        ├── desktop_home_page.dart     главная: сетка плейлистов
        └── desktop_player_bar.dart    нижняя панель плеера (прогресс, управление)
```

### Разделение UI по платформам

Корень выбирается в `lib/main.dart` по `isDesktop` (см. `desktop_layout.dart`):

```dart
home: isDesktop
    ? const DesktopShell()   // Windows/Linux/macOS
    : const HomePage(),      // Android/iOS
```

- Мобильные страницы (`ui/pages/`) остаются нетронутыми и не знают о десктопе.
- Десктопный `DesktopShell` переиспользует мобильные страницы (Search, History,
  Settings, Cache) как разделы `IndexedStack` — состояние сохраняется при
  переключении. Плейлист открывается в собственном стеке контента
  (внутри окна), а не через `Navigator.push` поверх всей раскладки.
- Страницам, встроенным в shell, отключается встроенный мини-плеер
  (`showNowPlayingOverlay: false`), т.к. свою панель рисует
  `DesktopPlayerBar` внизу окна — иначе были бы две панели.
- Реализации плеера тоже две, выбор в `main.dart`:
  `Platform.isAndroid || Platform.isIOS` → `PlayerService`
  (audio_service, фоновые уведомления), иначе → `DesktopPlayerService`
  (чистый just_audio, без audio_service).
- Десктопные экраны докручиваются независимо: сетка плейлистов
  (`desktop_home_page.dart`), панель плеера (`desktop_player_bar.dart`),
  клавиатурные шорткаты — без риска сломать мобильную вёрстку.

### Идея плагинной системы

Любая новая площадка реализует интерфейс `TrackSource`:

```dart
abstract class TrackSource {
  String get id;
  String get displayName;
  Future<List<Track>> search(String query, {int limit});
  Future<String> resolveStreamUrl(Track track);
}
```

И регистрируется в `SourceRegistry`:

```dart
SourceRegistry.instance.register(SoundCloudSource());
```

Плеер работает с любым источником одинаково — берёт трек, спрашивает у его
источника прямую ссылку и проигрывает через `just_audio`.

## Источники

### YouTube
Поиск и стрим — через `youtube_explode_dart` (Android VR client).
Кэш скачанного аудио — `youtube_cache.dart` (LRU на 5 треков).

### Muzmo (`rmr.muzmo.cc`)
Поиск парсится из HTML страницы `/search?q=...`:
блоки `<div class="item-song">` содержат `data-file` — прямой mp3 (320kbps),
который играется обычным HTTP-клиентом, без HLS и подписей.
Сессионная кука `sid` подхватывается автоматически (`CookieManager`).

Обложек Muzmo не отдаёт, поэтому они подгружаются через `ArtworkProvider`.

### SoundCloud
Поиск и стриминг через публичный API `api-v2.soundcloud.com`. `client_id`
извлекается из JS-бандлов главной страницы автоматически. Используется
progressive-транскодинг (прямой MP3). Обложки берутся напрямую с
`sndcdn.com`, Genius/iTunes используется только как фолбэк.

## Обложки (ArtworkProvider)

1. **SoundCloud / YouTube** — отдают обложки сами, `ArtworkProvider` не нужен.
2. Для Muzmo и треков без обложек:
   - **Genius API** — основной источник. Нужен Client Access Token,
     получается на https://genius.com/api-clients.
   - **iTunes Search API** — fallback, бесплатный, без токена,
     покрывает то, что Genius не нашёл (русская музыка, ремиксы).
3. **Хинты из скобок**: всё, что в скобках (круглых или квадратных) после
   названия трека, отправляется в поисковый запрос как хинт версии —
   например `(Remix)`, `(Club Mix | Extended Mix)`, `[Slowed + Reverb]`,
   `(Original Mix)`, `(Radio Edit)`. Это помогает Genius/iTunes найти
   именно версию трека, а не оригинал. Пропускаются только заведомо
   не-версионные метки: `feat/ft`, `prod. by`, `official video/audio`,
   `клип`, `lyric video`, `explicit/clean`. Если поиск с хинтами пуст,
   делается retry «без хинтов», а для кириллицы — fallback по артисту.
   Важно: если искалась конкретная версия, страница оригинала на Genius
   (с обложкой альбома, в котором есть трек) не используется — версия
   получает обложку только со своей страницы Genius или через iTunes
   fallback.
4. Результаты кэшируются в RAM и в SQLite, поэтому повторные поиски не
   дёргают сеть. Найденные URL имеют TTL (`foundUrlTtl`, 7 дней): по
   истечении срока URL считается устаревшим, и следующий запрос лениво
   перезапрашивает Genius/iTunes — так подхватывается смена обложки на
   стороне Genius. Если нового URL нет или сеть недоступна, устаревший URL
   используется как запасной, пока TTL не обновится.
5. **Авто-обновление в плейлистах и истории**: при каждом старте приложения
   `PlaylistRepository._refreshArtworkCandidates()` и
   `HistoryRepository._refreshArtworkCandidates()` (для истории — так же, как
   для плейлистов) перезапрашивают обложки для треков без обложки и для
   **провайдерских** обложек (Genius/iTunes), у которых истёк TTL — т.е.
   обложки, изменённые на стороне Genius/iTunes, подхватываются автоматически,
   без ручной очистки кэша. Дополнительно исправляется **рассинхрон**: если
   в кэше провайдера лежит свежий URL, отличающийся от хранимого в
   плейлисте/истории, он обновляется без запроса сети. Обложки, которые дал
   сам источник (SoundCloud/YouTube), и кастомные обложки пользователя не
   трогаются. Операция фоновая и ограничена (`_maxEnrichPerLoad`, семафор) —
   старт приложения не превращается в сетевой шторм.
6. **Одна обложка на трек во всём приложении**: любой найденный URL
   кросс-пропагируется между плейлистами и историей прослушивания
   (`PlaylistRepository._applyArtworkUpdates` ↔ `HistoryRepository._applyArtworkUpdates`),
   поэтому один и тот же трек показывает одну и ту же самую актуальную
   обложку в плейлистах, в истории, в очереди и на экране плеера.
   Обновления идемпотентны, циклического «пинг-понга» нет.
7. **Очистка кэша обложек** (CachePage) теперь сбрасывает и кэш найденных
   URL (`ArtworkProvider.clearCache()`: RAM + SQLite), и `artworkUrl` у
   провайдерских обложек **и в плейлистах, и в истории** (`resetAllTrackArtworks`
   у обоих репозиториев), после чего фоновая дозагрузка перезапрашивает
   Genius/iTunes заново — так подхватывается самая свежая обложка на стороне
   провайдера.

Токен Genius задаётся при сборке через `--dart-define-from-file=env.json`.
**ВАЖНО**: нужен именно **Client Access Token** (со страницы
https://genius.com/api-clients), а НЕ Client Secret. Код шлёт его в
заголовке `Authorization: Bearer <token>`.

Настройка (один раз):

1. Скопируй `env.json.example` в `env.json` (файл в `.gitignore`, в git
   не попадает).
2. Вставь токен в `env.json`:

```json
{
  "GENIUS_TOKEN": "<твой_Client_Access_Token>"
}
```

Дальше токен подставляется автоматически:

```powershell
# debug / запуск (аргументы пробрасываются в flutter run)
tools\run.ps1

# release APK — скрипт сам добавит токен и упадёт с ошибкой, если он пуст
tools\build_release.ps1
```

Запуск по F5 из VS Code тоже работает: конфигурации в `.vscode/launch.json`
уже передают `--dart-define-from-file=env.json`.

Если собираешь вручную — флаг нужно указывать самому:

```bash
flutter run --dart-define-from-file=env.json
flutter build apk --release --dart-define-from-file=env.json
```

Если токен не указан или неверный, Genius тихо пропускается и
используется только iTunes-фолбэк. В debug-режиме при ошибке
авторизации (401/403) в логи пишется предупреждение.

Примечание про кэш: результаты («нашли»/«не нашли») кэшируются в
SQLite. Префикс ключа зависит от наличия токена, поэтому
после добавления токена негативные результаты, накопленные без него,
больше не блокируют повторный поиск через Genius.

## Запуск

```bash
flutter pub get
tools\run.ps1            # запуск на Android-устройстве/эмуляторе (токен из env.json)
tools\build_release.ps1  # релизный APK (токен из env.json)
```

Для Windows (нужны Visual Studio Build Tools 2022 и Windows 10/11 SDK):

```bash
tools\run.ps1 -d windows     # запуск десктопной сборки в debug (токен из env.json)
tools\build_windows.ps1      # релизная Windows-сборка player.exe (токен из env.json)
tools\build_windows.ps1 -Zip # дополнительно упакует Release-папку в build\player-windows-x64.zip
```

Для iOS:

```bash
flutter pub get
cd ios && pod install && cd ..
flutter run -d ios --dart-define-from-file=env.json
```

## CI/CD (Codemagic)

iOS-сборка настроена через `codemagic.yaml`. Триггер — пуш тега вида `ios-*`.
Сборка выполняется без code-signing (только `.app` бандл).

`GENIUS_TOKEN` задаётся в Codemagic UI: **App settings → Environment variables**
→ группа `player_credentials`.

## Подпись release-сборки (Android)

Release APK подписывается постоянным ключом (а не debug-ключом), иначе
Google Play Protect помечает установку как угрозу (ложное срабатывание
вида `*.BulimiaTGen.*` / «высокий риск»). Конфигурация подписи читается из
`android/key.properties` (этот файл и сам keystore в `.gitignore`).

Keystore должен лежать рядом с `build.gradle.kts`:

```
android/app/player-release.jks
android/key.properties
```

Создать keystore (один раз):

```bash
keytool -genkeypair -v -keystore android/app/player-release.jks ^
  -keyalg RSA -keysize 2048 -validity 10000 -alias player
```

`android/key.properties`:

```
storePassword=<пароль>
keyPassword=<пароль>
keyAlias=player
storeFile=app/player-release.jks
```

**ВАЖНО**:

- Не теряйте `player-release.jks`. С другим ключом обновления поверх
  установленной версии работать не будут.
- При первой установке APK с новой подписью сначала удалите старую версию
  приложения с устройства — Android не обновляет APK с другим сертификатом.
- После создания/изменения keystore сделайте бэкап:

  ```powershell
  tools\backup_keystore.ps1
  ```

  Скрипт сохранит `player-release.jks` и `key.properties` в
  `Documents\Player-Keystore-Backup\<дата_время>`. Храните эту копию в
  надёжном месте (облако, менеджер паролей и т.п.).

### Play Protect / «высокий риск»

Даже правильно подписанный release APK при локальной сборке может вызвать
у Play Protect предупреждение «высокий риск» или ложное срабатывание
антивируса (например, `*.BulimiaTGen.*`). Это происходит потому, что
самоподписанный APK собран на вашем ПК и ещё не известен системе защиты.
APK из GitHub Releases обычно не вызывает такого предупреждения, потому что
уже был просканирован и/или установлен ранее.

Чтобы установить локальную сборку:

1. Включите «Установка из неизвестных источников» для используемого
   браузера/файлового менеджера (или для ADB).
2. Временно отключите Play Protect:
   **Play Market → профиль → Play Protect → настройки (шестерёнка) →
   Выключить сканирование приложений с помощью Play Protect**.
3. Установите APK через `tools\install_release.ps1` или вручную.
4. После успешной установки Play Protect можно снова включить.

Если вы выпускаете релиз для других пользователей — загрузите финальный APK
на GitHub Releases. Play Protect со временем перестаёт ругаться на файл,
который уже установлен у многих людей.

## Что дальше (roadmap)

- [x] Источник Muzmo (HTML-парсинг rmr.muzmo.cc)
- [x] Источник SoundCloud (публичный API)
- [x] Локальная БД: плейлисты, история прослушивания
- [x] Офлайн-кэширование треков (LRU, 5 треков)
- [x] Тёмная / светлая тема с адаптивной палитрой (Material You)
- [x] Поиск одновременно по всем источникам
- [x] Импорт / экспорт плейлистов (JSON)
- [x] Автообновление из GitHub Releases
- [x] Десктопная реализация плеера (Windows: чистый just_audio)
- [x] Десктопный UI: боковая навигация + панель плеера (DesktopShell)
- [ ] Десктоп: клавиатурные шорткаты (пробел — play/pause, стрелки — скип)
- [ ] Десктоп: очередь и детали трека в панели плеера
- [ ] Источник VK Music (reverse-engineered API + токен)
- [ ] Источник Bandcamp (официальный, простой scraping)
- [ ] Эквалайзер (через `just_audio`'s `AndroidLoudnessEnhancer`)

## Заметки

- `youtube_explode_dart` иногда отстаёт от изменений YouTube — обновляй
  пакет, если перестали резолвиться стримы.
- Стрим-URL временные (несколько часов). Хранить их в БД бессмысленно —
  сохраняем только метаданные трека, а URL резолвим при воспроизведении.
- Для офлайн-кэша аудио скачивается в `path_provider`'s
  `getApplicationDocumentsDirectory()` и URL подменяется на локальный путь
  в `resolveStreamUrl`.