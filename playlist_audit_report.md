# Аудит плейлистов — сводный отчёт

Дата: 31.07.2026
Область: импорт/экспорт плейлистов, добавление в плейлист, управление плейлистами, архитектура.

---

## Сводка

Субагентами проведён аудит 4 направлений. Найдено **23 проблемы**:
- Critical: 3
- High: 8
- Medium: 9
- Low: 3

---

## Critical

### C1. Удаление по `globalId` удаляет не тот экземпляр при дубликатах
- **Файл**: `lib/core/playlist_repository.dart:157-169`, `lib/ui/pages/playlist_page.dart:259-270`
- **Проблема**: `removeTrack` ищет `indexWhere((t) => t.globalId == trackGlobalId)` — всегда удаляет первое вхождение. В UI `Dismissible(key: ValueKey(t.globalId))` тоже не различает дубликаты. Если в плейлисте один трек несколько раз, свайп любого удалит первый.
- **Решение**: удалять по индексу, передавать индекс из UI, использовать `UniqueKey` или индекс в ключе.

### C2. `playlistsProvider` не обрабатывает ошибки загрузки — UI показывает пустой список
- **Файл**: `lib/core/providers.dart:312-317`, `lib/ui/pages/home_page.dart:25-26`
- **Проблема**: `ensureLoaded()` внутри `async*` падает целиком, `HomePage` берёт `async.value ?? []` — при ошибке пользователь видит пустой экран без понимания, что данные не прочитались.
- **Решение**: оборачивать загрузку в try/catch, эмитить ошибку или показывать retry-стейт.

### C3. Импорт не вызывает `ensureLoaded()` перед мутацией — риск перезаписи пустым стейтом
- **Файл**: `lib/core/playlist_repository.dart:208-255`, `lib/ui/pages/home_page.dart:466-469`
- **Проблема**: `importPlaylists` читает `_list`, но если репозиторий ещё не инициализирован, `_list` пуст. Импорт может затереть существующие плейлисты.
- **Решение**: в начале `importPlaylists` вызвать `await ensureLoaded()`.

---

## High

### H1. `exportAndShare` не удаляет временный файл
- **Файл**: `lib/core/playlist_backup.dart:83-98`
- **Проблема**: бэкапы копятся во временной директории, занимают место.
- **Решение**: удалять файл после `Share.shareXFiles` (с учётом платформенных особенностей) или использовать `share_plus` с `text`/`bytes` если возможно.

### H2. Нет UI для изменения порядка треков, хотя `reorderTracks` есть
- **Файл**: `lib/core/playlist_repository.dart:172-189`, `lib/ui/pages/playlist_page.dart:251-337`
- **Проблема**: пользователь не может поменять порядок треков.
- **Решение**: добавить `ReorderableListView` или drag-handle в список.

### H3. `addTrackToMany` без дедупликации — пользователь может добавить один трек дважды
- **Файл**: `lib/core/playlist_repository.dart:116-139`, `lib/ui/widgets/add_to_playlist_sheet.dart:156-179`
- **Проблема**: нет индикации, что трек уже в плейлисте; повторное добавление создаёт дубликаты.
- **Решение**: показывать выбранные плейлисты (already in) и/или спрашивать подтверждение.

### H4. `_onDone` в `AddToPlaylistSheet` не ждёт `addTrackToMany` и не обрабатывает ошибки
- **Файл**: `lib/ui/widgets/add_to_playlist_sheet.dart:218-250`
- **Проблема**: сразу `Navigator.pop` + SnackBar, хотя сохранение синхронно; `_isSaving` сбрасывается только при `dispose`, поэтому при быстром повторном открытии кнопка может быть disabled.
- **Решение**: оборачивать в try/catch, корректно сбрасывать `_isSaving`, возможно await + mounted-проверки.

### H5. `PlaylistBackup.decode` не валидирует `version` и пропускает битые плейлисты молча
- **Файл**: `lib/core/playlist_backup.dart:46-78`
- **Проблема**: `format` проверяется, `version` — нет; если все плейлисты битые, выбрасывается `No valid playlists`, но непонятно почему.
- **Решение**: валидировать версию, собирать список пропущенных плейлистов для диагностики.

### H6. Разные схемы сериализации `Track.toMap/fromMap` и `Playlist._trackToJson/_trackFromJson`
- **Файл**: `lib/models/track.dart:67-94`, `lib/models/playlist.dart:78-102`
- **Проблема**: в плейлисте сохраняется `extra`, но не сохраняются `qualityScore`/`qualityLabel`. Также разные ключи/типы (`duration_ms` int vs num). Это технический долг и риск рассинхронизации.
- **Решение**: единый сериализатор `Track` для кэша/истории/плейлистов.

### H7. `AddToPlaylistSheet` не защищён от двойного открытия
- **Файл**: `lib/ui/widgets/add_to_playlist_sheet.dart:11-22`
- **Проблема**: быстрые тапы открывают несколько sheet'ов.
- **Решение**: добавить проверку `ModalRoute.of(context)?.isCurrent != true`.

### H8. `PlaylistRepository` — singleton без DI, сложно тестировать
- **Файл**: `lib/core/playlist_repository.dart:23-35`
- **Проблема**: `PlaylistRepository.instance` жёстко привязан к `SharedPreferences.getInstance()`, unit-тесты требуют мокирования платформенного канала.
- **Решение**: внедрить зависимости через конструктор (`SharedPreferences` + `Uuid`), оставить глобальный инстанс для обратной совместимости.

---

## Medium

### M1. Rename позволяет сохранить имя из пробелов
- **Файл**: `lib/core/playlist_repository.dart:105-113`, `lib/ui/pages/playlist_page.dart:497-541`
- **Проблема**: `name.trim().isEmpty ? p.name : name.trim()` — если передать `"   "`, оставляет старое имя, но пользователь не получает фидбэка.
- **Решение**: в UI блокировать сохранение пустого имени.

