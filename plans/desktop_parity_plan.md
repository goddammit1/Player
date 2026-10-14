# План: паритет десктопной версии с мобильной (v3.3.0)

> Статус: этапы 1–3 выполнены (2026-10-12, не закоммичены; 3.8 — не делалась, Soulseek на
> Windows вживую не проверен); этап 4 — 4.1–4.3 выполнены (2026-10-13, не закоммичены; 4.4 —
> не делалась, на собранном `player.exe` не проверялся); этап 5 — план.
> Boost на десктопе — без лимитера (см. «Итог этапа 2», 2.4).
> Платформа: **только Windows**.
> Ограничение: сохранить текущий десктопный UI — `DesktopShell` (top bar + nav rail +
> `FloatingPanel` + `QueuePanel`) и `DesktopPlayerBar` поверх всех маршрутов через
> `DesktopFrame`. Мобильная вёрстка и мобильный движок (just_audio + audio_service) не
> меняются; всё новое гейтится через `isDesktop`.

## Принятые решения

| Вопрос | Решение |
|---|---|
| Аудиодвижок десктопа | **Переводим на `media_kit` (libmpv)** — boost, FLAC/Opus, уход от хаков just_audio_windows |
| Soulseek на Windows | **Внутри процесса** через `dart:ffi`; библиотека — оригинальная Soulseek.NET (NuGet `Soulseek` 10.0.2, как в slskd), а не Android-форк из SeekerAndroid; эталон архитектуры — slskd |
| Дистрибуция | **zip** через `tools/build_windows.ps1 -Zip` → `build\player-windows-x64.zip` |
| Платформы | Только Windows (Linux/macOS не трогаем) |

---

## 0. Как устроено сейчас

Десктоп **переиспользует** большую часть мобильных страниц: `PlaylistPage`, `HistoryPage`,
`SearchPage`, `SettingsPage` → `Appearance` / `Cache` / `CachedTracks` / `Backup` / `About`.
Поэтому разрыв — не «нет страниц», а:

1. **Нет точки входа в UI.** Полноэкранный `PlayerPage` открывается только из
   `NowPlayingOverlay`, скрытого на десктопе; меню трека — только long-press.
2. **Платформенные гейты** `Platform.isAndroid` / `isAvailable` выключают функции целиком
   (Soulseek, boost, обновления).
3. **`DesktopPlayerService` беднее мобильного `PlayerService`** (нет подтягивания обложек,
   boost не применяется).
4. **Источники завязаны на just_audio.** `TrackSource.createAudioSource` возвращает
   just_audio-типы: `LockCachingAudioSource` (muzmo, soundcloud, youtube — стриминг с
   записью в кэш через локальный прокси just_audio), `StreamAudioSource` (стриминг Soulseek
   во время загрузки), `AudioSource.uri`. Для `media_kit` эти типы непригодны — это главный
   объём работы при смене движка.

---

## 1. Матрица разрыва

| # | Функция | Мобилка | Десктоп сейчас | Где |
|---|---|---|---|---|
| 1 | Полноэкранный плеер (большая обложка, смена/сброс обложки трека, фон Mesh/Blur) | `PlayerPage` | **недостижим** | `now_playing_overlay.dart:108`, `player_interactive_artwork.dart` |
| 2 | Меню трека: Add to playlist, Play next, Download/Cached, Sleep timer, Details, Open folder, Boost | `showTrackSettingsSheet` | только long-press; для **играющего** трека — недоступно | `track_settings_sheet.dart`, `player_bottom_actions.dart:133` |
| 3 | Очередь: reorder, удаление, меню | `QueueSheet` | только тап; кнопка очереди в баре — `onPressed: () {}`; при ширине < 960 очереди нет | `queue_panel.dart`, `desktop_player_bar.dart:233`, `desktop_shell.dart:626` |
| 4 | Вкладка «Track» в панели очереди | — | заглушка | `queue_panel.dart:26-50` |
| 5 | Sleep timer | из меню трека | логика есть, UI нет | `sleep_timer_sheet.dart` |
| 6 | История поиска | `SearchHistoryPage` | пишется (`desktop_top_bar.dart:647`), **не показывается** | `search_history_page.dart` |
| 7 | Импорт плейлиста из JSON | меню «+» на главной | нет | `home_page.dart:560-650` |
| 8 | Boost громкости (0..12 dB) | `AndroidLoudnessEnhancer` | сохраняется, **не применяется**; слайдер скрыт | `player_service_desktop.dart:191`, `track_settings_sheet.dart:177` |
| 9 | Автоподтягивание обложек очереди | `_warmArtwork`, `_fetchAndApplyArtwork` | **нет** | `player_service.dart:566-690` |
| 10 | Soulseek целиком | Kotlin + .NET AAR | **выключен** (`isAvailable == android`) | `soulseek_platform_channel.dart:51`, `settings_page.dart:109`, `cache_page.dart:65` |
| 11 | Экспорт бэкапа/плейлиста | share-sheet | `Share.shareXFiles` — на Windows нужен «Сохранить как…» | `playlist_backup.dart:127,191` |
| 12 | Проверка обновлений | APK из GitHub Releases | пункт скрыт; ищется только `app-release.apk` | `update_service.dart:116-132`, `about_page.dart:110` |
| 13 | Системные медиа-контролы | audio_service | после перехода на `media_kit` SMTC пропадёт — нужен `smtc_windows` | — |
| 14 | Фоновые уведомления о кэшировании | Android-уведомление | только progress sheet | `playlist_cache_notifier.dart` |
| 15 | Haptics | есть | секция настроек видна, но бессмысленна | `appearance_page.dart:83` |

Попутно найденные проблемы:
- **Расположение данных на Windows.** `getApplicationDocumentsDirectory()` на Windows — это
  `C:\Users\<user>\Documents`: туда кладутся БД (`app_database.dart:86`), кастомные обложки
  (`artwork_helper.dart:32`) и там же ищется авто-бэкап (`main.dart:243`). Аудиокэш и кэш
  обложек — в `getTemporaryDirectory()` = `%TEMP%` (`youtube_cache.dart:309`), который чистит
  «Очистка диска» Windows, — закреплённые «офлайн»-треки могут исчезнуть.
