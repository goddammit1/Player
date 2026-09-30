# План серии 02 — SESSION-01, кликабельный кэш, статус загрузки в плеере, качество в деталях

Серия из четырёх задач по мотивам пользовательской формулировки: «исправим оставшиеся проблемы связанные с SESSION-01: Session restore failed: type 'Null' is not a subtype of type 'String' (track.dart:80 Track.fromMap), а также сделать кликабельный кэш, чтобы оттуда можно взаимодействовать было с треками как и со страницы поиска. Нужно показывать статус загрузки трека на самом плеере (уже есть нужная кнопка download) и также в том же плеере в деталях трека указывать качество (сейчас на треках из соулсик там unavailable)».

База: ветка main, HEAD = c49455f, рабочее дерево чистое. Прошлый цикл (FGS-01, CACHE-01, P1–P5, NEW-1/3) закрыт верификацией на устройстве; тесты 634 passed / 4 skipped, analyze чист. При подготовке плана код только читался — сборки, тесты и правки не выполнялись.

Формат и стиль соответствуют [soulseek_bugfix_plan.md](soulseek_bugfix_plan.md) и [soulseek_source_integration_plan.md](soulseek_source_integration_plan.md).

## 1. Сводная таблица проблем

| ID | Приоритет | Проблема | Затронутые файлы | Слой |
|---|---|---|---|---|
| SESSION-01 | P0 | `Session restore failed: type 'Null' is not a subtype of type 'String'` в `Track.fromMap` — restore сессии с любой очередью, сохранённой мобильным плеером, падает целиком | [lib/models/track.dart](../lib/models/track.dart), [lib/core/player_conversions.dart](../lib/core/player_conversions.dart), [lib/core/database/playback_dao.dart](../lib/core/database/playback_dao.dart) | Dart core |
| CACHE-UI-01 | P1 | Кэш-лист Soulseek пассивен: тап по элементу ничего не делает; нет воспроизведения из кэша и контекстных действий как у плиток поиска | [lib/ui/widgets/soulseek_cache_sheet.dart](../lib/ui/widgets/soulseek_cache_sheet.dart), [lib/sources/soulseek_models.dart](../lib/sources/soulseek_models.dart) | Dart UI |
| PLAYER-DL-01 | P1 | В плеере (кнопка «…» → track settings sheet → Download) нет статуса закачки Soulseek: кнопка не знает про native-кэш и трансферы, показывает неверное состояние, а при загрузке вообще не понимает, что её инициировал `resolveStreamUrl` | [lib/ui/widgets/track_settings_sheet.dart](../lib/ui/widgets/track_settings_sheet.dart), [lib/ui/pages/player/player_bottom_actions.dart](../lib/ui/pages/player/player_bottom_actions.dart) | Dart UI |
| QUALITY-01 | P1 | В деталях трека для Soulseek битрейт показывает «unavailable»: Track, собранный из MediaItem в плеере, теряет `extra` и `qualityScore` | [lib/ui/pages/player/player_bottom_actions.dart](../lib/ui/pages/player/player_bottom_actions.dart), [lib/ui/widgets/track_details_sheet.dart](../lib/ui/widgets/track_details_sheet.dart), [lib/core/player_conversions.dart](../lib/core/player_conversions.dart) | Dart UI/core |

Ключевой факт, объединяющий PLAYER-DL-01 и QUALITY-01: обе проблемы имеют один корень — деградация `Track` до `MediaItem` и обратно с потерей полей (см. §4.3 и §4.4).

## 2. Root cause по каждой задаче (из реального кода)

### 2.1. SESSION-01 — рассинхрон форматов writer/reader

Писатель и читатель сессии говорят на разных форматах ключей:

