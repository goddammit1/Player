# Plan: Soulseek transfers — retry and clear finished

**Complexity**: Medium
**Owner**: subagent
**Parent plan**: [soulseek_pages_redesign_plan.md](soulseek_pages_redesign_plan.md) (UI calls the API below)

## Goal

Add two transfer operations to the Soulseek channel on **both** platforms:

```dart
/// Restarts a failed or cancelled download with the same peer/file/cacheKey.
/// Returns false if the transfer is unknown or not in a terminal failed/cancelled state.
Future<bool> retryDownload(String downloadId);

/// Removes completed/failed/cancelled transfers from the transfer list
/// (in-memory and persisted). Never touches cached audio files.
/// Returns the number of removed transfers.
Future<int> clearFinishedTransfers();
```

This is the **contract** the UI (downloads sheet) codes against. Keep names and signatures exactly.

## Where things live

| Layer | File |
|---|---|
| Dart channel interface | `lib/sources/soulseek_source.dart` (`abstract class SoulseekChannel`, ~line 90–120) |
| Platform base + Android impl | `lib/sources/soulseek_platform_channel.dart` (`AndroidSoulseekChannel`, pattern: `cancelDownload` ~line 485) |
| Windows impl | `lib/sources/soulseek_desktop/soulseek_desktop_channel.dart` → `soulseek_transfer_manager.dart` (pure Dart manager, `_transfers` map, `_persist`, `soulseek_desktop_store.dart`) |
| Android plugin | `android/app/src/main/kotlin/com/player/player/SoulseekPlugin.kt` (method switch, `"cancelDownload"` ~line 603) |
| Android manager | `.../SoulseekTransferManager.kt` (`transfers` ConcurrentHashMap, `TransferContext`, `processTransfer`, `persistTransfer`, `cacheKeyToDownloadId`, `cleanupMappings`) |
| Android DB | `.../SoulseekDatabase.kt` (persisted transfers, `restoreFromDatabase`) |

## Tasks

### Task 1 — Investigate before coding
- Confirm both managers keep peerUsername / remoteFilename / sizeBytes / cacheKey / title / artist on
  terminal transfers (needed to restart without the original search result).
- Check how terminal transfers are persisted and restored (`restoreFromDatabase`, desktop `restore()`),
  and whether `getActiveTransfers(includeTerminal: true)` reads memory, DB or both.
- Check `SoulseekSource` (`_awaitDownload`, `_claims`, `_manualDownloads`) for assumptions that a
  terminal transfer stays in the list — clearing must not break awaiting code.

### Task 2 — Windows (Dart manager)
- `retryDownload`: only for `failed` / `cancelled`. Reset bytes/attempt counters/error, set `queued`,
  re-run the same processing path as `startDownload` (slots, `_process`), publish event, persist.
  A completed transfer is not retried (return false).
- `clearFinishedTransfers`: remove terminal transfers from `_transfers` and from the desktop store;
  emit nothing per-item, the UI refreshes after the call.
- Wire through `DesktopSoulseekChannel`.

### Task 3 — Android (Kotlin)
- `SoulseekTransferManager.retryDownload(downloadId): Boolean` and `clearFinished(): Int`, same
  semantics; reuse the existing launch path used by `startDownload`/`resumeDownload` (coroutine scope,
  slot semaphore, `cacheKeyToDownloadId` mapping restored).
- Persist / delete DB rows accordingly (`SoulseekDatabase`).
- `SoulseekPlugin`: methods `"retryDownload"` (`downloadId`) → Boolean, `"clearFinishedTransfers"` → Int.
- If an AIDL/service boundary sits between plugin and manager, extend it the same way existing
  `cancelDownload` goes through.

### Task 4 — Dart channel
- Add both methods to `SoulseekChannel` interface and `SoulseekPlatformChannel`, implement in
  `AndroidSoulseekChannel` (mirror `cancelDownload`: `_requireAndroid()`, `_invoke`, `?? false` / `?? 0`).
- Every class that `implements` / fakes the channel must compile: grep
  `implements SoulseekPlatformChannel|extends SoulseekPlatformChannel|implements SoulseekChannel`
  in `lib/` and `test/`. In `test/ui/*` fakes ONLY add the two overrides (returning `true` / `0`
  or recording calls) — the UI owner edits the rest of those files later.

### Task 5 — Tests
- `test/sources/soulseek_desktop/soulseek_transfer_manager_test.dart`: retry after failure re-runs and
  completes; retry on completed returns false; clear removes terminal only and keeps active ones;
  cleared transfers do not come back after `restore()`.
- Kotlin: add unit tests only if the module already has a Kotlin test setup; otherwise skip and say so.

## Constraints
- Do NOT edit `lib/ui/**` (owned by the UI plan).
- Do NOT commit (user commits themselves).
- Remove any temporary debug logging before finishing.
- Comments in the code are in Russian, matching surrounding files.

## Validation

```bash
flutter analyze lib/sources test/sources
flutter test test/sources/soulseek_desktop test/sources/soulseek_source_test.dart
```

Android: `cd android && ./gradlew :app:compileDebugKotlin` (or the closest available compile task).

## Report back
- Files changed, how retry restarts the transfer on each platform, any behavior caveats
  (e.g. retry of a cancelled transfer restarts from 0 because `.part` was deleted), validation output.