- `DesktopPlayerBar._TrackInfo` подставляет захардкоженные `'Muzmo'` / `'320 kbps'`
  (`desktop_player_bar.dart:110-114`).
- `PlayerServiceInterface.rawPlayer` отдаёт just_audio `AudioPlayer`, но нигде не используется —
  убрать из интерфейса перед сменой движка.

---

## 2. Этапы

Оценки: S — до дня, M — 2–4 дня, L — неделя, XL — несколько недель.

### Этап 1. Точки входа в UI (максимум отдачи, минимум риска)

Не зависит от смены движка — можно делать первым и параллельно с этапом 2.

**1.1 Контекстное меню трека по правому клику — S/M**
- Сначала вынести действия трека из `track_settings_sheet.dart` (1210 строк) в UI-независимый
  контроллер: download / deleteCache / isCached / soulseekFolderAvailable / playNext.
- Хелпер `lib/ui/desktop/track_context_menu.dart`:
  `showTrackContextMenu(context, track, globalPosition)` в стиле меню плейлиста
  (`desktop_home_page.dart:183`). Пункты: Play next, Add to playlist, Download / Remove from
  cache, Details, Open folder (Soulseek), Remove from queue/playlist по контексту. Сложные
  пункты открывают существующие шиты через `showDesktopModalSheet`.
- `onSecondaryTapDown` в: `search_track_tiles.dart:46,180`, `playlist_page.dart:1559`,
  `history_page.dart:674`, `cached_tracks_page.dart:461,557`, `queue_panel.dart`.
  `onLongPress` остаётся.

**1.2 Полноценная очередь — M**
- `queue_panel.dart`: `ReorderableListView` с drag-handle по hover → `reorderQueueItem`;
  «×» по hover → `removeFromQueue`; «Очистить» (`clearQueue()` добавить в
  `PlayerServiceInterface`).
- Кнопка очереди в баре переключает видимость `QueuePanel` (провайдер, общий для shell и бара);
  при ширине < 960 панель выезжает оверлеем справа.

**1.3 Вкладка «Track» = десктопный Now Playing — M**
Заменяет `PlayerPage` без изменения раскладки:
- Большая обложка, по наведению — «Change cover» / «Reset» (логику из
  `player_interactive_artwork.dart:55-80` вынести в общий хелпер).
- Название / артист / источник / качество, остаток sleep timer.
- Действия трека инлайн: Download/Cached, Add to playlist, Sleep timer, Details, Open folder,
  слайдер Boost (после 2.4).
- Фон вкладки — `PlayerBackground`, чтобы темы **Mesh** и **Blur** давали эффект на десктопе.

**1.4 Плеер-бар — S**
- Клик по `_TrackInfo` → панель на вкладке «Track»; «…» → меню текущего трека.
- Индикатор sleep timer; убрать фолбэки `'Muzmo'` / `'320 kbps'`.

**1.5 История поиска в top bar — S/M**
Оверлей под капсулой при фокусе пустого поля: недавние запросы из `searchHistoryProvider`,
клик — поиск, «×» — удалить, «Clear all», стрелки + Enter, Esc.

**1.6 Импорт плейлиста — S**
`_importPlaylist` из `home_page.dart` → общий хелпер; на десктопе — правый клик по карточке
«new playlist»: «New playlist» / «Import from file».

**1.7 Мелочи — S**
Скрыть Haptics при `isDesktop`.

**Итог этапа 1 (сделано):**
- Ядро: `lib/core/track_actions.dart` (кэш-статус / download / delete / папка Soulseek /
  play next), `lib/core/cover_actions.dart`; в `PlayerServiceInterface` — `clearQueue()` и
  `trackQueueStream` (мобильный сервис — поверх `queue`, десктопный — свой subject).
- UI: `track_context_menu.dart`, `desktop_ui_state.dart` (панель docked / overlay + вкладка),
  `now_playing_panel.dart`; переписаны `queue_panel.dart`, плеер-бар, top bar;
  `TrackActionsGroup` (бывший `_SettingsGroup`) переиспользуется на вкладке «Track»;
  импорт плейлиста — `lib/ui/widgets/playlist_import.dart`.
- Отклонения: правый клик в `soulseek_folder_sheet` не подключён (Soulseek на десктопе — этап 3);
  остаток sleep timer показан в плитке «Sleep timer» вкладки и пилюлей в баре, а не отдельной
  строкой; слайдер Boost — после 2.4.
- Попутно исправлено: десктопный `update/resetCustomArtwork` не обновлял `MediaItem` и не
  удалял файл кастомной обложки; путь Windows (`C:\…`) не считался локальной обложкой
  (`isLocalArtworkUrl`); `SearchHistoryNotifier.remove` не удалял запись, сохранённую в
  нижнем регистре; `showTrackSettingsSheet` / `showSleepTimerSheet` не открывались из
  контекста без маршрута (плеер-бар).
- Тесты: `test/ui/desktop_stage1_test.dart` (11 шт.); весь набор — 918 зелёных.
- Ручная проверка на `player.exe` ещё не делалась.

### Этап 2. Движок `media_kit` на Windows

**2.0 Общее ядро очереди — M**
`PlayerService` (1078 строк) и `DesktopPlayerService` (602) дублируют очередь, `_playIndex`,
retry+evict, skip-after-error, prefetch, порог истории, сессию. Перед сменой движка вынести это
в общий `QueueEngine` поверх абстракции «бэкенд воспроизведения» (load / play / pause / seek /
position / completed / volume). Мобильный бэкенд — just_audio, десктопный — media_kit.
Заодно десктоп получает `_warmArtwork` / `_fetchAndApplyArtwork` (п. 9 матрицы).
Юнит-тесты на ядро с фейковым бэкендом в `test/core`.

**2.1 Нейтральное описание источника — M**
Сейчас `TrackSource.createAudioSource` возвращает just_audio-типы. Ввести sealed-тип,
например `PlaybackSource`:
- `LocalFile(path)` — офлайн-кэш, готовые файлы Soulseek;
- `RemoteStream(url, headers, cacheId?)` — muzmo / soundcloud mp3 / youtube (с записью в кэш);
- `Hls(url)` — soundcloud HLS;
- `GrowingFile(partPath, totalBytes, contentType)` — Soulseek во время загрузки.