- **Писатель (mobile):** [`PlayerConversions.trackToRow()`](../lib/core/player_conversions.dart:47) в [`_flushSessionNow()`](../lib/core/player_service.dart:724) кладёт в `queue_json` строки с ключами `track_id`, `source_id`, `extra_json` (extra сериализуется в JSON-строку через [`TrackRowCodec.extraPrimitives()`](../lib/core/database/track_row_codec.dart:37)).
- **Читатель:** [`PlaybackDao.loadPlaybackSession()`](../lib/core/database/playback_dao.dart:57) декодирует `queue_json` и вызывает [`Track.fromMap(r)`](../lib/models/track.dart:79), который ждёт ключи `id`, `source_id`, `extra` (map, не строка).
- **Результат:** `m['id']` → `null` → `null as String` → `type 'Null' is not a subtype of type 'String'` на [строке 80](../lib/models/track.dart:80). Исключение выбрасывается из `.map()` по всей очереди, catch в [`_restoreSession()`](../lib/core/player_service.dart:775) гасит его целиком — сессия не восстанавливается никогда, включая позицию и очередь.
- **Писатель (desktop):** [`player_service_desktop.dart`](../lib/core/platform/player_service_desktop.dart:547) пишет `t.toMap()` — правильный формат. Т.е. баг только мобильного пути, но формат в БД один и тот же.

Замечание про прошлую диагностику: [soulseek_bugfix_plan.md §7](soulseek_bugfix_plan.md) предполагал «старую схему/битую запись» — фактически причина проще и воспроизводима на текущем коде: любой мобильный flush создаёт нечитаемую запись.

Другие потребители `Track.fromMap` (для оценки blast radius фикса): [`HistoryEntry.fromJson()`](../lib/core/repositories/history_repository.dart:25) и импорт бэкапа в [`app_database.dart:290`](../lib/core/database/app_database.dart:290) — оба читают формат `Track.toMap()` и работают корректно; их трогать не нужно.

### 2.2. CACHE-UI-01 — пассивный список без Track-модели

[`_CacheTile`](../lib/ui/widgets/soulseek_cache_sheet.dart:423) — чисто презентационный виджет: строки из `SoulseekCacheEntry` (title/artist/duration с fallback на basename), кнопки Pin/Unpin/Delete на уровне `_CacheItem.cacheKey`. Нет `onTap`-обработки на тайле, нет построения `Track` — значит нет ни воспроизведения, ни `showTrackSettingsSheet` (который даёт add to playlist / play next / details).

Паттерн для переиспользования — плитки поиска: [`SearchTrackTileList`](../lib/ui/pages/search/search_track_tiles.dart:19) — `onTap` + `onLongPress: () => showTrackSettingsSheet(context, track: track)`; воспроизведение в [`search_page._playTrack()`](../lib/ui/pages/search_page.dart:291) через `player.setQueue(...)`.

Проблема воспроизведения из кэша: `SoulseekSource.resolveStreamUrl()` при cache hit возвращает `entry.localPath` мгновенно, но для этого нужны `extra.cacheKey` или триада `peerUsername/remoteFilename/sizeBytes` ([`_getOrCreateCacheKey()`](../lib/sources/soulseek_source.dart:760)). В `SoulseekCacheEntry` ([модель](../lib/sources/soulseek_models.dart:379)) есть `cacheKey`, `title`, `artist`, `durationSeconds`, `sizeBytes`, но нет `peerUsername`/`remoteFilename`/`bitrate`/`extension`-атрибутов — их нужно либо добавить в БД/канал (масштабно), либо обойтись `extra.cacheKey` (достаточно для cache hit — см. решение).

### 2.3. PLAYER-DL-01 — кнопка Download не знает о native-кэше и трансферах

Кнопка download в плеере — это тайл Download в [`_SettingsGroup`](../lib/ui/widgets/track_settings_sheet.dart:778) внутри track settings sheet, который открывается из плеера через `_showExtra()` в [player_bottom_actions.dart:133](../lib/ui/pages/player/player_bottom_actions.dart:133).

Три несоответствия:

1. **Проверка кэша:** [`_checkCache()`](../lib/ui/widgets/track_settings_sheet.dart:643) проверяет только `YoutubeCache.instance.hasFile(...)` — Dart-файловый кэш. Soulseek-треки живут в native-кэше (SQLite + файлы, ключ = sha256-cacheKey), для них `hasFile` всегда false → кнопка всегда показывает «Download», даже когда файл давно скачан.
2. **Двойная загрузка для Soulseek:** `_download()` вызывает `source.resolveStreamUrl(track)` (который для Soulseek сам качает файл в native-кэш и ждёт завершения через [`_waitForDownloadComplete()`](../lib/sources/soulseek_source.dart:415)), а затем **вторым dio.download** копирует `file://`-путь в YoutubeCache как `.mp3` — лишняя копия с неверным расширением (flac-файл сохраняется как mp3) и двойным занятием места.
3. **Нет прогресса из потока трансферов:** для Soulseek реальный прогресс идёт по EventChannel `transferEvents` ([канал](../lib/sources/soulseek_platform_channel.dart:73), события [`SoulseekTransferInfo.progress`](../lib/sources/soulseek_models.dart:356)), а `_download()` ждёт его внутри `resolveStreamUrl` без колбэка прогресса — UI может показать лишь неопределённый спиннер. Состояния «уже в кэше / качается / не начиналась» не различаются.