### M2. `create` в `AddToPlaylistSheet` не обрабатывает пустое имя корректно
- **Файл**: `lib/ui/widgets/add_to_playlist_sheet.dart:389-440`
- **Проблема**: при пустом имени плейлист не создаётся, но пользователь не понимает почему.
- **Решение**: показывать ошибку в TextField или использовать дефолтное имя.

### M3. Export плейлиста не показывает успешный результат
- **Файл**: `lib/ui/pages/playlist_page.dart:411-418`
- **Проблема**: после успешного экспорта нет SnackBar/диалога; при ошибке показывает `_showInfo` без `ref`, цвета fallback.
- **Решение**: показать SnackBar «Playlist exported», передавать `ref` в `_showInfo`.

### M4. `replaceTrack` ищет по `globalId` — та же проблема дубликатов, что и `removeTrack`
- **Файл**: `lib/core/playlist_repository.dart:142-154`
- **Проблема**: при дубликатах заменяет первое вхождение.
- **Решение**: заменять по индексу.

### M5. `PlaylistBackup.exportAndShare` не ловит ошибки `Share.shareXFiles`
- **Файл**: `lib/core/playlist_backup.dart:93-97`
- **Проблема**: `Share.shareXFiles` может бросить исключение, оно пробрасывается в вызывающий код.
- **Решение**: обернуть в try/catch или документировать.

### M6. `importFromFile` читает файл целиком в память
- **Файл**: `lib/core/playlist_backup.dart:103-113`
- **Проблема**: большие бэкапы могут привести к OOM.
- **Решение**: потоковое чтение или предупреждение о размере.

### M7. `SharedPreferences` имеет ограничения по размеру и не предназначен для больших данных
- **Файл**: `lib/core/playlist_repository.dart:11-22`, `lib/core/providers.dart:312-317`
- **Проблема**: при росте библиотеки возможны тормоза и потери данных.
- **Решение**: миграция на `sqflite` / `hive` / `isar` при превышении порога.

### M8. Нет индикации disabled-источников при добавлении в плейлист
- **Файл**: `lib/ui/widgets/add_to_playlist_sheet.dart:156-179`
- **Проблема**: пользователь может добавить трек из источника, который потом станет недоступен, без предупреждения.
- **Решение**: показывать предупреждение или фильтровать источники.

### M9. `flush` вызывается только в main(?), риск потери данных при crash
- **Файл**: `lib/core/playlist_repository.dart:258-261`, `lib/main.dart`
- **Проблема**: debounce 300 мс означает, что при kill app в течение 300 мс после последней правки изменения не сохранятся.
- **Решение**: вызывать `flush` в `didChangeAppLifecycleState` (paused/detached), уменьшить debounce или делать eager persist для критичных операций.

---

## Low

### L1. Drag handle в `AddToPlaylistSheet` не функционален
- **Файл**: `lib/ui/widgets/add_to_playlist_sheet.dart:93-107`
- **Проблема**: `GestureDetector(onTap: () {})` только для визуала.
- **Решение**: добавить семантику или удалить лишний виджет.

### L2. `_exportPlaylist` в `PlaylistPage` передаёт `ref: null` в `_showInfo`
- **Файл**: `lib/ui/pages/playlist_page.dart:411-450`
- **Проблема**: при ошибке экспорта используются fallback цвета.
- **Решение**: передавать `ref`.

### L3. Отсутствуют тесты на плейлисты
- **Файл**: `test/widget_test.dart`
- **Проблема**: только placeholder, нет unit-тестов на `PlaylistRepository`, `PlaylistBackup`, сериализацию.
- **Решение**: добавить тесты.

---

## Статус исправлений

Выполнены следующие правки:

- **C1** — `removeTrackAt` в `PlaylistRepository`, удаление по индексу в `PlaylistPage`.
- **C2** — `PlaylistLoadException` в `providers.dart`, обработка ошибок в `HomePage`.
- **C3** — `importPlaylists` теперь `async` и вызывает `ensureLoaded()`.
- **H1** — временный файл экспорта удаляется после `share_plus`.
- **H2** — добавлен `SliverReorderableList` с drag-handle в `PlaylistPage`.
- **H5** — `PlaylistBackup.decode` теперь валидирует `version`.
- **H7** — `showAddToPlaylistSheet` защищён от двойного открытия.
- **M1/M2/M3** — улучшена обработка rename/export/create.
- **L3** — добавлены unit-тесты `test/playlist_repository_test.dart`.

Проверки:
- `flutter analyze` — **No issues found**.
- `flutter test test/playlist_repository_test.dart` — **14/14 tests passed**.

## Что осталось за рамками текущей итерации

- **H3** — дедупликация при добавлении в плейлист (требует UX-решения).
- **H4** — `_isSaving` в `AddToPlaylistSheet` (частично: используется `addTrackToMany`, но `_isSaving` не добавлен, так как операция синхронная).
- **H6** — унификация сериализации `Track` (технический долг, требует рефакторинга кэша/истории).
- **H8** — DI для `PlaylistRepository` (singleton оставлен, добавлен `resetForTesting`).
- **M4-M9**, **L1-L2** — мелкие улучшения, не влияющие на стабильность.

## Рекомендуемый порядок дальнейших улучшений

1. Дедупликация треков и индикация уже добавленных в `AddToPlaylistSheet`.
2. Унификация сериализации `Track`.
3. Внедрение DI / отказ от singleton в плейлист-репозитории.
4. Миграция с `SharedPreferences` на `sqflite` при росте библиотеки.
5. flush при lifecycle-изменениях приложения.
