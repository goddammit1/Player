// lib/ui/desktop/queue_panel.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/player_service_interface.dart';
import '../../core/providers.dart';
import '../../models/track.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/artwork.dart';
import 'design/dimens.dart';
import 'design/floating_panel.dart';
import 'desktop_ui_state.dart';
import 'now_playing_panel.dart';
import 'track_context_menu.dart';

class QueuePanel extends ConsumerStatefulWidget {
  const QueuePanel({super.key, this.width = 340.0});

  final double width;

  @override
  ConsumerState<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends ConsumerState<QueuePanel> {
  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);
    final tab = ref.watch(desktopSidePanelProvider.select((s) => s.tab));

    return SizedBox(
      width: widget.width,
      child: Column(
        children: [
          // 1. Верхний переключатель табов высотой 64px со скользящей M3-пилюлей
          _M3SegmentedTabs(
            selectedTab: tab,
            colors: colors,
            onTabChanged: (t) =>
                ref.read(desktopSidePanelProvider.notifier).selectTab(t),
          ),

          // Зазор между капсулой фильтров и списком
          const SizedBox(height: Dimens.gap),

          // 2. Основное окно очереди
          Expanded(
            child: FloatingPanel(
              color: colors.elevated,
              child: tab == DesktopSideTab.queue
                  ? _QueueList(colors: colors)
                  : const NowPlayingPanel(),
            ),
          ),
        ],
      ),
    );
  }
}

class _M3SegmentedTabs extends StatelessWidget {
  const _M3SegmentedTabs({
    required this.selectedTab,
    required this.colors,
    required this.onTabChanged,
  });

  final DesktopSideTab selectedTab;
  final AppColors colors;
  final ValueChanged<DesktopSideTab> onTabChanged;