### 2.4. QUALITY-01 — потеря качества при деградации Track → MediaItem → Track

[`_TrackDetailsSheet._loadBitrate()`](../lib/ui/widgets/track_details_sheet.dart:39): если `track.qualityScore != null` — показывает его; иначе зовёт `source.resolveBitrate(track)` ([Soulseek-реализация](../lib/sources/soulseek_source.dart:596) читает `extra['bitrate']` → `qualityScore`). «unavailable» возникает когда оба значения null/≤0.

Для Soulseek из поиска качество есть: `_resultToTrack()` проставляет `qualityScore: result.bitrate ?? 0` и `extra['bitrate']` ([строки 323–338](../lib/sources/soulseek_source.dart:313)). Но из плеера details sheet получает Track, пересобранный в [`_showExtra()`](../lib/ui/pages/player/player_bottom_actions.dart:135) из `MediaItem` — **только id/sourceId/title/artist/duration/artworkUrl**, без `extra` и `qualityScore`. `resolveBitrate` тогда возвращает null → «unavailable». Аналогично после SESSION-01 фикса треки, восстановленные из сессии, несут `extra` (см. §3), но `qualityScore` там сохраняется — тут всё ок.

Источник данных качества уже существует на всех слоях: C# bridge извлекает `File.BitRate/SampleRate/BitDepth` из атрибутов Soulseek ([SoulseekBridge.cs:648–652](../soulseek-wrapper/SoulseekBridge.cs:648)), Dart-модель [`SoulseekSearchResult`](../lib/sources/soulseek_models.dart:243) содержит `bitrate/sampleRate/bitDepth`, `qualityLabel()` ([soulseek_source.dart:868](../lib/sources/soulseek_source.dart:868)) уже умеет строить «FLAC 24/96», «MP3 320». Данные теряются только в UI-пересборке Track.

## 3. Этап 1 — SESSION-01 фикс (P0)

### Решение

Единый формат + defensive reader. Два изменения:

1. **Писатель — [`PlayerConversions.trackToRow()`](../lib/core/player_conversions.dart:47):** заменить на `track.toMap()`-совместимый формат (ключи `id`, `source_id`, ..., `extra` как map). Это устраняет рассинхрон в корне: `toMap()/fromMap()` — уже согласованная пара, используемая историей и бэкапом. Обязательный нюанс: `extra` должен проходить через `TrackRowCodec.extraPrimitives()` (JSON-безопасность) перед `jsonEncode` — сейчас это делает только `trackToRow`.
2. **Читатель — [`Track.fromMap()`](../lib/models/track.dart:79):** сделать null-safe:
   - `id`: `m['id'] as String?` с fallback на legacy-ключ `m['track_id'] as String?`; если оба null/пустые — **пропустить запись** (см. ниже);
   - `title`/`artist`: `as String? ?? ''` (отображаемые поля — дефолты безопасны);
   - `sourceId`: `as String? ?? ''` — но трек без sourceId невоспроизводим; пустой sourceId допустим моделью (Track его не валидирует), renderинг покажет sourceId как есть;
   - `extra`: уже частично tolerant — расширить: принимать и map (`m['extra']`), и legacy-строку (`m['extra_json']` → `jsonDecode`), как это делает [`TrackRowCodec.fromRow()`](../lib/core/database/track_row_codec.dart:11).

   Пропуск битых записей: `fromMap` не может вернуть null (factory возвращает Track), поэтому фильтрация записей без id выполняется в [`PlaybackDao.loadPlaybackSession()`](../lib/core/database/playback_dao.dart:57) — `.map(...)` заменить на цикл с try/catch на каждую запись: одна битая запись не роняет всю очередь (рекомендация из §7 прошлого плана: «не стирать всю сессию из-за одной записи»). После фильтрации пересчитать `currentIndex` clamp-ом (уже есть) — но при пропуске записей до текущего индекса индекс нужно сместить на число пропущенных раньше стоящих.

