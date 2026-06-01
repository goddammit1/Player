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

Токен Genius можно переопределить при сборке:

```bash
flutter run --dart-define=GENIUS_TOKEN=<твой_токен>
```

В коде дефолтный токен лежит в `lib/sources/artwork_provider.dart`.

## Запуск

```bash
flutter pub get
flutter run                  # на подключённом устройстве / эмуляторе
flutter build apk --release  # релизный APK
```

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
