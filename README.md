# Player

Мобильный музыкальный плеер с парсингом треков с разных площадок.
Только для личного использования.

## Стек

- **Flutter** (Android)
- **just_audio** + **audio_service** — воспроизведение, фон, lock-screen контролы
- **youtube_explode_dart** — парсинг YouTube
- **dio** + **dio_cookie_manager** + **cookie_jar** + **html** — парсинг
  HTML-источников (Muzmo и др.)
- **flutter_riverpod** — state management
- **sqflite** — локальная БД (библиотека / история)
- **shared_preferences** — кэш URL обложек и мелких настроек

## Архитектура

```
lib/
??? main.dart                       инициализация audio_service + Riverpod
??? core/
?   ??? player_service.dart         AudioHandler поверх just_audio
?   ??? providers.dart              Riverpod провайдеры (плеер, поиск)
??? models/
?   ??? track.dart                  унифицированная модель трека
??? sources/                        ?? плагинная система источников ??
?   ??? track_source.dart           интерфейс
?   ??? source_registry.dart        реестр
?   ??? youtube_source.dart         реализация для YouTube
?   ??? youtube_cache.dart          LRU file-cache для скачанных треков
?   ??? muzmo_source.dart           реализация для rmr.muzmo.cc
?   ??? artwork_provider.dart       обложки: Genius API + iTunes fallback
??? ui/
    ??? pages/
    ?   ??? search_page.dart        главный экран с поиском
    ?   ??? player_page.dart        полноэкранный плеер
    ??? widgets/
        ??? mini_player.dart        компактная панель внизу
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

Обложек muzmo не отдаёт, поэтому они подгружаются через
`ArtworkProvider`:
1. **Genius API** — основной источник. Нужен Client Access Token,
   получается на https://genius.com/api-clients.
2. **iTunes Search API** — fallback, бесплатный, без токена,
   покрывает то, что Genius не нашёл (русская музыка, ремиксы).
3. Результаты кэшируются в RAM и в `SharedPreferences`, поэтому
   повторные поиски не дёргают сеть.

Токен Genius задаётся при сборке через `--dart-define-from-file=env.json`.
ВАЖНО: нужен именно **Client Access Token** (со страницы
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
tools\run.ps1            # запуск на устройстве/эмуляторе (токен из env.json)
tools\build_release.ps1  # релизный APK (токен из env.json)
```

## Подпись release-сборки

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

ВАЖНО: при первой установке APK с новой подписью сначала удалите старую
версию приложения с устройства — Android не обновляет APK с другим
сертификатом. И не теряйте keystore: с другим ключом обновления
поверх установленной версии работать не будут.


## Что дальше (roadmap)

- [x] Источник Muzmo (HTML-парсинг rmr.muzmo.cc)
- [ ] Источник SoundCloud (через scraping API)
- [ ] Источник VK Music (reverse-engineered API + токен)
- [ ] Источник Bandcamp (официальный, простой scraping)
- [ ] Локальная БД: избранное, плейлисты, история
- [ ] Офлайн-загрузка треков (`path_provider` + кеш audio)
- [ ] Тёмная/светлая тема, настройки качества
- [ ] Поиск во всех источниках одновременно (агрегатор)
- [ ] Импорт/экспорт плейлистов
- [ ] Эквалайзер (через `just_audio`'s `AndroidLoudnessEnhancer`)

## Заметки

- `youtube_explode_dart` иногда отстаёт от изменений YouTube — обновляй
  пакет если перестали резолвиться стримы.
- Стрим-URL временные (несколько часов). Хранить их в БД бессмысленно —
  сохраняем только метаданные трека, а URL резолвим при воспроизведении.
- Для офлайн-кеша имеет смысл скачивать аудио в `path_provider`'s
  `getApplicationDocumentsDirectory()` и подменять URL на локальный путь
  в `resolveStreamUrl`.
