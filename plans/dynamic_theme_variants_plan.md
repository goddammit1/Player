# План: выбор из пяти тем (Fixed / Classic / Perceptual / Mesh / Blur)

**Сложность**: Medium
**Статус**: выполнен (2026-10-08)

## Суть

Сейчас тем две: `AppThemeMode.fixed` и `AppThemeMode.dynamic` (HSL-экстрактор
из `dynamic_colors.dart` поверх `palette_generator`). Нужен один список из пяти
тем:

| Тема | Цвета интерфейса | Фон страницы плеера |
|---|---|---|
| Fixed | фиксированные `AppColors.fixed` | чёрный градиент (как сейчас) |
| Classic | текущий HSL-алгоритм без изменений | вертикальный градиент (как сейчас) |
| Perceptual | новый алгоритм на HCT (`material_color_utilities`) | вертикальный градиент из перцептивной палитры |
| Mesh | Perceptual | анимированный mesh из 4 цветов обложки (fragment shader) |
| Blur | Perceptual | размытая обложка + затемнение |

Mesh и Blur меняют только фон страницы плеера (`PlayerContent`). Остальные
экраны получают однотонный `background` из палитры Perceptual.

## Требования

- Выбор сохраняется в `settings` под тем же ключом `app_theme_mode`. Значение
  `dynamic` остаётся именем Classic, чтобы у пользователей с сохранённой
  dynamic-темой ничего не поменялось. Схема БД не меняется, миграция не нужна.
- Classic визуально идентичен текущей dynamic-теме: `PaletteExtractor` не
  трогаем.
- Perceptual: контраст иконки к кнопке Play ≥ 3:1, текста к фону ≥ 4.5:1 для
  любого seed (по построению через tone HCT).
- Mesh: анимация работает только пока плеер развёрнут. `PlayerContent` всегда
  смонтирован в `NowPlayingOverlay` (скрыт через `Opacity`,
  `now_playing_overlay.dart:144`), поэтому тикер нужно глушить явно.
- Blur: без покадровой анимации размытия; обложка декодируется в маленьком
  размере и растягивается.
- Fallback: если шейдер не загрузился или обложки нет, рисуется обычный
  градиент.
- Импорт бэкапа уже вызывает `appThemeModeProvider.reload()`
  (`backup_page.dart:139`), новые значения подхватятся без доработок.

## Паттерны

| Категория | Источник | Паттерн |
|---|---|---|
| Настройка-enum | `lib/core/providers/appearance_provider.dart` | `StateNotifier` + `AppDatabase.getSetting/setSetting`, `orElse` на fixed |
| Палитра по URL | `global_theme_provider.dart:22` | `FutureProvider.autoDispose.family`, ошибки → `AppColors.fixed` |
| Анимация палитры | `global_theme_provider.dart:119` | `Ticker` + `AppColors.lerp` |
| Фон плеера | `player_page.dart:58` | `BoxDecoration(LinearGradient)` |
| Тесты настроек | `test/state/providers_test.dart:160` | `_readyNotifier`, `TestHarness` |

## Фазы

### Фаза 1. Enum и экран выбора

- `AppThemeMode`: `fixed`, `dynamic` (Classic), `perceptual`, `mesh`, `blur`.
  Геттеры-расширения: `usesArtwork`, `paletteAlgorithm` (classic / perceptual),
  `playerBackground` (gradient / mesh / blur).
- `toggle()` удалён вместе с тестом (использовался только в тесте).
- `appearance_page.dart`: сегментированная строка из двух кнопок заменяется
  вертикальным списком из пяти строк (иконка, название, однострочное описание,
  отметка выбранной). Подписи на английском, как остальной UI страницы.
- Тесты: сохранение и чтение всех пяти значений; неизвестное значение → fixed;
  старое `dynamic` читается как Classic. Виджет-тест выбора темы использует
  нотифаер без записи в БД: запись sqflite из fake-async зоны `testWidgets`
  не завершается и держит блокировку БД (тест висел до таймаута).

На этом этапе perceptual/mesh/blur временно ведут себя как Classic.

### Фаза 2. Perceptual-палитра