### Совместимость

- Старые записи в `queue_json` (формат `track_id`/`extra_json`) продолжат читаться через legacy-ключи — восстановление после обновления без очистки данных.
- Desktop-формат (`toMap()`) не меняется.
- Другие потребители fromMap (history, backup) пишут/читают `toMap()` — их сценарии не затронуты; fallback-логика в fromMap для них прозрачна.

### Тесты

- [test/models/track_test.dart](../test/models/track_test.dart): fromMap с null-полями, legacy-ключами `track_id`/`extra_json` (строка-JSON в extra_json), пустым extra, round-trip toMap/fromMap, полный набор текущих кейсов остаётся зелёным.
- [test/database/dao_test.dart](../test/database/dao_test.dart): savePlaybackSession→loadPlaybackSession round-trip в новом формате; очередь из смешанных записей (новый формат + legacy + одна битая без id) — битая пропущена, остальные восстановлены, index/position корректны; пустая очередь → null.
- Регресс: `flutter test` — все 634 существующих теста зелёные.

### Критерии готовности этапа

- [ ] Мобильная сессия (в т.ч. с Soulseek-треками в очереди) сохраняется и восстанавливается: очередь, индекс, позиция, título/artist в шторке.
- [ ] Ни при каких данных `queue_json` restore не выбрасывает unhandled — максимум пропуск отдельных записей.
- [ ] `flutter analyze` чист, `flutter test` без регрессий.

## 4. Этап 2 — данные о качестве в модели/канале (фундамент для UI-задач)

### 4.1. MediaItem extras — носитель качества через плеер

[`PlayerConversions.toMediaItem()`](../lib/core/player_conversions.dart:24) кладёт в `extras` только `sourceId/trackId/originalArtworkUrl/qualityLabel`. Расширить:

- добавить `qualityScore` (int) и `bitrate`/`sampleRate`/`bitDepth`/`extension`/`cacheKey` из `track.extra` (для Soulseek);
- [`_showExtra()` в player_bottom_actions.dart](../lib/ui/pages/player/player_bottom_actions.dart:135) пересобирает Track уже с `qualityScore` и `extra` из `m.extras` — тогда details sheet и track settings sheet получают полное качество без изменения их логики.

Формат extras Map<String, dynamic> уже допускает произвольные ключи — backward-совместимо (null-safe чтение).

### 4.2. Track из SoulseekCacheEntry — фабрика в soulseek_source

Добавить в [`SoulseekSource`](../lib/sources/soulseek_source.dart) видимый для UI метод:

```dart
Track trackFromCacheEntry(SoulseekCacheEntry entry) => Track(
  id: entry.cacheKey,             // cacheKey как идентификатор
  sourceId: sourceId,
  title: entry.title ?? basenameWithoutExt(entry.localPath),
  artist: entry.artist ?? 'Unknown',
  duration: entry.durationSeconds != null
      ? Duration(seconds: entry.durationSeconds!) : null,
  extra: {'cacheKey': entry.cacheKey},  // достаточно для cache hit
);
```

`extra.cacheKey` — ключевой момент: [`_getOrCreateCacheKey()`](../lib/sources/soulseek_source.dart:760) возвращает его без требования peerUsername/remoteFilename/sizeBytes, а `resolveStreamUrl()` первым шагом делает [`getCacheEntry(cacheKey)`](../lib/sources/soulseek_source.dart:352) → cache hit → `localPath`. Повторная загрузка не нужна и не начнётся. Расширение localPath (flac/mp3) можно взять из `entry.localPath` через существующий `removeExtension`-хелпер — для `qualityLabel` (формат из расширения).

### 4.3. Расширение SoulseekCacheEntry (опционально, только если решим показывать качество в кэш-листе)

В native-БД `cache_entries` нет колонок bitrate/extension-атрибутов, но `extension` в БД **уже есть** ([SoulseekDatabase.kt: `COL_EXTENSION`](../android/app/src/main/kotlin/com/player/player/SoulseekDatabase.kt:57)) — просто не пробрасывается в Dart-модель `SoulseekCacheEntry` и в мапперы [SoulseekPlugin.kt:531/594](../android/app/src/main/kotlin/com/player/player/SoulseekPlugin.kt:531). Минимальное расширение: добавить `extension` в Dart-модель + в два Kotlin-маппера. Битрейт в БД отсутствует — для кэш-плиток достаточно `extension` (метка «FLAC»/«MP3»), точный битрейт показывается в деталях из extra трека (если известен) или «unavailable» остаётся для старых записей без данных. Изменения Kotlin → требуется пересборка APK, но **не AAR** (Kotlin-слой в `:app`, не в обёртке).

