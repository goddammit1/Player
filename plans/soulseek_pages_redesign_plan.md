# Plan: Soulseek settings + downloads sheet redesign

**Complexity**: Medium
**Concept**: approved interactive mockup v2 (chat, 2026-10-16)
**Companion plan**: [soulseek_transfers_retry_clear_plan.md](soulseek_transfers_retry_clear_plan.md) — native retry/clear (subagent)

## Summary

Rebuild `SoulseekSettingsPage` from 8 stacked sections into a compact status card + 3 groups + collapsible
"Advanced", and restyle the downloads sheet so it uses only `AppColors` (no hardcoded green/orange), real
track artwork, a right-aligned format chip and ring progress. Logic (connect retry loop, generations,
repository persistence) stays as is; this is a presentation rewrite plus a few agreed behavior changes.

UI strings stay in English (the app UI is English; the mockup was Russian only for review).

## Agreed decisions

| # | Decision |
|---|---|
| 1 | Remove "Save credentials" button — credentials are saved on Connect (already done in `_connect`). |
| 2 | Search timeout stays a free numeric input (compact inline field). Parallel downloads: segmented 2–5. |
| 3 | Retry (failed/cancelled) and "Clear finished" are added — native part by subagent. |
| 4 | Downloads use real artwork (`Artwork` lazy lookup by artist/title); format shown as a chip on the right. |

## Patterns to mirror

| Category | Source | Pattern |
|---|---|---|
| Grouped rows | `lib/ui/pages/cached_tracks_page.dart:39` | `_trackBorderRadius(isFirst,isLast)`: 15 outer / 5 inner, 2px gaps, `colors.elevated` |
| Section label | `lib/ui/pages/soulseek_settings_page.dart:1278` | `_Section` uppercase 12px w700 `textTertiary`, padding 20/16/20/8 |
| Switch colors | `lib/ui/pages/appearance_page.dart:439` | `Switch.adaptive` with accent thumb, accent@0.3 track |
| Segmented | `lib/ui/pages/appearance_page.dart:301` | elevated container + selected label `textPrimary` w600 |
| Artwork | `lib/ui/pages/cached_tracks_page.dart:694` | `SoulseekSource.artworkQuery` → `Artwork(url:null, artist, title)` |
| Ring progress | `lib/ui/desktop/soulseek_downloads_indicator.dart:110` | `CircularProgressIndicator` textPrimary on outline |
| Destructive | `lib/ui/pages/cache_page.dart:652` | `Colors.redAccent` text only |
| Errors | `lib/ui/widgets/snack.dart` | `showSnack` / `showErrorSnack` |
| Tests | `test/ui/soulseek_settings_connect_test.dart` | fake `SoulseekPlatformChannel`, `pump(Duration)` not `pumpAndSettle` (sqflite hang) |

## Files to change

| File | Action | Why |
|---|---|---|
| `lib/ui/pages/soulseek_settings_page.dart` | UPDATE | New layout, status card, groups, Advanced, cancel-connect |
| `lib/ui/widgets/soulseek_transfer_sheet.dart` | UPDATE | New tile, groups, header summary, Clear / Retry wiring |
| `test/ui/soulseek_settings_connect_test.dart` | UPDATE | Single Connect/Disconnect button labels |
| `test/ui/soulseek_settings_timeout_test.dart` | UPDATE | Field finder if it relied on old layout |
| `test/ui/soulseek_stage3_ui_test.dart` | UPDATE | Old section titles / buttons |

Files owned by the subagent (do NOT edit in this plan): `lib/sources/soulseek_platform_channel.dart`,
`lib/sources/soulseek_desktop/*`, `lib/sources/soulseek_source.dart` (interface), Kotlin
`android/app/src/main/kotlin/com/player/player/Soulseek*.kt`, `test/sources/**`.

## Tasks

### Task 1 — Settings: status card (top)
- One grouped block: row 1 = status dot (`_ConnectionStatusDot`, recolored: connected `textPrimary`,
  connecting pulsing `textSecondary`, failed `redAccent`, disconnected `textTertiary`) + title
  (`Connected` / `Connecting…` / `Reconnecting…` / `Connection failed` / `Disconnected`) + subtitle
  (`as <username>` when connected, else `_connectionMessage`, else `Offline`) + single pill button.
- Button: disconnected/failed → `Connect`; connecting/reconnecting → `Cancel`; connected → `Disconnect`.
- `Cancel`: new `_cancelConnect()` sets `_connectCancelled = true`, calls `disconnect()`; retry loop in
  `_connect` checks the flag between attempts and before applying the result; cancelled run ends in
  `disconnected` without the failure snack.