  @override
  Widget build(BuildContext context) {
    final isQueue = selectedTab == DesktopSideTab.queue;

    return Container(
      height: 64.0, // Высота 64px
      decoration: BoxDecoration(
        color: colors.elevated,
        borderRadius: BorderRadius.circular(Dimens.radiusPill),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeInOutCubicEmphasized, // Фирменная кривая M3
            alignment: isQueue ? Alignment.centerLeft : Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              heightFactor: 1.0,
              child: Container(
                decoration: BoxDecoration(
                  color: colors.elevatedHi,
                  borderRadius: BorderRadius.circular(Dimens.radiusPill),
                ),
              ),
            ),
          ),

          // Кликабельные сегменты с текстом
          Row(
            children: [
              Expanded(
                child: _TabSegmentItem(
                  label: 'Queue',
                  isSelected: isQueue,
                  colors: colors,
                  onTap: () => onTabChanged(DesktopSideTab.queue),
                ),
              ),
              Expanded(
                child: _TabSegmentItem(
                  label: 'Track',
                  isSelected: !isQueue,
                  colors: colors,
                  onTap: () => onTabChanged(DesktopSideTab.track),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Интерактивный текст таба с hover-откликом и плавной сменой стиля
class _TabSegmentItem extends StatefulWidget {
  const _TabSegmentItem({
    required this.label,
    required this.isSelected,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final AppColors colors;
  final VoidCallback onTap;

  @override
  State<_TabSegmentItem> createState() => _TabSegmentItemState();
}

class _TabSegmentItemState extends State<_TabSegmentItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final textColor = widget.isSelected || _isHovered
        ? widget.colors.textPrimary
        : widget.colors.textSecondary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            style: TextStyle(
              color: textColor,
              fontSize: 20,
              fontWeight: FontWeight.w500,
              fontFamily: 'Geist',
            ),
            child: Text(widget.label),
          ),
        ),
      ),
    );
  }
}

/// Список треков очереди: reorder за drag-handle, удаление и меню по hover /
/// правому клику, «Clear» в шапке.
class _QueueList extends ConsumerStatefulWidget {
  const _QueueList({required this.colors});

  final AppColors colors;

  @override
  ConsumerState<_QueueList> createState() => _QueueListState();
}

class _QueueListState extends ConsumerState<_QueueList> {
  late PlayerServiceInterface _player;
  List<Track> _tracks = const [];
  int _current = -1;
  StreamSubscription<List<Track>>? _queueSub;
  StreamSubscription<int>? _indexSub;

  @override
  void initState() {
    super.initState();
    _subscribe(ref.read(playerServiceProvider));
  }

  void _subscribe(PlayerServiceInterface player) {
    _queueSub?.cancel();
    _indexSub?.cancel();
    _player = player;
    _tracks = player.trackQueue;
    _current = player.currentIndex;
    _queueSub = player.trackQueueStream.listen((q) {
      if (mounted) setState(() => _tracks = q);
    });
    _indexSub = player.currentIndexStream.listen((i) {
      if (mounted) setState(() => _current = i);
    });
  }

  @override
  void dispose() {
    _queueSub?.cancel();
    _indexSub?.cancel();
    super.dispose();
  }

  void _onReorder(int oldIndex, int newIndex) {
    // ReorderableListView отдаёт индекс ДО удаления элемента.
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    // Оптимистично: без этого перетащенная плитка на кадр прыгает назад,
    // пока не придёт событие очереди.
    setState(() {
      final list = [..._tracks];
      list.insert(newIndex, list.removeAt(oldIndex));
      _tracks = list;
      if (oldIndex == _current) {
        _current = newIndex;
      } else if (oldIndex < _current && newIndex >= _current) {
        _current -= 1;
      } else if (oldIndex > _current && newIndex <= _current) {
        _current += 1;
      }
    });
    _player.reorderQueueItem(oldIndex, newIndex);
  }

  /// Переставляет трек сразу за текущим (без дубликата в очереди).
  void _moveNext(int index) {
    if (_current < 0) return;
    final target = index > _current ? _current + 1 : _current;
    if (target == index) return;
    _player.reorderQueueItem(index, target);
  }

  Future<void> _confirmClear() async {
    final ok = await showAppConfirmDialog(
      context: context,
      title: 'Clear queue',
      subtitle:
          'Playback will stop and all tracks will be removed '
          'from the queue.',
      confirmLabel: 'Clear',
      isDestructive: true,
    );
    if (ok == true) await _player.clearQueue();
  }

  /// Индекс [track] в очереди на момент выбора пункта меню: пока меню было
  /// открыто, очередь могла сдвинуться (автопереход, удаление, reorder).
  /// null — трека больше нет или он стал текущим.
  int? _resolveIndex(Track track, int hint) {
    var index = -1;
    if (hint < _tracks.length && identical(_tracks[hint], track)) {
      index = hint;
    } else {
      index = _tracks.indexWhere((t) => identical(t, track));
      if (index < 0) {
        final matches = [
          for (var i = 0; i < _tracks.length; i++)
            if (_tracks[i].globalId == track.globalId) i,
        ];
        if (matches.length == 1) index = matches.single;
      }
    }
    if (index < 0 || index == _current) return null;
    return index;
  }

  void _showMenu(int index, Offset position) {
    final track = _tracks[index];
    final isCurrent = index == _current;
    void withIndex(void Function(int index) action) {
      if (!mounted) return;
      final i = _resolveIndex(track, index);
      if (i != null) action(i);
    }

    showTrackContextMenu(
      context,
      track: track,
      position: position,
      isCurrent: isCurrent,
      showQueueActions: false,
      leading: [
        if (!isCurrent) ...[
          TrackMenuAction(
            icon: Icons.play_arrow_rounded,
            label: 'Play now',
            onSelected: () => withIndex(_player.skipToQueueItem),
          ),
          if (_current >= 0 && index != _current + 1)
            TrackMenuAction(
              icon: Icons.queue_play_next_rounded,
              label: 'Play next',
              onSelected: () => withIndex(_moveNext),
            ),
        ],
      ],
      trailing: [
        if (!isCurrent)
          TrackMenuAction(
            icon: Icons.remove_circle_outline_rounded,
            label: 'Remove from queue',
            destructive: true,
            onSelected: () => withIndex(_player.removeFromQueue),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final player = ref.watch(playerServiceProvider);
    if (!identical(player, _player)) _subscribe(player);

    if (_tracks.isEmpty) {
      return Center(
        child: Text(
          'Queue is empty',
          style: TextStyle(color: colors.textTertiary, fontSize: 13),
        ),
      );
    }

    // Один и тот же трек может стоять в очереди несколько раз — ключ
    // дополняется номером вхождения.
    final seen = <String, int>{};
    final keys = <Key>[];
    for (final t in _tracks) {
      final n = seen[t.globalId] = (seen[t.globalId] ?? 0) + 1;
      keys.add(ValueKey('${t.globalId}#$n'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 10, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _tracks.length == 1 ? '1 track' : '${_tracks.length} tracks',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              TextButton(
                key: const Key('queue_clear'),
                onPressed: _confirmClear,
                style: TextButton.styleFrom(
                  foregroundColor: colors.textSecondary,
                  shape: const StadiumBorder(),
                ),
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: _tracks.length,
            onReorder: _onReorder,
            proxyDecorator: (child, index, animation) => Material(
              color: Colors.transparent,
              elevation: 6,
              shadowColor: Colors.black54,
              borderRadius: BorderRadius.circular(Dimens.radiusCard),
              child: child,
            ),
            itemBuilder: (context, index) {
              final t = _tracks[index];
              return _QueueTileItem(
                key: keys[index],
                index: index,
                artworkUrl: t.artworkUrl,
                title: t.title,
                artist: t.artist,
                duration: t.duration,
                isCurrent: index == _current,
                colors: colors,
                onTap: () => _player.skipToQueueItem(index),
                onRemove: () => _player.removeFromQueue(index),
                onContextMenu: (pos) => _showMenu(index, pos),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Элемент списка трека. По наведению — «×» (кроме текущего) и drag-handle.
class _QueueTileItem extends StatefulWidget {
  const _QueueTileItem({
    super.key,
    required this.index,
    required this.artworkUrl,
    required this.title,
    required this.artist,
    required this.duration,
    required this.isCurrent,
    required this.colors,
    required this.onTap,
    required this.onRemove,
    required this.onContextMenu,
  });

  final int index;
  final String? artworkUrl;
  final String title;
  final String artist;
  final Duration? duration;
  final bool isCurrent;
  final AppColors colors;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final ValueChanged<Offset> onContextMenu;

  @override
  State<_QueueTileItem> createState() => _QueueTileItemState();
}

class _QueueTileItemState extends State<_QueueTileItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final durationStr = _fmt(widget.duration);

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          Artwork(
            url: widget.artworkUrl,
            artist: widget.artist,
            title: widget.title,
            size: 64,
            borderRadius: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  widget.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  durationStr,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final tile = widget.isCurrent
        ? Container(
            decoration: BoxDecoration(
              color: colors.elevatedHi,
              borderRadius: BorderRadius.circular(Dimens.radiusCard),
            ),
            child: content,
          )
        : InkWell(
            borderRadius: BorderRadius.circular(Dimens.radiusCard),
            hoverColor: colors.elevatedVariant.withValues(alpha: 0.4),
            onTap: widget.onTap,
            child: content,
          );

    // Кнопки поверх правого края — без резерва места, чтобы название не
    // сужалось у всех строк.
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapDown: (d) => widget.onContextMenu(d.globalPosition),
        child: Stack(
          alignment: Alignment.centerRight,
          children: [
            tile,
            Positioned(
              right: 10,
              child: IgnorePointer(
                ignoring: !_hovered,
                child: AnimatedOpacity(
                  opacity: _hovered ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 120),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: widget.isCurrent
                          ? colors.elevatedHi
                          : colors.elevatedVariant,
                      borderRadius: BorderRadius.circular(Dimens.radiusPill),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!widget.isCurrent)
                          _TileIconButton(
                            key: ValueKey('queue_remove_${widget.index}'),
                            icon: Icons.close_rounded,
                            colors: colors,
                            onTap: widget.onRemove,
                          ),
                        ReorderableDragStartListener(
                          index: widget.index,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: SizedBox(
                              key: ValueKey('queue_drag_${widget.index}'),
                              width: 36,
                              height: 36,
                              child: Icon(
                                Icons.drag_indicator_rounded,
                                size: 20,
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(Duration? d) {
    if (d == null) return '0:00';
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _TileIconButton extends StatefulWidget {
  const _TileIconButton({
    super.key,
    required this.icon,
    required this.colors,
    required this.onTap,
  });

  final IconData icon;
  final AppColors colors;
  final VoidCallback onTap;

  @override
  State<_TileIconButton> createState() => _TileIconButtonState();
}

class _TileIconButtonState extends State<_TileIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(
            widget.icon,
            size: 20,
            color: _hovered
                ? widget.colors.textPrimary
                : widget.colors.textSecondary,
          ),
        ),
      ),
    );
  }
}
