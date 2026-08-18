# Changelog

Все заметные изменения в этом проекте будут документироваться в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
проект придерживается [Semantic Versioning](https://semver.org/lang/ru/).

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
