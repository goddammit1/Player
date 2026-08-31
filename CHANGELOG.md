# Changelog

Все заметные изменения в этом проекте будут документироваться в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
проект придерживается [Semantic Versioning](https://semver.org/lang/ru/).

## [2.5.0] - 2026-08-31

### Added

- Кнопка «Cache all tracks» в меню плейлиста: пакетное скачивание всех треков
  плейлиста в дисковый кэш для офлайн-прослушивания. Шторка прогресса
  (`playlist_cache_progress_sheet.dart`) показывает текущий трек и общий
  прогресс, поддерживает отмену и по завершении выводит итоговый отчёт
  (скачано / уже в кэше / пропущено из-за отключённого источника / ошибки).
  Логика вынесена в чистый Dart-сервис `PlaylistCacheService`
  (`lib/core/playlist_cache_service.dart`): последовательная загрузка через
  `resolveStreamUrl` → `Dio().download` → `pin`, отмена через `CancelToken`.
- Ручной режим сортировки треков в плейлисте (`PlaylistSortMode.manual`):
  порядок, сохранённый в БД при добавлении/перестановке треков, больше не
  подвергается дополнительной сортировке и реверсу. Выбранный режим
  сортировки вынесен в `playlistSortModeProvider`
  (`lib/core/providers/playlist_sort_mode.dart`) и персистится в таблице
  `settings` — выбор переживает перезапуск приложения.

### Fixed

- Поиск: исправлены фильтры источников и вычисление id трека из очереди
  (`fd54f93`, `lib/sources/conversion.dart`, `lib/ui/pages/search_page.dart`).
- Обложки: обход ограничения Genius API по скобкам в названиях треков —
  `buildGeniusQueryVariants` добавляет fallback-варианты запроса с
  удалением/заменой скобок (подробности в `docs/genius_brackets_fix.md`).

### Refactored

- Импорт бэкапа упрощён: плейлисты всегда добавляются как новые, без попыток
  слияния с существующими (`lib/core/backup/playlist_backup.dart`).

### Tests

- Unit-тесты `PlaylistCacheService` — 11 шт.
  (`test/core/playlist_cache_service_test.dart`).
- Widget-тесты меню кэширования плейлиста — 6 шт.
  (`test/ui/playlist_cache_menu_test.dart`).

## [2.4.1] - 2026-08-25

### Fixed

- SoundCloud-источник: извлечение `client_id` теперь перебирает все JS-бандлы
  главной страницы SoundCloud (защитный потолок 20), а не первые 3. Реальный
  токен жил в 11-м бандле, тогда как первые (`tags.js`, `59-*`, `57-*`) его
  не содержали, поэтому источник был сломан. Лимит из 3 снят в
  `SoundCloudSource._maxClientIdScripts`.

## [2.4.0] - 2026-08-24

### Added

- Desktop-shell: единая рамка десктопа (`DesktopFrame`) и фабрика платформенного
  плеера (`PlayerServiceFactory`), инкапсулирующая выбор mobile/desktop-сервиса.
- Ленивый RAM-кэш кастомных обложек (`ArtworkHelper.getCustomArtwork`) — обложки
  подгружаются по запросу, а не массово при старте; `PlaylistArtworkEnricher` выделен
  из `PlaylistRepository`.
- Поиск по разделам: `SearchController`, `SearchState`, `SearchViewMode`,
  `SearchHistoryNotifier` вынесены в `lib/search/`.
- Guard эвикции `YoutubeCache`: повторный вызов `_evictIfNeeded` получает тот же
  Future вместо параллельного сканирования каталога.
- Wave 2: CDN-резолв кэшируется в `MuzmoSource`, дедупликация `_getStreamInfo`
  в `YoutubeSource`, параметризация `YoutubeCache` через конструктор.

### Refactored

- Декомпозиция `AppDatabase` на слои DAO и схему (`lib/core/database/`).
- Вынос конверсий `Track↔MediaItem` в `PlayerConversions` и `mediaItemToTrack`
  (`lib/core/player_conversions.dart`, `lib/sources/conversion.dart`).
- Вынос парсеров SoundCloud и утилит обложек в отдельные модули
  (`lib/sources/soundcloud_parser.dart`, `lib/sources/artwork_title_utils.dart`).
- Виджеты страницы плеера выделены в `lib/ui/pages/player/`.
- Компоненты строки поиска выделены в `lib/ui/pages/search/`.
- `_DesktopFrame` из `main.dart` вынесен в `lib/ui/desktop/desktop_frame.dart`.

### Tests

- Тесты DAO (`test/database/dao_test.dart`), фабрики плеер-сервиса
  (`test/core/platform/player_service_factory_test.dart`).
- Тесты конверсий (`test/sources/conversion_test.dart`), десктоп-панели очереди
  (`test/desktop_queue_panel_test.dart`).
- Обновлённые тесты artwork-хелпера, youtube-cache, playlist-repository.

## [2.3.0] - 2026-08-20

### Added

- Разделы настроек (Appearance, Backup, About) вынесены из модальных шторок
  в отдельные страницы, открываемые через `Navigator.push`.
- Общий виджет круглой кнопки «Назад» (`CircleBackButton`) для страниц настроек.

### Fixed

- Safe-area отступ для мобильной строки поиска (уходила под notch/статус-бар).
- Инициализация `AnimationController` в `NowPlayingOverlay` перенесена в
  `initState` — исправлено потенциальное падение `dispose()` при размонтировании.

### Tests

- Тесты на рендер подстраниц настроек и навигацию.

## [2.2.2] - 2026-08-18

### Fixed

- Полная очистка кастомных обложек при `clear_all_cache`
  (dead-custom detection в `PlaylistRepository.resetAllTrackArtworks`,
  `HistoryRepository.resetAllTrackArtworks`, `PlayerService._fetchAndApplyArtwork`).
- Восстановление оригинальной обложки для треков с удалёнными кастомными
  обложками после очистки кэша.

### Tests

- Тесты на очистку кастомных обложек и кэша.
- Регрессионный тест восстановления оригинальных обложек.

### Chore

- `.claude/` добавлен в `.gitignore`.

Полная история коммитов доступна в `git log`.