Источники возвращают `PlaybackSource`. Мобильный адаптер превращает его ровно в те же
just_audio-объекты, что сейчас (`LockCachingAudioSource`, `SoulseekStreamAudioSource`…), —
поведение на Android не меняется. Тесты источников обновить.

**2.2 Локальный прокси на десктопе — L** (самый рискованный кусок этапа)
`media_kit` играет URL, но не умеет «стримить и одновременно писать в наш кэш» и читать
растущий файл. Нужен свой `HttpServer` на `127.0.0.1` в Dart:
- `RemoteStream` → проксирует upstream с поддержкой Range, параллельно пишет в
  `YoutubeCache` (замена `LockCachingAudioSource`), атомарно публикует файл в кэш по
  завершении; частичные загрузки не попадают в индекс.
- `GrowingFile` → логика `SoulseekStreamAudioSource` (дочитывание `.part`, poll, stall timeout)
  переносится сюда.
- Windows-нюанс: файл, открытый на чтение, нельзя переименовать (тот же errno 32, что глушится
  в `main.dart:151`). Прокси сам владеет и записью, и чтением, поэтому rename делается после
  закрытия читателей — без гонок.
- После этого хаки `_IdleAudioPlayer` / force-reload в `player_service_desktop.dart:398` и
  перехват `PathAccessException` в `main.dart` удаляются.

**2.3 `MediaKitPlayerBackend` — M**
- Пакеты `media_kit` + `media_kit_libs_windows_audio` (только аудио, без видео-DLL).
- `MediaKit.ensureInitialized()` в `main.dart` для десктопа; just_audio_windows убрать из
  десктопной сборки.
- Маппинг стримов position / duration / playing / completed / buffering в `PlaybackState`
  и `MediaItem`, которые ждёт UI (типы остаются из `audio_service` / `just_audio`, это чистый Dart).
- Замер до/после на реальной машине: время старта трека, переключения next/prev,
  seek в некэшированном треке. Временные логи убрать после замеров.

**2.4 Boost — S** (после 2.3)
Гейн через фильтр mpv: `af=lavfi=[volume=<db>dB,alimiter]` (лимитер против клиппинга на
+12 dB) через `NativePlayer.setProperty`; громкость пользователя остаётся отдельной.
Показать слайдер Boost на десктопе (`track_settings_sheet.dart:177`, вкладка «Track»).

**2.5 SMTC и медиаклавиши — M**
`media_kit` не интегрируется с системным медиа-флайаутом Windows. Подключить `smtc_windows`:
название / артист / обложка, play / pause / next / prev / seek из флайаута и аппаратных
медиаклавиш → команды `QueueEngine`.

**2.6 Сохранение сессии при закрытии окна — S**
Проверить, что `_SessionAutoSave` (`main.dart:270`) срабатывает при закрытии окна на Windows;
при необходимости — перехват закрытия окна и `saveSession()` перед выходом.

**Итог этапа 2 (сделано):**
- 2.0 + 2.1 сделаны вместе: ядру нужно отменять устаревшую загрузку между resolve и load,
  поэтому источник сразу стал нейтральным. `lib/core/playback/`: `QueueEngine` (очередь,
  поколения загрузок, retry+evict, skip-after-error, prefetch, порог истории, sleep timer,
  boost/громкость, сессия, обложки), `PlaybackBackend`, `QueueEnvironment` (шов для тестов),
  `JustAudioBackend` (мобилка: `PlaybackSource` → те же `LockCachingAudioSource` /
  `SoulseekStreamAudioSource` / `AudioSource.uri`), `MediaKitBackend`, `StreamProxy`.
  `PlayerService` — тонкая audio_service-обёртка над ядром, `DesktopPlayerService` — ядро на
  media_kit. `TrackSource.createAudioSource` → `createPlaybackSource` (`lib/sources/playback_source.dart`:
  `LocalFile` / `RemoteStream` / `Hls` / `GrowingFile`). `rawPlayer` убран из интерфейса,
  `SleepTimerMode` переехал в `player_service_interface.dart`.
- Десктоп получил то, что было только на мобилке: подтягивание обложек очереди, сохранение
  позиции на паузе, восстановленный трек виден в баре сразу. Попутно в ядре: смена очереди во
  время восстановления сессии больше не затирается, удаление играющего трека отменяет его загрузку,
  обложка из сети не применяется к другому треку, если очередь успела измениться.
- 2.2: чтение растущего файла вынесено в `GrowingFileReader` (общий для мобильного
  `SoulseekStreamAudioSource` и прокси). Прокси: одна загрузка в `<cachePath>.part`, range из
  `.part`, seek дальше загруженного + 512 КБ — прямым range-запросом в upstream, публикация в кэш
  после закрытия писателя и всех читателей, таймаут бездействия upstream (зависшая загрузка не
  переиспользуется), отмена незавершённой загрузки вытесненного источника без читателей.
  Хаки `_IdleAudioPlayer` / force-reload и перехват `PathAccessException` в `main.dart` удалены.
- 2.3: `media_kit` 1.2.6 + `media_kit_libs_windows_video` (по решению — видео-сборка вместо
  аудио, см. 2.4), `just_audio_windows` удалён;
  `archive` поднят до 4.5.1 (иначе `image` 4.11, который тянет media_kit, не компилируется).
  Успех загрузки — mpv узнал длительность; ошибка mpv или возврат в idle — исключение, ядро
  делает retry/skip (ошибки ловятся за ~35 мс). `network-timeout` поднят до 60 с для медленных
  пиров Soulseek. Замер на одинаковых входных данных (WAV, upstream 800 КБ/с), just_audio_windows →
  media_kit: старт локального файла 43–83 → 52–95 мс; старт потока с кэшем 685–751 → 330–351 мс;
  seek вперёд в некэшированном ~1065 → 101–156 мс; старый движок к тому же не публиковал кэш
  (errno 32). На реальных источниках: muzmo — 426–526 мс до старта, soundcloud — 1166 мс.
