# План: стриминг Soulseek (воспроизведение во время загрузки)

**Сложность**: Medium
**Статус**: фазы 1–4 выполнены, фаза 5 (устройство) — ожидает (2026-10-07)

## Суть

Сейчас `SoulseekSource.createAudioSource` ждёт полной загрузки файла
(`_waitForDownloadComplete`) и только потом отдаёт `AudioSource.uri(file)`.
C# bridge пишет данные последовательно в `<cacheDir>/<cacheKey>.part`
(Soulseek.NET, `FileMode.Create/Append`), по завершении валидирует и делает
atomic rename в `<cacheKey>.<ext>`. Значит, байты из `.part` можно отдавать
плееру по мере появления.

Решение: собственный `StreamAudioSource` (just_audio, тот же механизм локального
прокси, что у уже используемого `LockCachingAudioSource`), который читает
`.part` «хвостом»: отдаёт то, что уже записано, и ждёт прироста файла, пока
загрузка не завершится или не упадёт.

## Требования

- Воспроизведение начинается после первых ~N КБ, а не после всего файла.
- `sourceLength` = заявленный `sizeBytes`, ExoPlayer видит полную длительность.
- Перемотка за пределы скачанного = буферизация (ждём байты), не ошибка.
- Ошибка/отмена загрузки во время игры → ошибка стрима → штатная логика
  retry/skip плеера.
- Завершённая загрузка: rename `.part` → final не ломает открытый поток
  (fd остаётся валиден на Linux/Android); новые range-запросы после
  завершения читают финальный файл.
- Индексация кэша (`_recordCacheKey`, единый кэш) — как сейчас, по завершению.
- URL/пути в БД не сохраняются (правило проекта).
- Только Android (Soulseek). Windows/iOS не затрагиваются.

## Паттерны

| Категория | Источник | Паттерн |
|---|---|---|
| DI канала | `lib/sources/soulseek_source.dart:48` | `SoulseekChannel` abstract, фейки в тестах |
| Ожидание загрузки | `soulseek_source.dart:779` | события + поллинг + общий таймаут, `SoulseekException` |
| Ошибки | `soulseek_models.dart` | `SoulseekException(code, message, retryable:)` |
| Контракт канала | `SoulseekPlugin.kt:520` | map-ответ `startDownload`, правка Dart+Kotlin |
| StreamAudioSource | `muzmo_source.dart:436` | `LockCachingAudioSource` уже в проде |
| Тесты | `test/sources/soulseek_source_test.dart:37` | `_TestChannel implements SoulseekChannel` |

## Файлы

| Файл | Действие | Зачем |
|---|---|---|
| `android/.../SoulseekPlugin.kt` | UPDATE | `partPath` в ответе `startDownload` |
| `lib/sources/soulseek_models.dart` | UPDATE | `SoulseekDownloadResult.partPath` (nullable) |
| `lib/sources/soulseek_stream_audio_source.dart` | CREATE | tail-reader `.part` → `StreamAudioSource` |
| `lib/sources/soulseek_source.dart` | UPDATE | стриминговый путь в `createAudioSource` |
| `lib/core/soulseek_settings_repository.dart` + страница настроек | UPDATE | переключатель «Играть во время загрузки» |
| `test/sources/soulseek_stream_audio_source_test.dart` | CREATE | юнит-тесты читателя на временных файлах |
| `test/sources/soulseek_source_test.dart` | UPDATE | стриминговый путь / fallback |
| `CHANGELOG.md` | UPDATE | запись в Unreleased |

## Фазы

### Фаза 1. Контракт канала: путь к `.part` ✅
- Kotlin: в `startDownload` добавить `"partPath" to cacheManager.ensurePartFile(cacheKey).absolutePath`
  (только когда не cache hit). Путь совпадает с C# (`cacheDirectoryPath` + `cacheKey + ".part"`,
  cacheKey — sha256 hex, санитизация no-op с обеих сторон).
- Dart: `SoulseekDownloadResult.partPath` (nullable, старые фейки не ломаются).
- Тест: `fromMap` с/без `partPath`.

### Фаза 2. `SoulseekStreamAudioSource` (чистый Dart, TDD) ✅
- Вход: `partPath`, `totalBytes`, `contentType`, `Future<String> completion`
  (финальный путь или ошибка), `pollInterval`, `stallTimeout`.
- `request(start, end)`: открыть `.part` (или финальный файл, если загрузка
  уже завершилась), цикл чтения чанков; нет данных → ждать прироста; ошибка
  `completion` → ошибка стрима; нет прироста дольше `stallTimeout` → ошибка.