### Тесты этапа 2

- [test/sources/soulseek_source_test.dart](../test/sources/soulseek_source_test.dart): `trackFromCacheEntry` — заполнение полей, fallback'и, cache hit в resolveStreamUrl для трека с только `extra.cacheKey` (через fake-канал, паттерн уже есть в тесте).
- [test/models/track_test.dart](../test/models/track_test.dart) или отдельный тест conversions: toMediaItem extras содержит качество; пересборка Track из extras восстанавливает qualityScore/extra.
- [test/sources/soulseek_models_test.dart](../test/sources/soulseek_models_test.dart): SoulseekCacheEntry.fromMap с новым полем `extension` (и без него — старые записи).

## 5. Этап 3 — UI: кликабельный кэш, статус загрузки в плеере, качество в деталях

### 5.1. Кликабельный кэш (CACHE-UI-01)

В [`soulseek_cache_sheet.dart`](../lib/ui/widgets/soulseek_cache_sheet.dart):

1. Построить `Track` через `SoulseekSource.trackFromCacheEntry(entry)` (после рефреша, рядом с `_CacheItem`).
2. `_CacheTile` → обернуть в `InkWell`/`GestureDetector` (по образцу [`SearchTrackTileList`](../lib/ui/pages/search/search_track_tiles.dart:43)):
   - `onTap`: воспроизвести. Кэш-лист показывает **только complete-записи** (`entry.complete`, см. `_refresh()` — incomplete идут с `Icons.downloading_rounded`, но для простоты тап обрабатываем только для complete) — вызвать `player.setQueue([track], startIndex: 0)` (single-track queue; кэш-лист не упорядочен как альбом, паттерн «очередь = весь список» как в поиске здесь не обязан сохраняться, но допустим вариант «очередь = все complete-треки, старт с выбранного» — выбрать при реализации; рекомендую второй вариант для консистентности с поиском).
   - `onLongPress`: `showTrackSettingsSheet(context, track: track)` — автоматически даёт add to playlist, play next, details, download-status (после 5.2), delete native-кэша (осторожно: delete в settings sheet работает с YoutubeCache — см. риск R3).
3. Визуал: иконка статуса уже есть (pinned/complete/downloading); добавить chevron или hint «Tap to play» не обязательно.

### 5.2. Статус загрузки на кнопке плеера (PLAYER-DL-01)

Кнопка — тайл Download в [`_SettingsGroup`](../lib/ui/widgets/track_settings_sheet.dart:778). Требуемые состояния:

| Состояние | Источник | Отображение |
|---|---|---|
| Уже в кэше (native, complete) | `getCacheEntry(cacheKey).complete` | `Icons.download_done_rounded`, accent, «Cached» |
| Идёт загрузка | подписка на `transferEvents` по downloadId `dl_$cacheKey` | `CircularProgressIndicator(value: progress)` + «Downloading… N%» (progress из [`SoulseekTransferInfo.progress`](../lib/sources/soulseek_models.dart:356)) |
| Не начиналась | ничего из выше | текущий вид «Download» |

Реализация в `_SettingsGroupState`:

1. **Проверка кэша — source-aware:** для `track.sourceId == 'soulseek'` вместо/в дополнение к YoutubeCache-проверке звать `SoulseekPlatformChannel.instance.getCacheEntry(cacheKey)` (cacheKey из `track.extra['cacheKey']` или пересчёт). Есть нюанс: у трека, пересобранного из MediaItem, extra есть после этапа 2 — если cacheKey отсутствует и нет триады полей, fallback на текущее поведение (YoutubeCache).
2. **Подписка на прогресс:** подписаться на `SoulseekSource.transferEvents` (через `SourceRegistry.instance.get('soulseek') as SoulseekSource`), фильтровать по `event.downloadId == 'dl_$cacheKey'`, обновлять `_progress` (setState). Отписка в dispose. Событие `completed` → `_isCached = true`, progress = null; `failed/cancelled` → сброс + snackbar. Снимок при подписке (snapshot на onListen) покрывает случай «лист открыли во время загрузки».
3. **Действие тапа для Soulseek:** вызвать `SoulseekSource.prefetch(track)` (уже стартует native-загрузку через startDownload с dedupe по downloadId) вместо старого `_download()` с dio — исключает двойную загрузку и неверное расширение файла. Прогресс придёт из подписки п.2. Для не-Soulseek источников `_download()` не меняется. **Удаление кэша для Soulseek:** `_platform.removeCache(cacheKey)` + `source.forgetCacheKey(cacheKey)` — паттерн уже реализован в [кэш-листе `_delete()`](../lib/ui/widgets/soulseek_cache_sheet.dart:135).