- Добавить `material_color_utilities` в прямые зависимости `pubspec.yaml`
  (уже есть транзитивно, версию брать из `pubspec.lock`).
- `lib/core/providers/perceptual_colors.dart`:
  - загрузка пикселей: `ImageProvider` → `ResizeImage` ~112 px →
    `ui.Image.toByteData(rawRgba)` → список ARGB;
  - `QuantizerCelebi().quantize(pixels, 128)` → `Score.score(...)` → seed и до
    4 цветов для mesh;
  - роли через `Hct.from(hue, min(chroma, cap), tone)`: gradientTop t18/c16,
    gradientBottom t6/c8, elevated t22/c14, accent t75/c 24..48 +
    `DislikeAnalyzer.fixIfDisliked`, onAccent t10/c10;
  - чистая функция `buildPerceptualPalette(int seedArgb, List<int> meshSeeds)`
    отдельно от загрузки, чтобы тестировать без картинок.
- `AppColors`: новые поля `onAccent` (Fixed/Classic = `textPrimary`, то есть
  поведение не меняется) и `meshColors` (4 цвета, для Fixed/Classic выводятся
  из gradientTop/elevated/accent).
- Кнопка Play (`player_controls.dart:221`, индикатор загрузки `:214`) и прочие
  места, где поверх `accent`/`elevatedHi` рисуется иконка, переходят на
  `onAccent`. Список мест уточнить grep'ом по `elevatedHi`.
- `_appColorsForUrlProvider`: ключ family `(url, algorithm)` (record), ветвление
  на Classic/Perceptual. `CurrentPaletteNotifier._recompute` учитывает
  алгоритм, а не только URL.
- Тесты `test/core/providers/perceptual_colors_test.dart`: seed по кругу оттенков
  + серый + пастель; проверить контраст onAccent/accent ≥ 3:1,
  textPrimary/gradientTop ≥ 4.5:1, tone фона в коридоре, у жёлто-зелёного
  акцента tone поднят.

**Как сделано (отличия от плана выше):** `onAccent` не понадобился.
`elevatedHi` в ~20 виджетах — заливка под белым текстом и иконками (подсветка
играющего трека, кнопки диалогов с `Colors.white`, кнопка Play), поэтому у
Perceptual он на tone 46 (светлота `0x747474` из Fixed, белый ≥ 4.5:1), а
`accent` t75 остаётся для цветных элементов поверх тёмного фона. Тёмный
жёлто-зелёный на tone 46 и в mesh приглушается до chroma 16 вместо подъёма
tone. Ч/б обложка даёт серую палитру: если `Score` не нашёл цветного
кандидата, seed — преобладающий серый, а не синий по умолчанию. Classic и
Fixed не изменились (у Fixed контраст кнопки Play тот же, что раньше).

### Фаза 3. Переход в OKLab

- `lib/core/providers/color_space.dart`: sRGB ↔ OKLab (~30 строк) и
  `lerpOklab(a, b, t)`.
- `AppColors.lerp` переходит на `lerpOklab`. Конечные цвета не меняются, меняется
  только середина перехода, поэтому применяется ко всем темам.
- Тест: lerp на t=0/1 возвращает концы; середина синий↔оранжевый не серее
  концов (chroma в OKLab выше порога).

**Как сделано (отличия от плана выше):** прямая в декартовом OKLab не
помогла: синий и оранжевый почти комплементарны, и середина у них такая же
серая, как в sRGB (chroma 0.064 против 0.053). Поэтому `lerpOklch`: L и
chroma линейно, оттенок по короткой дуге. Доля поворота оттенка взвешена
насыщенностью концов, `t·cy / ((1−t)·cx + t·cy)`. Серый конец (Fixed,
тонированные нейтрали) сразу берёт оттенок цветного, а у равно насыщенных
концов это обычный OKLCh. Сначала пробовал жёсткий порог «серого», но он давал
рывок оттенка на первом кадре перехода. Цвета вне гаммы sRGB обрезаются по
каналам: у очень ярких пар (зелёный↔пурпурный) середина теряет часть chroma.
Gamut mapping отложен, у реальных палитр насыщенность ниже.

### Фаза 4. Фон плеера: каркас и Blur