- Отмена подписки (перемотка) закрывает `RandomAccessFile`.
- Тесты: чтение растущего файла, range-запрос, ожидание данных за границей
  записанного, rename во время чтения, ошибка загрузки, stall timeout.

### Фаза 3. Интеграция в `SoulseekSource.createAudioSource` ✅
- Кэш complete → файл (как сейчас). `startDownload` cacheHit → файл.
- Иначе при наличии `partPath` и включённом стриминге:
  `completion = _waitForDownloadComplete(id)` (индексация кэша сохраняется),
  ждать стартовый порог (+256 КБ к начальному размеру `.part`, чтобы
  остаток прошлой попытки не считался стартом; или завершение) с тем же
  `downloadTimeout` — очередь у пира/оффлайн-пир по-прежнему дают ошибку
  до `setAudioSource`; вернуть `SoulseekStreamAudioSource`.
- Иначе — старый путь (полная загрузка).
- Тесты на фейковом канале + временном файле.

### Фаза 4. Настройка ✅
- `soulseek_streaming_enabled` (по умолчанию true) в репозитории настроек
  Soulseek + переключатель на `SoulseekSettingsPage`.

### Фаза 5. Проверка на устройстве и замеры
- logcat: время от тапа до звука до/после (MP3 320 и FLAC), перемотка
  вперёд за буфер, обрыв пира в середине, завершение загрузки во время игры.
- Проверить, что `FileShare.None` в Soulseek.NET не мешает читать `.part`
  (ожидается advisory flock / проверка только внутри Mono — не мешает).
- Убрать временную диагностику, CHANGELOG.

## Риски

| Риск | Вероятность | Митигация |
|---|---|---|
| Блокировка `.part` со стороны .NET (FileShare.None) | Низкая | Проверка на устройстве в фазе 5; fallback — выключенный стриминг |
| M4A/ALAC с moov в конце: ExoPlayer запросит хвост | Средняя | Range-запрос просто ждёт данные → поведение как сейчас (ждём файл) |
| Перемотка далеко вперёд | Средняя | Буферизация до прихода байтов; Soulseek качает последовательно |
| Обрыв пира в середине: Kotlin ретраит с offset | Средняя | `stallTimeout` щедрый (= `downloadTimeout`), PAUSED/retry не валят стрим |
| Валидация C# отклонила файл после проигрывания | Низкая | `completion` с ошибкой → ошибка стрима, `.part` удалён bridge'ем |
| Retry плеера вызывает evict → `.part` удаляется, загрузка с нуля | Средняя | Приемлемо для MVP; отметить для follow-up |
| Прокси just_audio для StreamAudioSource — experimental API | Низкая | Уже используется `LockCachingAudioSource` |

## Итоги ревью (ecc:flutter-reviewer) и follow-up

Исправлено:
- Остаток `.part` прошлой попытки проходил порог старта → порог считается
  как прирост от начального размера.
- Отменённый читатель (перемотка/переподключение ExoPlayer) держал файл
  открытым до таймаута → `StreamController` + `onCancel` будит ожидание.
- `stallTimeout` 2 мин → 45 с: ExoPlayer (DefaultHttpDataSource, read
  timeout 8 с) сдаётся примерно через 40 с без прогресса.

Известные ограничения / follow-up:
- Перемотка далеко за скачанную часть и M4A с moov в конце: ExoPlayer
  ждёт ~40 с, потом ошибка. Варианты: ограничивать перемотку в UI
  скачанной долей; для m4a/alac не стримить.
- Ошибка стрима посреди воспроизведения только логируется плеером (как у
  остальных источников) — нет авто-повтора с текущей позиции.
- Ожидатель завершения загрузки живёт до конечного состояния трансфера
  (до `streamDownloadTimeout` = 1 ч) и после пропуска трека; нужен
  dispose-хук из плеера, если пулы поллеров станут заметны.
- Retry плеера вызывает evict → `.part` удаляется, загрузка с нуля.

## Приёмка

- [x] `flutter analyze` чистый, `flutter test` зелёный (828)
- [ ] Новый трек Soulseek начинает играть до окончания загрузки (замер в logcat)
- [ ] Завершённая загрузка попадает в кэш и единый список кэшированных треков
- [ ] Ошибка загрузки в середине — переход к retry/skip, без зависания
- [x] CHANGELOG обновлён