### 5.3. Качество в деталях трека (QUALITY-01)

1. **Основной фикс — этап 2** (extras через MediaItem): details sheet получает `qualityScore != null` → показывает «N kbps» без вызова resolveBitrate. Дополнительно: `qualityScore` для Soulseek FLAC часто null (битрейт есть не у всех lossless-атрибутов) — тогда `resolveBitrate` вернёт null → «unavailable». Поэтому:
2. **Расширить `_BitrateRow`/details:** для Soulseek-треков при недоступном точном битрейте показывать `qualityLabel` из extras (например «FLAC 24/96») вместо «unavailable» — данные уже в `track.qualityLabel` (приходит из поиска) и в `extra` (после этапа 2). Формат строки: значение qualityLabel как есть.
3. Для треков, восстановленных из кэша (кэш-лист → детали через long-press): extension в extra (этап 4.3) даёт метку «FLAC»/«MP3» минимум; точный битрейт — если сохранился в extra трека, иначе честное «unavailable» (метаданные файла из DB недоступны — колонки нет; чтение тегов из файла — вне scope).

### Тесты этапа 3

- [test/ui/widget_test.dart](../test/ui/widget_test.dart) (или новый test/ui/track_settings_sheet_test.dart): тайл Download показывает «Cached» при native cache hit (fake-канал), прогресс при transfer-событии, сброс после failed; не-Soulseek путь не затронут.
- Новый тест кэш-листа (виджет-тест с fake `SoulseekPlatformChannel`): тап по complete-тайлу вызывает setQueue с Track у которого `extra.cacheKey` заполнен; long-press открывает settings sheet.
- Details sheet: для Track с qualityLabel и без qualityScore показывает qualityLabel; «unavailable» только при полном отсутствии данных.

## 6. Верификация на устройстве

Устройство: 3B6F5WE8GCL1A3HD, adb = `C:\Users\goddammit\AppData\Local\Android\Sdk\platform-tools\adb.exe` (НЕ `C:\Windows\System32\adb.cmd` — битый шим). Все команды из корня проекта.

```cmd
:: Сборка debug (Kotlin-изменения этапа 2.3 требуют пересборки APK; AAR не трогаем)
flutter build apk --debug
%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe -s 3B6F5WE8GCL1A3HD install -r build\app\outputs\flutter-apk\app-debug.apk

:: Логи на прогоне (фильтр PlayerService/Soulseek)
%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe -s 3B6F5WE8GCL1A3HD logcat -v threadtime | findstr /i "PlayerService Soulseek flutter"
```

Сценарии приёмки (по этапам):

1. **SESSION-01:** воспроизвести Soulseek-трек (и смешанную очередь Soulseek + YouTube) → свернуть/убить приложение → запустить: очередь и текущий трек восстановлены, в логе нет «Session restore failed»; повторить с очередью, сохранённой старой версией APK (upgrade без очистки данных) — legacy-записи читаются.
2. **Кэш-лист:** открыть Soulseek cache → тап по complete-файлу → мгновенное воспроизведение из localPath (без сетевой загрузки; в логе `[Soulseek] cache hit`); long-press → track settings sheet → add to playlist / play next работают; удалить из sheet'а — исчезает из списка.
3. **Кнопка Download:** Soulseek-трек, не в кэше → «…» в плеере → Download → прогресс растёт на кнопке, по завершении «Cached»; открыть sheet повторно — «Cached»; тап → удаление native-кэша (файла в списке кэша больше нет); во время загрузки свернуть лист и открыть снова — прогресс продолжается (snapshot).
4. **Качество:** Soulseek-трек в плеере → «…» → Details → битрейт/метка качества отображаются («320 kbps» / «FLAC 24/96»), не «unavailable»; для YouTube-треков поведение неизменно.
5. **Регресс:** полный `flutter analyze` + `flutter test` (634+ passed), воспроизведение YouTube/SoundCloud из поиска и после restore сессии не сломано.