- `lib/ui/pages/player/player_background.dart`: `PlayerBackground` выбирает
  gradient / mesh / blur по `appThemeModeProvider`; `player_page.dart:58`
  использует его вместо `BoxDecoration`.
- Флаг активности: `NowPlayingOverlay` передаёт в `PlayerContent` признак
  «развёрнут» (`t > 0`), фон оборачивается в `TickerMode(enabled: active)`.
- Blur: обложка через `ResizeImage(width: 48)`, `fit: cover`,
  `FilterQuality.medium`, поверх лёгкий `ImageFiltered` в `RepaintBoundary`
  и затемнение `Colors.black` ~40 %. Смена трека через `AnimatedSwitcher`
  1000 мс (как у палитры). Источник картинки — тот же `artUri`, разбор
  file/network как в `_appColorsForUrlProvider` (вынести в общий хелпер).
- Widget-тест: для каждого режима строится нужный фон; при отсутствии обложки
  Blur падает на градиент.

**Как сделано (отличия от плана выше):** `PlayerBackground` — виджет без
провайдеров (`style`, `colors`, `artwork`, `animate`, `child`), провайдеры
читает `PlayerContent`. Форма дерева постоянна (градиент → слой фона →
контент), иначе смена стиля или трек без обложки пересоздавали бы весь
контент плеера вместе с очередью. `TickerMode` оборачивает только слой фона,
анимации контента не глушатся. В свёрнутом плеере смена обложки мгновенная
(`Duration.zero`), иначе замороженные переходы копили бы полноэкранные слои.
Затемнение и блюр рисуются только после загрузки кадра (`frameBuilder`,
fade-in 300 мс); битая или ещё не загруженная обложка оставляет чистый
градиент. Затемнение 60 % вместо 40 %: при 40 % белый текст на белой обложке
не дотягивает до 4.5:1. SafeArea переехала из `NowPlayingOverlay` внутрь
`PlayerContent`, фон теперь заходит под статус-бар. Раньше там была полоса
`colors.background`, у Classic она отличалась от `gradientTop`.
Хелпер разбора `artUri` вынесен в `lib/core/artwork_image_provider.dart`.
Для фазы 6: `RepaintBoundary` кэширует запись, но не результат
`ImageFiltered`, так что полноэкранный блюр, вероятно, пересчитывается на
каждом кадре сцены (ползунок, переход палитры). Если на замере это стоит
кадров, убрать `ImageFiltered` (48 px с `FilterQuality.medium` и так мягкие)
или декодировать в 24 px.

### Фаза 5. Mesh

- `shaders/mesh_gradient.frag` (GLSL): 4 цвета + время как uniform, плавающие
  радиальные пятна, итоговое затемнение. Регистрация в `pubspec.yaml`
  (`flutter: shaders:`).
- `MeshBackground`: `FragmentProgram.fromAsset` один раз (кэш в статике),
  `Ticker` → `CustomPainter` с `FragmentShader`. Цвета из
  `animatedPaletteProvider.meshColors`, так что смена трека плавная.
- Ошибка загрузки шейдера → градиент (try/catch, без падения).
- Проверить на Windows (`tools\run_windows.ps1`): FragmentProgram должен
  работать, иначе fallback.
- Widget-тест: при выключенном `TickerMode` тикер не тикает; fallback при
  ошибке загрузки (через подменяемый загрузчик).

**Как сделано (отличия от плана выше):** вместо времени в шейдер идут центры
пятен: `meshBlobCenters(phase)` считает их на CPU в double (8 sin/cos на
кадр вместо 8 на пиксель), частоты кратны циклу 120 с, поэтому фаза
заворачивается без скачка. Фаза копится по приращениям тикера с шагом не
больше 100 мс (`advanceMeshPhase`): у заглушённого `TickerMode` тикера
elapsed идёт дальше, и без ограничения пятна прыгали бы при разворачивании
плеера. В шейдере `precision highp`: в mediump (fp16 на Adreno/Mali) хэш
дизеринга переполняется ниже ~837 px и даёт NaN. Тикер создаётся только
после загрузки программы. Ленивый `late` тикер создавался бы в `dispose()`
при неудачной загрузке и падал. Неудачная загрузка кэшируется, пока шейдера
нет, видна градиент-подложка `PlayerBackground`.
Проверка на Windows не нужна: на десктопе страница плеера не показывается
(`NowPlayingOverlay` там пустой, `PlayerPage` нигде не используется).
Шейдер компилируется и рендерится в `flutter test` на Windows-хосте.
Для фазы 6: полноэкранный шейдер на 60 fps. Если на замере это заметно по
батарее или кадрам, ограничить обновление фазы ~30 fps: движение медленное
(цикл 17–40 с на пятно), разницы не видно.

