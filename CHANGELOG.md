# Changelog

Все заметные изменения в этом проекте будут документироваться в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
проект придерживается [Semantic Versioning](https://semver.org/lang/ru/).

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
