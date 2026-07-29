# Player

Мобильный музыкальный плеер с поиском и стримингом треков с разных площадок.
Только для личного использования.

## Стек

- **Flutter** (Android + iOS)
- **just_audio** + **audio_service** — воспроизведение, фон, lock-screen контролы
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
├── main.dart                          инициализация audio_service + Riverpod
├── core/
│   ├── player_service.dart            AudioHandler поверх just_audio
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
    ├── pages/
    │   ├── home_page.dart             главный экран с табами
    │   ├── search_page.dart           поиск по источникам
    │   ├── player_page.dart           полноэкранный плеер
    │   ├── playlist_page.dart         список плейлистов / содержимое
    │   ├── history_page.dart          история прослушивания
    │   ├── settings_page.dart         настройки
    │   └── cache_page.dart            управление кэшем
    └── widgets/
        ├── now_playing_overlay.dart   мини-плеер поверх контента
        ├── artwork.dart               виджет обложки с эффектами
        ├── queue_sheet.dart           очередь воспроизведения
        ├── track_details_sheet.dart   детали трека (битрейт, источник)
        ├── track_settings_sheet.dart  настройки конкретного трека
        ├── add_to_playlist_sheet.dart добавление трека в плейлист
        ├── update_dialog.dart         диалог обновления приложения
        └── snack.dart                 снек-бары
```

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
3. Результаты кэшируются в RAM и в `SharedPreferences`, поэтому
   повторные поиски не дёргают сеть.

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
`SharedPreferences`. Префикс ключа зависит от наличия токена, поэтому
после добавления токена негативные результаты, накопленные без него,
больше не блокируют повторный поиск через Genius.

## Запуск

```bash
flutter pub get
tools\run.ps1            # запуск на Android-устройстве/эмуляторе (токен из env.json)
tools\build_release.ps1  # релизный APK (токен из env.json)
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
вида `*.BulimiaTGen.*`). Конфигурация подписи читается из
`android/key.properties` (этот файл и сам keystore в `.gitignore`).

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
storeFile=player-release.jks
```

**ВАЖНО**: при первой установке APK с новой подписью сначала удалите старую
версию приложения с устройства — Android не обновляет APK с другим
сертификатом. И не теряйте keystore: с другим ключом обновления
поверх установленной версии работать не будут.

## Что дальше (roadmap)

- [x] Источник Muzmo (HTML-парсинг rmr.muzmo.cc)
- [x] Источник SoundCloud (публичный API)
- [x] Локальная БД: плейлисты, история прослушивания
- [x] Офлайн-кэширование треков (LRU, 5 треков)
- [x] Тёмная / светлая тема с адаптивной палитрой (Material You)
- [x] Поиск одновременно по всем источникам
- [x] Импорт / экспорт плейлистов (JSON)
- [x] Автообновление из GitHub Releases
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