### Фаза 6. Устройство и подстройка

- На Android на реальных обложках подобрать tone/chroma ролей Perceptual.
- Замерить кадры (`flutter run --profile`, DevTools) для Mesh и Blur в
  развёрнутом плеере и убедиться, что в свёрнутом нет перерисовок.
- `flutter analyze`, `flutter test`.
- CHANGELOG (раздел Unreleased): новые темы, исправление контраста кнопки Play.

**Как сделано.** Замеры на OnePlus PLC110 (120 Гц, бюджет кадра 8.3 мс),
release-сборка `toolsuild_release.ps1`, установка `adb install -r` поверх
release без потери данных. Вместо DevTools — временный
`addTimingsCallback` в logcat, после замеров удалён.

| Сценарий | fps | build p90 | raster p90 |
|---|---|---|---|
| Mesh, развёрнут, пауза | 121 | 0.6 мс | 2.2 мс |
| Mesh / Blur, свёрнут | 0 кадров | — | — |
| Blur, развёрнут, пауза | 0 кадров (статичен) | — | — |
| Blur, воспроизведение (ползунок ~8 fps) | 8 | 2.7 мс | 3.7 мс |
| Смена трека, Fixed | 121 | 1.1 мс | 2.5 мс |
| Смена трека, Classic / Perceptual / Mesh / Blur | 98–112 | 6–9 мс | 2.3–3.0 мс |

- GPU не узкое место: размытие и шейдер укладываются в 2–4 мс raster.
  Ограничивать Mesh до 30 fps и убирать `ImageFiltered` у Blur не нужно.
- Квантизация Celebi + Score шла на UI-потоке 51–75 мс на каждую смену
  трека, vsyncOverhead до 101 мс (фриз). Перенесена в `Isolate.run`, после
  этого vsyncOverhead не больше 15 мс.
- Build 6–9 мс на кадрах перехода палитры есть и у старой Classic:
  `PlayerContent` целиком перестраивается на каждом тике
  `animatedPaletteProvider`. Это вне рамок плана, вынесено в отдельную задачу.
- Подстройка по скриншотам четырёх реальных обложек. Нижняя граница chroma
  акцента 24 → 36: бледные обложки давали серую кнопку Play. «Нелюбимый»
  тёмный жёлто-зелёный теперь сдвигается по оттенку к ближайшей границе
  диапазона DislikeAnalyzer, а не приглушается до chroma 16 (было
  серо-оливково). Tone пятен mesh снижен на 8 (22/14/28/18): кнопки
  `elevated` (tone 22) сливались с фоном.
- Исправление контраста кнопки Play в CHANGELOG не попало: Fixed и Classic
  не менялись, гарантированный контраст есть только у новых тем.

## Риски

| Риск | Митигация |
|---|---|
| Квантизация Celebi на UI-потоке даёт подлагивание при смене трека | 112 px ≈ 12k пикселей, ожидаю единицы мс; замерить, при необходимости `compute()` |
| `palette_generator` discontinued | остаётся только для Classic; удалить можно позже, если Classic станет не нужен |
| Шейдер на старых Android GPU / Windows | fallback на градиент, проверка на устройстве в фазе 6 |
| `PlayerContent` всегда смонтирован → батарея | `TickerMode` по флагу развёрнутости, проверка в фазе 6 |
| Новые значения enum при откате на старую версию | старая версия прочитает неизвестное значение как fixed (`orElse`), не падает |

## Вне рамок

- Mesh/Blur на мини-плеере, списках и desktop-рамке.
- Удаление Classic и `palette_generator`.
- Ползунки tone/chroma в настройках.