- Row 2: `Show in search` switch (`_toggleEnabled`).
- Below the block: P2P footnote (info icon + 12px `textTertiary`), replaces the orange box.
- `_connectionSectionKey` moves to the status card (search filter tap still scrolls there).

### Task 2 — Account group
- Hidden while `_connectionState == connected`.
- Two grouped rows: label column (`Username`/`Password`, 13px textTertiary, fixed width) + borderless
  `TextField` (no fill, no prefix icon); password row keeps the eye toggle.
- Drop `_saveCredentials` button (method removed if unused).

### Task 3 — Search group
- `Lossless only` switch row (existing `_togglePreferLossless`).
- Formats row: compact `_FormatChip`s (smaller padding, selected = `elevatedVariant` + `elevatedHi` border).
- `Max file size` row: trailing value (`Unlimited` / `N MB`) + chevron → option sheet with presets
  `Unlimited, 50, 100, 200, 500 MB` (desktop: `showDesktopModalSheet`, mobile: modal bottom sheet).
  Writes via `_updateMaxFileSize`.
- `Search timeout` row: compact inline `_NumericField` (≈56px wide, no icon, centered) + `s` suffix.
  Keeps debounce/blur/dispose commit semantics of `_NumericField`.

### Task 4 — Downloads group
- `Play while downloading` switch.
- `Parallel downloads` segmented 2/3/4/5 → `_updateMaxParallel`.
- `Downloads` nav row: trailing `N active` (from a light `getActiveTransfers()` on open + `transferEvents`
  listener; hidden when 0) → `showSoulseekTransferSheet`.
- `Cached tracks` nav row → `CachedTracksPage` (no count — avoids loading the whole cache on open).

### Task 5 — Advanced (collapsible, collapsed by default)
- Header row `Advanced` + rotating chevron; `AnimatedSize` body.
- Rows: `Listener port` (compact numeric field), `Shared folder` (path subtitle, info dialog),
  `Storage diagnostics` (report dialog), `Clear credentials` (red text, confirm dialog).
- Remove `_buildSharingSection`, `_buildTroubleshootingSection`, `_buildDangerZone`, `_ActionButton`
  if unused.

### Task 6 — Downloads sheet
- Header: `Downloads` 22px + subtitle `N active · <total speed>` (tabular figures) + text button
  `Clear` (visible when any terminal transfer exists) → `clearFinishedTransfers()` then `_refresh()`.
- Two labelled groups: `In progress` (active + paused + prebuffered) and `Finished` (completed, failed,
  cancelled); grouped tiles with `_trackBorderRadius`-style corners.
- Tile: `Artwork` 42px r9 (`soulseekArtworkQuery(remoteFilename, fallbackArtist, fallbackTitle)`,
  trackId = downloadId) · title + subtitle (`artist · 62% · 820 KB/s` / `artist · Queued at peer` /
  `artist · 41.2 MB` / red `Failed` + message) · format chip (extension of `remoteFilename`, uppercase) ·
  trailing control:
  - downloading → ring with pause icon (tap pause) + small cancel `x`
  - paused → ring with play icon (resume) + `x`
  - queued/connecting/searching → dashed ring with `x` (cancel)
  - completed → check icon (`textSecondary`)
  - failed/cancelled → retry icon → `retryDownload(id)`; cancelled tile at 55% opacity.
- Remove all `Colors.greenAccent/orangeAccent`; keep `Colors.redAccent` only for the `Failed` word.
- Empty state unchanged in copy, recolored.

### Task 7 — Tests
- Update existing UI tests for the new labels/structure; add: status button label per state, Advanced
  expands, transfer sheet groups + Clear button visibility (fake channel).
- Use `pump(const Duration(...))`, no `pumpAndSettle` (pulsing dot repeats forever).

## Validation

```bash
flutter analyze lib/ui/pages/soulseek_settings_page.dart lib/ui/widgets/soulseek_transfer_sheet.dart
flutter test test/ui/soulseek_settings_connect_test.dart test/ui/soulseek_settings_timeout_test.dart test/ui/soulseek_stage3_ui_test.dart test/ui/settings_subpages_test.dart
```

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Cancel during connect races with retry loop / push events | Medium | Flag checked between attempts; generation bump on cancel |
| Subagent and UI edit the same fake channels in tests | Medium | Subagent only adds overrides to fakes; UI test edits happen after it finishes |
| `Artwork` lazy lookup per tile on 1 s poll rebuilds | Low | Stable `trackId` key; Artwork caches by id |
| Format chip empty when `remoteFilename` missing | Low | Hide chip |

## Acceptance
- [ ] Settings page matches mockup v2 in Fixed and artwork palettes
- [ ] No hardcoded green/orange in either file
- [ ] Retry / Clear work on Android and Windows (with subagent's API)
- [ ] `flutter analyze` clean, touched tests green