- 2.4 — **отклонение**: в аудио-сборке libmpv из media_kit (mpv 0.36, ffmpeg 6.0) нет
  libavfilter — `af=lavfi=[…]` не инициализируется даже с `anull`, а `volume-gain` появился только
  в mpv 0.38. Boost сделан громкостью mpv выше 100% (`volume-max=160`; гейн mpv кубический, +N dB =
  ×10^(N/60)), **без лимитера** — на громких мастерах при большом boost возможен клиппинг.
  Проверено на `media_kit_libs_windows_video`: её ffmpeg тоже урезан (нет `anull`, `alimiter`,
  компрессоров; `volume` без параметров), лимитера нет и там. По решению оставлена видео-сборка
  (+ANGLE / Vulkan / d3dcompiler DLL), boost — по-прежнему громкостью mpv. Лимитер возможен только
  с полным libmpv (например, shinchiro/mpv-winbuild-cmake, ~31.6 МБ архив) своим шагом в CMake.
  Внимание при смене пакета libs: оба плагина распаковывают libmpv в общий
  `build/windows/x64/libmpv` и пропускают распаковку, если каталог не пуст, — после переключения
  этот каталог (или `flutter clean`) нужно удалить, иначе рядом с exe останется старый DLL.
  Слайдер Boost — в шите трека и на вкладке «Track».
- 2.5: `smtc_windows` требует Rust-тулчейн — вместо него свой C++/WinRT-класс
  `windows/runner/media_controls.{h,cpp}` (канал `player/media_controls`; события SMTC из
  фонового потока передаются в UI-поток через `PostMessage`) и `WindowsMediaControls` в Dart:
  метаданные и обложка, play/pause, позиция и длительность (досылка раз в 5 с и при seek),
  кнопки флайаута и медиаклавиши → ядро.
- 2.6: `_SessionAutoSave.didRequestAppExit` дожидается `saveSession()` перед выходом — до этого
  при закрытии окна позиция терялась (проверено по `playback_state`).
- Тесты: `test/core/playback/` (ядро на фейковом бэкенде, маппинг в just_audio, прокси на фейковом
  upstream, формула boost), `test/core/platform/windows_media_controls_test.dart`, Boost на вкладке
  «Track»; весь набор — 980 зелёных. Android: `flutter build apk --debug` собирается, на устройстве
  не проверялось.
- Ручная проверка на `player.exe` (debug): воспроизведение muzmo / soundcloud через прокси,
  публикация в кэш, next / prev / pause / seek из системного флайаута, сохранение сессии при
  закрытии окна. Не проверены: HLS-поток SoundCloud вживую (демультиплексор в сборке есть) и
  растущий файл Soulseek на реальном пире (этап 3).

### Этап 3. Soulseek на Windows внутри процесса — XL

#### 3.0 Что взять за основу (результат анализа)

