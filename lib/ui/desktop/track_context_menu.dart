// lib/ui/desktop/track_context_menu.dart
//
// Контекстное меню трека по правому клику (десктоп). Стиль — как у меню
// карточки плейлиста (desktop_home_page.dart). Простые действия выполняются
// сразу, сложные открывают существующие шторки через showDesktopModalSheet.
// На мобильных не используется: там остаётся long-press → шторка настроек.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/track_actions.dart';
import '../../models/track.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/snack.dart';
import '../widgets/soulseek_folder_sheet.dart';
import '../widgets/track_details_sheet.dart';

/// Дополнительный пункт меню, зависящий от места вызова
/// (Remove from playlist / history / queue, Play now…).
class TrackMenuAction {
  const TrackMenuAction({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
  final bool destructive;
}

/// Сколько ждать кэш-статус перед показом меню. Обычно это stat файла
/// (единицы мс); если дольше — пункт Download не показываем, чем открывать
/// меню с запаздыванием.
const _cacheStatusTimeout = Duration(milliseconds: 400);

/// Показывает меню трека в точке [position] (глобальные координаты).
///
/// [leading] — пункты над стандартными, [trailing] — под ними (обычно
/// удаление из текущего списка). [isCurrent] — меню играющего трека:
/// вместо Play next / Add to queue показывается Sleep timer.
/// [onCacheChanged] вызывается после загрузки / удаления офлайн-копии.
/// [showQueueActions] = false — меню элемента самой очереди: Play next /
/// Add to queue задублировали бы трек, их заменяют свои [leading].
/// [showCacheAction] = false — экран сам управляет кэшем (Cached tracks):
/// пункт Download / Remove download не показывается.
///
/// [context] может быть выше Navigator'а (DesktopPlayerBar) — тогда меню
/// и шторки открываются через [rootNavigatorKey].
Future<void> showTrackContextMenu(
  BuildContext context, {
  required Track track,
  required Offset position,
  List<TrackMenuAction> leading = const [],
  List<TrackMenuAction> trailing = const [],
  bool isCurrent = false,
  bool showQueueActions = true,
  bool showCacheAction = true,
  VoidCallback? onCacheChanged,
}) async {
  final nav =
      Navigator.maybeOf(context, rootNavigator: true) ??
      rootNavigatorKey.currentState;
  if (nav == null) return;
  final navCtx = nav.context;
  final container = ProviderScope.containerOf(navCtx, listen: false);
  final colors = container.read(animatedPaletteProvider);
  final player = container.read(playerServiceProvider);
  final overlayBox = nav.overlay?.context.findRenderObject() as RenderBox?;
  if (overlayBox == null) return;
  final local = overlayBox.globalToLocal(position);
  final overlaySize = overlayBox.size;

  TrackCacheStatus? status;
  if (showCacheAction) {
    try {
      status = await TrackActions.cacheStatus(
        track,
      ).timeout(_cacheStatusTimeout);
    } on TimeoutException {
      status = null;
    }
  }
  if (!navCtx.mounted) return;

  PopupMenuEntry<VoidCallback> item(
    IconData icon,
    String label,
    VoidCallback? onSelected, {
    bool destructive = false,
    Key? key,
  }) {
    final color = destructive
        ? Colors.redAccent
        : onSelected == null
        ? colors.textTertiary
        : colors.textPrimary;
    return PopupMenuItem<VoidCallback>(
      key: key,
      value: onSelected,
      enabled: onSelected != null,
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> download() async {
    final isSoulseek = TrackActions.soulseekDownloadId(track) != null;
    showSnack(navCtx, 'Downloading "${track.title}"…');
    try {
      await TrackActions.download(track);
      if (!navCtx.mounted) return;
      showSuccessSnack(
        navCtx,
        isSoulseek ? 'Download started' : 'Saved for offline',
      );
      onCacheChanged?.call();
    } catch (e) {
      if (navCtx.mounted) showErrorSnack(navCtx, 'Download failed: $e');
    }
  }

  Future<void> deleteCache() async {
    try {
      await TrackActions.deleteCache(track);
      if (!navCtx.mounted) return;
      showSnack(navCtx, 'Removed from downloads');
      onCacheChanged?.call();
    } catch (e) {
      if (navCtx.mounted) showErrorSnack(navCtx, 'Failed to delete: $e');
    }
  }

  final entries = <PopupMenuEntry<VoidCallback>>[
    for (final a in leading)
      item(a.icon, a.label, a.onSelected, destructive: a.destructive),
    if (!isCurrent && showQueueActions) ...[
      item(
        Icons.queue_play_next_rounded,
        'Play next',
        () {
          TrackActions.playNext(player, track);
          showSnack(navCtx, '"${track.title}" will play next');
        },
        key: const Key('track_menu_play_next'),
      ),
      item(
        Icons.add_to_queue_rounded,
        'Add to queue',
        () {
          player.addToQueue(track);
          showSnack(navCtx, '"${track.title}" added to queue');
        },
        key: const Key('track_menu_add_to_queue'),
      ),
    ],
    item(
      Icons.playlist_add_rounded,
      'Add to playlist…',
      () => showAddToPlaylistSheet(navCtx, track),
      key: const Key('track_menu_add_to_playlist'),
    ),
    const PopupMenuDivider(height: 8),
    if (status != null)
      switch (status.state) {
        TrackCacheState.cached => item(
          Icons.download_done_rounded,
          'Remove download',
          deleteCache,
          key: const Key('track_menu_remove_download'),
        ),
        TrackCacheState.downloading => item(
          Icons.downloading_rounded,
          status.progress != null
              ? 'Downloading… ${(status.progress! * 100).round()}%'
              : 'Downloading…',
          null,
          key: const Key('track_menu_downloading'),
        ),
        TrackCacheState.notCached => item(
          Icons.download_rounded,
          'Download',
          download,
          key: const Key('track_menu_download'),
        ),
      }
    else if (showCacheAction)
      // Статус не успел прочитаться (медленный мост Soulseek) — пункт виден,
      // но неактивен, чтобы меню не «прыгало» между открытиями.
      item(
        Icons.download_rounded,
        'Download status unavailable',
        null,
        key: const Key('track_menu_download_unknown'),
      ),
    if (TrackActions.soulseekFolderAvailable(track))
      item(
        Icons.folder_open_rounded,
        'Open folder',
        () => showSoulseekFolderSheet(navCtx, [track]),
        key: const Key('track_menu_open_folder'),
      ),
    if (isCurrent)
      item(
        Icons.bedtime_outlined,
        'Sleep timer…',
        () => showSleepTimerSheet(navCtx),
        key: const Key('track_menu_sleep_timer'),
      ),
    item(
      Icons.info_outline_rounded,
      'Details',
      () => showTrackDetailsSheet(navCtx, track),
      key: const Key('track_menu_details'),
    ),
    if (trailing.isNotEmpty) ...[
      const PopupMenuDivider(height: 8),
      for (final a in trailing)
        item(a.icon, a.label, a.onSelected, destructive: a.destructive),
    ],
  ];

  final selected = await showMenu<VoidCallback>(
    context: navCtx,
    color: colors.background,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    position: RelativeRect.fromRect(
      local & const Size(1, 1),
      Offset.zero & overlaySize,
    ),
    items: entries,
  );
  if (selected == null || !navCtx.mounted) return;
  selected();
}
