# Changelog

Все заметные изменения в этом проекте будут документироваться в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
проект придерживается [Semantic Versioning](https://semver.org/lang/ru/).

## [Unreleased]

### Added

- **Диагностика secure storage** (Soulseek → Troubleshooting → Secure
  storage diagnostics): отчёт для разработчика с кнопками Copy / Share —
  проверка Android Keystore, ключей flutter_secure_storage и
  EncryptedSharedPreferences по шагам с полными исключениями, плюс
  выдержка из логов плагина. Учётных данных отчёт не содержит.

### Changed

- Уточнение к 3.0.1: keep-правила R8 не устраняют сбой `Failed to save
  credentials (secure storage)`. Сборка без них работает на реальном
  устройстве; NPE `FlutterInjector.encrypt` означает, что на устройстве
  пользователя падает инициализация Keystore / сохранённых ключей. Правила
  оставлены как безвредные, причину покажет отчёт диагностики.

## [3.0.1] - 2026-10-01

### Fixed

- **Хотфикс: сбой сохранения учётных данных Soulseek** (`Failed to save
  credentials (secure storage)`) в Android release-сборке — NPE
  `io.flutter.FlutterInjector.encrypt`. R8 full mode (AGP 8.x) horizontal
  class merging разрушал flutter_secure_storage 9.2.4 (мержил cipher-классы
  плагина в кластер `io.flutter.FlutterInjector`, удалял интерфейсы и
  конструкторы). Добавлены ProGuard keep-правила для
  `com.it_nomads.fluttersecurestorage` / `androidx.security.crypto` /
  `com.google.crypto.tink`.

## [3.0.0-beta] - 2026-09-30

> ⚠ Бета-версия. Это крупное обновление с полной интеграцией Soulseek P2P.
> Возможны ошибки и нестабильная работа — устанавливайте осознанно.

### Added

- **Полная интеграция Soulseek P2P** — поиск и загрузка музыки из
  пиринговой сети Soulseek:
  - Поиск по сети Soulseek через нативную обёртку (JNI-адаптер
    `SoulseekBridge` поверх Soulseek.NET), результаты отображаются вместе с
    остальными источниками в едином списке поиска.
  - Загрузка с ретраями и валидацией файлов: нулевые, неполные,
    oversized и невалидные файлы не попадают в кэш; повреждённый результат
    инвалидируется, retry ограничен общим бюджетом (повторное открытие
    ошибочного файла не зацикливается).
  - Кэш с управлением: пин/анпин/удаление, отображение размера и статуса,
    очистка отдельных записей и всего кэша.
  - Стабильность фонового сервиса (FGS): исправлены отказы запуска
    foreground service на target SDK 36 (FGS-01), контролируемое завершение
    при неуспехе запуска — без сетевой работы под видом успешного FGS.
- **Кликабельный кэш Soulseek** (SERIES-02, CACHE-UI-01): тап по элементу
  кэш-листа теперь строит `Track` и открывает те же контекстные действия,
  что и плитки поиска (воспроизведение, add to playlist, play next,
  детали) — раньше список был пассивным.
- **Статус загрузки в плеере** (SERIES-02, PLAYER-DL-01): кнопка Download
  в track settings sheet теперь знает про native-кэш и трансферы Soulseek и
  корректно отражает состояние загрузки (вместо неверного «не загружено»).
- **Качество в деталях трека** (SERIES-02, QUALITY-01): в деталях трека для
  Soulseek отображается битрейт/качество вместо «unavailable» — устранена
  потеря `extra` и `qualityScore` при конверсии `Track ↔ MediaItem`.

### Fixed

- **Восстановление сессии** (SERIES-02, SESSION-01): `Session restore
  failed: type 'Null' is not a subtype of type 'String'` в `Track.fromMap`
  — рассинхрон форматов writer/reader сессии; любой мобильный flush
  создавал нечитаемую запись, теперь форматы ключей совпадают и сессия
  восстанавливается (позиция + очередь).
- FGS-01, CACHE-01 и задачи P1–P5 из цикла отладки Soulseek (см.
  `plans/soulseek_bugfix_plan.md`).

### Tests

- Тесты компаратора версий с поддержкой prerelease-тегов и детектора
  бета-релизов (`test/core/update_service_test.dart`).
- Тесты диалога обновлений: бейдж/баннер показывается для беты и не
  показывается для stable (`test/ui/update_dialog_test.dart`).

## [2.5.2] - 2026-09-02

### Fixed

- Ручной порядок треков плейлиста (режим сортировки «Manual») вынесен в
  отдельно хранимый список `Playlist.manualOrder` (список `globalId`) —
  раньше перестановка drag&drop перетирала `sort_order` треков и
  «протекала» в остальные режимы сортировки (по дате, названию,
  исполнителю). Теперь Manual не влияет на остальные режимы: те всегда
  работают по исходному порядку добавления.
- Схема БД поднята до версии 5: добавлена колонка
  `playlists.manual_order_json` (JSON-список `globalId`, NULL — порядок не
  задан) с миграцией v4 → v5 в `AppDatabaseSchema`.
- `PlaylistRepository`: `replaceTrack` синхронизирует `manualOrder`
  (вхождения старого `globalId` заменяются на новый — трек остаётся на
  своей ручной позиции), `removeTrackAt`/`removeTrack` вычёркивают из
  списка ровно то вхождение `globalId`, которое соответствует удалённому
  экземпляру (корректно для дубликатов). `addTrack` намеренно НЕ
  добавляет трек в `manualOrder` — до первого осознанного drag&drop
  Manual эквивалентен порядку добавления.
- `Playlist.applyManualOrder`: применение ручного порядка устойчиво к
  «неполному» списку (треки, добавленные после задания порядка, — в конец
  в порядке добавления; неизвестные id игнорируются) и поддерживает
  дубликаты `globalId`.
- Экран плейлиста: reorder-режим работает по тому же списку, что и
  Manual-отображение (`applyManualOrder`) — индексы `onReorder` совпадают
  с индексами репозитория; ключи тайлов дополнены позицией, чтобы Flutter
  не путал тайлы с одинаковым `globalId`; выход из режима редактирования
  при смене сортировки принудительно сливает порядок в БД.

### Tests

- Расширены тесты DAO, `PlaylistRepository` и widget-тест ручной
  перестановки (`test/database/dao_test.dart`,
  `test/repositories/playlist_repository_test.dart`,
  `test/ui/playlist_manual_reorder_test.dart`) — покрыты синхронизация
  `manualOrder` при удалении/замене, дубликаты и неполный порядок.

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