**Библиотека.** В `soulseek-wrapper/Soulseek.NET` лежит форк Soulseek.NET 10.0.2 из
SeekerAndroid: ~950 строк отличий от оригинала (бэклог листенера, `addressResolver`, доп.
состояния трансферов `UserOffline` / `CannotConnect` / `SizeMismatch`, interests, operator-события)
— подгонка под Android и UI Seeker. Для Windows берём **оригинал** —
[jpdillingham/Soulseek.NET](https://github.com/jpdillingham/Soulseek.NET), NuGet `Soulseek` 10.0.2
(последний релиз, июнь 2026; ровно эту версию использует slskd на всех десктопных ОС).
Android-сборку не трогаем — она остаётся на форке.

Что из форка использует наш мост и чем это заменить на оригинале:
- `addressResolver` (DNS с таймаутом 3 с и фолбэком на IP сервера, `SoulseekBridge.cs:1296`) →
  резолвить адрес самим и вызывать перегрузку `ConnectAsync(address, port, username, password)`.
- Классификация retryable-ошибок по именам `UserOffline` / `CannotConnect`
  (`SoulseekBridge.cs:1361`) → по типам исключений оригинала (`UserOfflineException`,
  `ConnectionException`, `TransferRejectedException`, `TransferSizeMismatchException` — сверить
  по исходникам 10.0.2).

Остальная логика моста (поиск, папки пира, `DownloadAsync` со `startOffset`, валидация файла,
события) работает на публичном API оригинала. Fork-only места изолировать `#if SEEKER_FORK`, чтобы
один исходник моста собирался в обе стороны.

**Эталон архитектуры — [slskd](https://github.com/slskd/slskd)** (референс из README
Soulseek.NET; Windows-сборки `win-x64` в каждом релизе). Что у него перенять:
- *Настройки клиента* (`src/slskd/Application.cs`, ~стр. 410–462): раздельные `ConnectionOptions`
  для сервера (`inactivityTimeout: -1` + TCP keepalive), пиров, трансферов (больше буферы, свой
  inactivity timeout) и distributed-сети; `UserEndPointCache`, `SearchResponseCache`. Наш мост
  сейчас создаёт клиент почти на дефолтах (`SoulseekBridge.cs:160`).
- *Переподключение* (`src/slskd/Core/ConnectionWatchdog.cs`): экспоненциальный backoff от 1 с до
  5 мин с jitter; **не** переподключаться при `IntentionalDisconnectException`,
  `LoginRejectedException` (неверный пароль) и `KickedFromServerException` (зашли под тем же ником
  с другого устройства — актуально, раз один аккаунт на телефоне и ПК). Событие
  `KickedFromServer` появилось как раз в 10.0.2.
- *Загрузки* (`src/slskd/Transfers/Downloads/DownloadService.cs`, ~стр. 1320–1500): недокачанные
  файлы в отдельном каталоге по схеме `<username>/<удалённый путь>` — исключает подхват чужого
  `.part` при resume; resume через `startOffset` + `FileMode.Append`; перенос в итоговый каталог
  только после успеха. Отличие для нас: slskd открывает файл с `FileShare.None`, а нам нужен
  `FileShare.Read | FileShare.Delete` — прокси читает файл во время загрузки (стриминг).
- *Раздача* (опционально, 3.8): `Shares/ShareScanner.cs` + `SqliteShareRepository.cs` + резолверы
  клиента; облегчённый вариант — `examples/Web/api/Startup.cs` в репо Soulseek.NET
  (`BrowseResponseResolver`, `SearchResponseResolver`, `EnqueueDownloadAction`).

**Лицензионные ограничения** (GPLv3 + Additional Terms в `LICENSE` Soulseek.NET):
- *Уникальный client minor version* — обязателен. Мост шлёт `ClientMinorVersion = 128`
  (`SoulseekBridge.cs:40`); проверить, что это не номер Seeker или другого клиента, иначе выбрать
  свой (зарезервированные диапазоны — в README Soulseek.NET; 760–7699999 занят slskd).
- *Изменение исходников библиотеки* делает её «Modified Version»: заголовок с описанием правок в
  каждом изменённом файле, обязательный текст в NOTICE, заметное указание в UI, ребрендинг.
  Отсюда выбор хостинга в 3.1 — предпочтительнее ничего не патчить.
- *Код slskd* — под AGPL-3.0: используем как образец архитектуры, без копирования кода.
- При раздаче (3.8) исходящие результаты поиска **обязательно** фильтровать по
  `ExcludedSearchPhrasesReceived` (требование README).

#### 3.1 Как запустить .NET внутри процесса — spike, M (делать первым)

NativeAOT с немодифицированной библиотекой не собрать: в `src/Common/Waiter.cs` используется
`dynamic` (`Microsoft.CSharp.RuntimeBinder`), который NativeAOT не поддерживает, а в
`src/Common/Extensions.cs:74` — `Activator.CreateInstance(typeof(T), …)` (это решается защитой
сборки от тримминга). Два варианта, оба внутри процесса:

- **A (рекомендую). Хостинг CoreCLR через `hostfxr`.** Мост — обычная `net9.0`-библиотека с
  экспортами `[UnmanagedCallersOnly]`; небольшой нативный загрузчик (C++ в `windows/runner` или
  отдельная DLL) поднимает runtime через `nethost` / `hostfxr`
  (`load_assembly_and_get_function_pointer`) и отдаёт указатели функций в Dart. NuGet-пакет
  используется **без изменений**: `dynamic` работает, обязательств по модифицированной версии нет,
  поведение то же, что у slskd на Windows (JIT). Минусы: в zip едет .NET runtime (+~70 МБ; zip
  slskd — ~60 МБ), холодный старт runtime ~0.1–0.3 с — поднимать лениво, при первом обращении к
  Soulseek.
- B. NativeAOT DLL. Меньше размер и старт, но нужен патч `Waiter.cs` (убрать `dynamic`) →
  модифицированная версия со всеми условиями лицензии и поддержкой патча при обновлениях. Имеет
  смысл, только если автор примет такой патч в апстрим — можно предложить PR и перейти на B после
  релиза с ним.

Spike: поднять runtime вариантом A из `player.exe`, подключиться, выполнить поиск, скачать файл,
получить события в Dart; замерить прирост zip и время старта.

#### 3.2 Мост: один исходник для Android и Windows — M

`SoulseekBridge` сейчас наследует Java-объект (JNI-конструктор, `ISoulseekEventSink`). Выделить
ядро без Android-зависимостей; Android-обёртка — под `#if ANDROID`, события — через C#-интерфейс.
Desktop-проект `net9.0` ссылается на NuGet `Soulseek` 10.0.2, Android — на форк (`#if SEEKER_FORK`
для `addressResolver` и fork-only состояний). Проверить, что `build_aar.ps1` и Android-сборка не
сломались. В desktop-варианте ядра — настройки клиента и переподключение по образцу slskd (3.0).

#### 3.3 Нативный ABI — M

- Экспорты `[UnmanagedCallersOnly]`: `slsk_init(eventCallback)`,
  `slsk_call(requestId, method, jsonUtf8)` (возвращает сразу, работа в `Task`), `slsk_free(ptr)`,
  `slsk_shutdown()`.
- Результаты и события — через один колбэк `(requestId | 0, jsonUtf8)`; в Dart это
  `NativeCallable.listener` (безопасно вызывать из любого потока .NET). Строки выделяет C#, Dart
  копирует и вызывает `slsk_free`. Блокирующих FFI-вызовов на UI-изоляте нет.
- **Защита процесса**: каждая точка входа и продолжение `Task` — в try/catch с ошибкой в JSON;
  `AppDomain.UnhandledException` / `TaskScheduler.UnobservedTaskException` — в лог.

#### 3.4 `DesktopSoulseekChannel` + порт Kotlin-логики в Dart — L

На Android между мостом и Dart ~4000 строк Kotlin (`SoulseekPlugin`, `TransferManager`,
`CacheManager`, `SoulseekDatabase`, `ForegroundService`). На десктопе — Dart-реализация
`SoulseekChannel` (`soulseek_source.dart:51`), DLL отдаёт только примитивы моста:
- `TransferManager`: очередь, лимит параллелизма, pause / resume / cancel, retry с backoff (как в
  `SoulseekTransferManager.kt`: база × 2^n, предел 30 с, jitter), события, snapshot активных
  трансферов при подписке; восстановление незавершённых загрузок после перезапуска (slskd делает
  то же на старте).
- `CacheManager` + БД кэша: LRU, pin, лимит, cleanup — в `AppDatabase` (sqflite_ffi) через миграцию
  схемы.
- Состояние соединения и переподключение — события в тот же контракт `SoulseekEvent`
  (`soulseek_models.dart`); «вас отключили: вход с другого устройства» показывать в UI явно.

`SoulseekPlatformChannel.instance` заменить фабрикой по платформе (как `PlayerServiceFactory`);
`syncToNative` в `main.dart` — только для Android.

#### 3.5 Стриминг и Windows-специфика — M

- Стриминг во время загрузки: `SoulseekSource` отдаёт `GrowingFile`, его обслуживает прокси из 2.2.
  Мост пишет `.part` с `FileShare.Read | FileShare.Delete`; итоговый rename делает `TransferManager`
  на Dart после закрытия читателей прокси.
- Каталог недокачанных — `<cache>/incomplete/<username>/<путь>` по схеме slskd.
- Listen-порт: запрос брандмауэра Windows при первом запуске; проброс — как в настройках Android.
- Пароль — `flutter_secure_storage` (DPAPI): проверить чтение/запись.

#### 3.6 Включить UI — S/M

Снять гейты: `settings_page.dart:109`, `cache_page.dart:65`, `cached_tracks_service.dart:357`,
`soulseek_settings_page.dart` (сейчас «unavailable»). Проверить десктопные ветки
`soulseek_folder_sheet` / `soulseek_transfer_sheet`. Индикатор загрузок в top bar или nav rail.

#### 3.7 Сборка и упаковка — S/M

`tools/build_windows.ps1`: `dotnet publish` моста (`win-x64`) + раскладка runtime и загрузчика
рядом с `player.exe` до упаковки в zip; в `windows/CMakeLists.txt` — install-шаг, чтобы это работало
и при `tools/run_windows.ps1`. Скрипт падает с ошибкой, если чего-то нет в Release-папке. В zip —
GPLv3 + Additional Terms Soulseek.NET (дополнить `soulseek-wrapper/THIRD_PARTY_NOTICES.md` для
Windows-сборки).

#### 3.8 Раздача файлов — M/L (опционально)

Ни на Android, ни в мосте раздачи по сути нет: `ConfigureSharingSync` меняет только порт и
скорости, резолверы browse / search / enqueue не заданы. ПК — естественное место для раздачи, а
часть пиров отказывает тем, кто ничего не раздаёт. Минимальная версия по образцу `examples/Web`
Soulseek.NET: выбранная папка → индекс в SQLite → `BrowseResponseResolver`,
`SearchResponseResolver` (с фильтром excluded phrases), `EnqueueDownload` с ограничением слотов и
скорости. Полная очередь отдачи с governor — по образцу `Transfers/Uploads` в slskd.

**Итог этапа 3 (сделано, кроме 3.8):**
- 3.1: вариант A без отдельного C++-загрузчика — CoreCLR поднимает сам Dart по FFI из фонового
  изолята: `soulseek/hostfxr.dll` → `hostfxr_initialize_for_dotnet_command_line` (мост — self-contained
  `net9.0`-приложение с пустым `Main`) → `hdt_get_function_pointer` → `[UnmanagedCallersOnly]`-экспорты.
  Runtime грузится из папки приложения (проверено: `RuntimeEnvironment.GetRuntimeDirectory()` =
  `…\soulseek\`), старт ~30 мс. Размер: папка `soulseek\` 76 МБ (192 файла), в zip ~33 МБ. Тримминг
  не делался (`dynamic` в библиотеке). Адреса экспортов кладутся в переменную окружения процесса —
  CoreCLR нельзя инициализировать повторно после hot restart.
- Client minor version: `128` в мосте — номер Seeker, а лицензия Soulseek.NET требует уникальный.
  Windows-клиент шлёт свой — `9100330` (вне 760–7699999 slskd). **Android по-прежнему шлёт 128** —
  это стоит поменять отдельно.
- 3.2: логика моста — в `soulseek-wrapper/SoulseekBridgeCore.cs` (общий исходник), `SoulseekBridge.cs` —
  тонкая JNI-обёртка с прежними `[Export]`. Fork-only места под `#if SEEKER_FORK` (символ задан в
  `SoulseekWrapper.csproj`): `addressResolver` (на Windows резолв сами + `ConnectAsync(address, port, …)`),
  7-аргументный конструктор `File` (Latin-1), классификация retryable по именам типов. На оригинале
  retryable — по цепочке исключений (`UserOffline`, `Connection`, `NoResponse`, `Timeout`, `Socket`, `IO`;
  не retryable — `TransferRejected`, `TransferSizeMismatch`, `TransferReportedFailed`). Настройки клиента
  по slskd: сервер без inactivity timeout + TCP keepalive, трансферы с буферами 256 КБ.
  `UserEndPointCache` / `SearchResponseCache` slskd не перенесены (в библиотеке только интерфейсы).
  Android-проект компилируется (`dotnet build`), **AAR в `android/app/libs` не пересобирался** и на
  устройстве не проверялся. Отличие оригинала: имена, декодированные как Latin-1, при запросе файла
  кодируются в UTF-8 — такие файлы могут не скачаться (как в slskd).
- 3.3: `soulseek-wrapper/desktop/` (`SoulseekDesktop.csproj`, `NativeExports.cs`): `Init(callback)`,
  `Call(requestId, method, json)`, `Free`, `Shutdown`; ответы и события — один колбэк, в Dart
  `NativeCallable.listener`; всё в try/catch, необработанные исключения — в лог.
- 3.4: `lib/sources/soulseek_desktop/`: `soulseek_native_bridge.dart` (FFI-транспорт),
  `soulseek_transfer_manager.dart` (порт TransferManager: семафор с изменяемым лимитом, retry 2 с × 2^n
  до 30 с, pause/resume/cancel, dedupe по cacheKey, restore: PAUSED / FAILED), `soulseek_desktop_cache.dart`
  (порт CacheManager: LRU, pin, лимит), `soulseek_desktop_store.dart` (таблицы `soulseek_transfers` /
  `soulseek_cache_entries`, миграция AppDatabase v7), `soulseek_desktop_channel.dart`.
  `SoulseekPlatformChannel` стал абстрактным, `instance` выбирается по `defaultTargetPlatform`
  (`AndroidSoulseekChannel` / `DesktopSoulseekChannel`). Переподключение по slskd: backoff 1 с … 5 мин с
  jitter, без него после ручного отключения, `LoginRejected` и `KickedFromServer` («signed in from another
  device» — снек в top bar). Сверх плана: при первом поиске/загрузке канал сам подключается сохранёнными
  учётными данными; ручное отключение ставит загрузки на паузу, а не отменяет их.
  `syncToNative` вызывается и на Windows (настройки применяются в памяти канала).
- 3.5: кэш — `%LOCALAPPDATA%\com.player\player\soulseek_cache`, недокачанное — `incomplete\<cacheKey>.part`
  (cacheKey уже включает пира и путь, поэтому схема `<username>/<путь>` slskd не нужна). Мост пишет `.part`
  с `FileShare.Read | Delete` и на Windows не переименовывает (`PublishOnComplete = false`): публикацию
  делает Dart после закрытия читателей прокси (`FileReadLeases` в `GrowingFileReader`); если читатель
  держит файл дольше 5 с (плеер на паузе) — публикуется копия, `.part` удаляется после закрытия.
  Не проверены: запрос брандмауэра на listen-порт и `flutter_secure_storage` (DPAPI) — нужен ручной прогон.
- 3.6: пункт Soulseek в настройках и раздел кэша показываются при `isAvailable` (на Windows — есть
  `soulseek\` рядом с exe); заглушка на Windows подсказывает пересобрать. Индикатор активных загрузок в
  top bar (`soulseek_downloads_indicator.dart`). Раздел «Sharing» оставлен как есть (раздачи нет — 3.8).
- 3.7: CMake-шаг `soulseek_bridge` — `dotnet publish` при изменении исходников моста + install в
  `soulseek\` (работает и в `flutter run`); без `dotnet` сборка проходит с предупреждением.
  `build_windows.ps1` падает, если моста нет. В `soulseek\` кладутся `LICENSE.Soulseek.NET.txt`,
  `NOTICE.Soulseek.NET.txt` (из NuGet-пакета) и `THIRD_PARTY_NOTICES.md` (добавлен раздел Windows).
- Тесты: `test/sources/soulseek_desktop/` (менеджер и кэш, канал, учёт читателей) — 33 шт.; весь набор —
  1013 зелёных. `player.exe` (debug) стартует, миграция БД 6→7 проходит.
- **Не проверено вживую**: подключение, поиск, загрузка и стриминг с реального пира на Windows,
  переподключение после обрыва сети, kicked при входе с телефона, resume после перезапуска.

**Ревью этапов 1–3 (2026-10-13, ECC: flutter / csharp / cpp reviewers) — исправлено:**
- *Soulseek (Dart)*: замыкание `Isolate.run` захватывало `this` → старт CoreCLR падал с «object is
  unsendable», мост не запускался вовсе (тест `soulseek_native_bridge_test.dart`). Менеджер: поколение
  retry-loop (pause → resume больше не запускает две загрузки одного `.part`), id попытки в мосте
  `dl_<key>#<n>` (события и отмена прошлой попытки не задевают новую), `resume` только из PAUSED,
  pause / cancel не трогают завершённые, запрос PAUSED-трека возобновляет его, `InProgress` →
  DOWNLOADING (и в Kotlin `BridgeStateMapper`). Кэш: отложенное удаление `.part` отменяется новой
  загрузкой ключа; запись кэша не удаляется, если файл занят. Канал: watchdog переподключения не
  глохнет после неудачного `_ensureConnected`, неудачный `_init` не кэшируется.
- *Мост (C#)*: события освобождённого клиента отфильтрованы, локальный `client` в connect; одно
  терминальное `downloadFailed` на попытку (TimedOut теперь retryable); перед дозаписью `.part`
  проверяется его длина; `OperationCanceledException` — отмена только по своему токену; retryable IO —
  кроме нехватки места / длинного пути; cleanup снимает только свой CTS; `..` — по сегментам пути;
  на Windows валидация не удаляет опубликованный файл; `Shutdown` отменяет поиски.
- *Прокси / media_kit*: `close()` ждёт писателей; повтор публикации (5 × 250 мс), затем ошибка;
  без Content-Length соединение обрывается, а не скачивается впустую; свой `.stream.part`
  (не конфликтует с ручной загрузкой и кэшем плейлиста); неудачный bind не кэшируется; после
  неудачной загрузки media_kit-бэкенд снова idle (play перезагружает трек).
- *UI*: «Add to playlist…» из контекстного меню и плеер-бара ничего не открывал; меню очереди
  разрешает индекс в момент выбора; повторный Download присоединяется к идущей загрузке, плитка
  Download на вкладке «Track» обновляется по `TrackActions.cacheChanges`; «назад» очищает поле
  поиска; «Remove from playlist» скрыт в режиме ручной сортировки.
- *SMTC / сборка*: обработчики SMTC и поток обложки держат общий `EventQueue` вместо `this`, обложка
  применяется в UI-потоке с проверкой поколения, кривой URL обложки не роняет метаданные; CMake
  требует .NET 9 SDK (не просто `dotnet.exe`), без него удаляет старый `soulseek\`, `-nodeReuse:false`.
- Открыто (нужен живой прогон или вне объёма): seek далеко вперёд в растущем mp3 Soulseek может ждать
  загрузку (ID3v1 в конце файла); синхронный `shutdown()` FFI при выходе; нет таймаута у
  `SoulseekNativeBridge.call`; `.part` упавших загрузок не подчищаются; Android-`TransferManager.kt`
  с теми же гонками pause/resume не трогали, AAR не пересобирался.

### Этап 4. Данные, обслуживание, дистрибуция

**4.1 Расположение данных на Windows — M** (до первого публичного релиза)
- БД, кастомные обложки, бэкапы → `getApplicationSupportDirectory()`
  (`%APPDATA%\<company>\player`) вместо `Documents`.
- Аудиокэш и закреплённые треки → постоянный каталог (`%LOCALAPPDATA%\…\cache`), а не `%TEMP%`.
- Одноразовая миграция существующих файлов со старых путей при старте (только Windows), с
  проверкой, что БД не открыта; Android-пути не меняются.
- `_autoRestoreBackupIfNeeded` искать в новом каталоге (и в старом — для обратной совместимости).

**4.2 Экспорт — S**
На десктопе вместо share-sheet — «Сохранить как…» (`FilePicker.platform.saveFile`) для полного
бэкапа и экспорта плейлиста (`playlist_backup.dart:116,180`).

**4.3 Обновления через zip — M**
- В GitHub Release, помимо `app-release.apk`, публикуется `player-windows-x64.zip` (результат
  `tools/build_windows.ps1 -Zip`; в него должны попасть DLL media_kit, мост Soulseek, загрузчик и .NET runtime из 3.7).
- `UpdateService`: выбирать asset по платформе (`update_service.dart:125` ищет только APK);
  поле `apkUrl` → `assetUrl`.
- Установка на Windows: скачать zip в temp → распаковать → запустить маленький
  PowerShell-скрипт, который ждёт выхода `player.exe`, копирует файлы поверх папки приложения
  и перезапускает его. Работает, потому что после 4.1 данные лежат вне папки с exe. Если папка
  приложения недоступна на запись — показать ссылку на релиз.
- Показать «Check for updates» на десктопе (`about_page.dart:110`).

**4.4 Тосты Windows — S (опционально)**
`flutter_local_notifications` 18 поддерживает Windows: завершение кэширования плейлиста /
загрузки Soulseek, когда окно не в фокусе.

**Итог этапа 4 (сделано, кроме 4.4):**
- 4.1: каталоги — `lib/core/platform/app_paths.dart` (`AppPaths.dataDir` / `cacheDir`); на мобильных
  прежние Documents / temp. Windows: БД и `custom_artworks` → `%APPDATA%\com.player\player`,
  `yt_audio_cache` → `%LOCALAPPDATA%\com.player\player` (там же `soulseek_cache`). Кэш обложек
  `libCachedImageData` (flutter_cache_manager) остался в `%TEMP%` — это чистый кэш.
- Миграция — `WindowsDataMigration.runOnStartup()` в `main` до первого обращения к БД. БД переносится
  `rename`-ом вместе с -wal/-shm/-journal (между томами — копия + удаление оригинала). Занята другим
  процессом → откат, приложение работает со старой БД в «Документах» до следующего старта. Обложки и
  аудиокэш — пофайлово, `.part` удаляются. Абсолютные пути обложек в БД (настройки, `playlist_covers`,
  треки в JSON) переписываются `AppDatabase.replaceInAllText` по всем текстовым колонкам — один раз,
  отметка `migration_windows_paths_v1`. Авто-бэкап ищется в новом каталоге и в «Документах».
- 4.2: `deliverBackupFile` в `playlist_backup.dart` — на десктопе `FilePicker.saveFile` (диалог Windows
  расширение не дописывает — дописываем `.json`); экспорт возвращает `false` при отмене.
- 4.3: `UpdateService.releaseAssetName` — `player-windows-x64.zip` на Windows; `AppRelease.apkUrl` →
  `assetUrl`. Установка — `lib/core/windows_update_installer.dart`: распаковка `Expand-Archive` в
  `%TEMP%\player-update-staging` (ошибки видны до выхода), отсоединённый PowerShell-скрипт (ASCII) ждёт
  выхода `player.exe` (≤ 2 мин, иначе отмена), `robocopy /E` поверх папки приложения (без удаления
  лишних файлов), перезапуск; лог — `%TEMP%\player-update.log`. Приложение закрывается через
  `exitApplication(cancelable)` (сессия сохраняется). Папка без прав на запись → кнопка «Открыть
  страницу релиза». В debug-сборке установка запрещена. Скрипт проверен вручную на песочнице (путь с
  кириллицей и пробелом, ожидание PID); полный цикл на `player.exe` из zip — не проверялся.
- Публикация zip в GitHub Release — вручную (`build\player-windows-x64.zip`, имя ассета строго такое).
- Тесты: `test/core/windows_data_migration_test.dart`, `windows_update_installer_test.dart`,
  `backup_export_desktop_test.dart`, Windows-сценарии в `update_service_test.dart`.

### Этап 5. Десктопное поведение (опционально, после этапов 1–2)

- Горячие клавиши: Space, Ctrl+F, Ctrl+←/→, Ctrl+↑/↓, Esc (`Shortcuts`/`Actions` в `DesktopShell`).
- Запоминать размер/позицию окна; один экземпляр приложения.
- Подстраницы настроек открывать внутри `FloatingPanel` через `_contentStack`, а не корневым
  `Navigator` поверх shell.

---

## 3. Порядок и зависимости

```
Этап 1 ───────────────────────────────────────────────┐ (параллельно)
                                                      │
2.0 ядро очереди → 2.1 PlaybackSource → 2.2 прокси → 2.3 media_kit → 2.4 boost
                                                   └→ 2.5 SMTC, 2.6 сессия
3.1 spike хостинга .NET + проверка client minor version (можно сразу, параллельно этапу 2)
   → 3.2 → 3.3 → 3.4 → 3.5 (нужен прокси из 2.2) → 3.6 → 3.7;  3.8 — по желанию
4.1 данные — до первого публичного Windows-релиза; 4.2 — в любой момент;
4.3 — после 3.7 (в zip должны быть мост и runtime)
```

Ориентир по объёму: этап 1 ≈ 1.5–2 недели; этап 2 ≈ 2.5–3 недели; этап 3 ≈ 4–5 недель;
этап 4 ≈ 1–1.5 недели.

Ключевые риски:
1. **Хостинг .NET внутри процесса** (размер zip, холодный старт, загрузка runtime из папки
   приложения) — проверяется spike 3.1 до остальных работ этапа 3. NativeAOT без патча
   библиотеки невозможен (`dynamic` в `Waiter.cs`).
2. **Локальный прокси (2.2)** — Range-запросы, обрыв upstream, корректная публикация в кэш.
   Покрыть тестами на фейковом upstream-сервере.
3. **Падение в нативном коде убивает приложение** (цена решения «внутри процесса») —
   дисциплина try/catch на границе ABI (3.3) и логирование.

## 4. Проверка

- Виджет-тесты рядом с `test/ui/desktop_*_test.dart`: контекстное меню, reorder/удаление в
  очереди, вкладка Track, выпадающая история поиска. Записи в БД из тапов в `testWidgets` не
  делать — подменять провайдеры in-memory (sqflite в виджет-тестах виснет).
- Юнит-тесты: `QueueEngine` с фейковым бэкендом (общие для мобилки и десктопа); маппинг
  `PlaybackSource` → just_audio (регресс мобилки); прокси с фейковым upstream и растущим файлом;
  `DesktopSoulseekChannel` / `TransferManager` с фейковым мостом.
- Ручная проверка на `player.exe` из zip: старт/переключение/seek, boost без клиппинга, SMTC и
  медиаклавиши, закрытие окна, Soulseek (поиск, скачивание, стриминг при медленном пире),
  миграция данных со старых путей, обновление zip поверх установленной версии.
- Soulseek на Windows: переподключение после обрыва сети (backoff), вход тем же аккаунтом с
  телефона (kicked — без автопереподключения), resume недокачанного файла после перезапуска.
- Android-сборка и тесты после 2.0, 2.1 и 3.2 — убедиться, что мобилка не изменилась
  (мост собирается в обе стороны, Android остаётся на форке Seeker).