## 7. Риски и совместимость

| Риск | Митигция |
|---|---|
| R1: Изменение `trackToRow` меняет формат `queue_json` — старая установленная версия не прочитает новую запись при downgrade | Downgrade не поддерживается политикой приложения; новые записи читаются новой версией, legacy-поддержка в fromMap покрывает upgrade-путь |
| R2: `fromMap` с fallback-ключами меняет контракт для history/backup | Их writer'ы используют `toMap()` — читаются как раньше; fallback-ветки для них не активируются. Тесты history/backup в прогоне 634 подтверждают |
| R3: Delete в track settings sheet для Soulseek-трека удалит YoutubeCache-запись, а не native | В 5.2 п.3 разделить ветку удаления по sourceId; кэш-лист остаётся источником истины для native-удаления |
| R4: Подписка transferEvents в sheet — утечка подписки при закрытии sheet во время загрузки | Отписка в `dispose()`; сама загрузка не отменяется (родной lifecycle TransfersManager) |
| R5: `setQueue` из кэш-листа перетирает текущую очередь пользователя | То же поведение, что у поиска (принятый UX); alternative — `insertToQueue` только через long-press |
| R6: Kotlin-изменение (extension в мапперах) требует пересборки APK, но не AAR | `COL_EXTENSION` уже в схеме БД v2 — миграция не нужна, изменение только в маппинге |
| R7: Прогресс загрузки недоступен, пока EventChannel не подписан (sheet закрыт) | Snapshot при onListen покрывает восстановление прогресса; поллинг в `_waitForDownloadComplete` — существующая страховка |

**AAR-пересборка не требуется:** все четыре задачи решаются в Dart + Kotlin (мапперы `:app`-модуля). `SoulseekBridge.cs`/`Soulseek.NET` не меняются — атрибуты BitRate/SampleRate/BitDepth уже извлекаются ([SoulseekBridge.cs:648](../soulseek-wrapper/SoulseekBridge.cs:648)). Достаточно `flutter build apk` (Gradle пересоберёт Kotlin-слой).

## 8. Что НЕ входит в серию (scope guard)

- Не менять SoulseekBridge.cs / SoulseekDtos.cs / Soulseek.NET — AAR остаётся как есть.
- Не добавлять колонки bitrate/sampleRate в native-БД и не читать аудио-теги из файлов (для кэш-треков качество ограничено extension-меткой).
- Не трогать FGS, retry/backoff, валидацию кэша, LRU — закрыто в прошлой серии.
- Не менять `_download()` (dio-путь) для не-Soulseek источников.
- Не переиспользовать YoutubeCache для Soulseek (не дублировать хранение).
- Не реализовывать prebuffer/воспроизведение частичных файлов; incomplete-записи в кэш-листе остаются некликабельными (кроме существующих действий pin/delete).
- Никаких изменений manifest/разрешений.

## 9. Порядок исполнения и чек-лист

1. [ ] Этап 1: SESSION-01 — trackToRow → toMap-формат, null-safe fromMap + legacy-ключи, per-entry skip в PlaybackDao, тесты track/dao.
2. [ ] Этап 2: extras в toMediaItem + пересборка Track в _showExtra; trackFromCacheEntry; (опц.) extension в SoulseekCacheEntry + Kotlin-мапперы.
3. [ ] Этап 3.1: кликабельный кэш-лист (onTap → setQueue, onLongPress → settings sheet).
4. [ ] Этап 3.2: source-aware Download-тайл (native cache check, transferEvents-прогресс, prefetch-действие, native-delete).
5. [ ] Этап 3.3: качество в details sheet (qualityScore из extras, qualityLabel-fallback).
6. [ ] `flutter analyze` + `flutter test` — без регрессий (базовая линия 634 passed / 4 skipped).
7. [ ] Верификация на устройстве по сценариям §6, логи сохранить.

Коммиты: по одному на этап/подзадачу; этап 1 независим и может выпускаться отдельно.
