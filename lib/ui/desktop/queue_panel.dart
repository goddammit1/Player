// lib/ui/desktop/queue_panel.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../widgets/artwork.dart';
import 'design/dimens.dart';
import 'design/floating_panel.dart';

enum _QueueTab { queue, track }

class QueuePanel extends ConsumerStatefulWidget {
  const QueuePanel({
    super.key,
    this.width = 340.0,
  });

  final double width;

  @override
  ConsumerState<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends ConsumerState<QueuePanel> {
  _QueueTab _activeTab = _QueueTab.queue;

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);

    return SizedBox(
      width: widget.width,
      child: Column(
        children: [
          // 1. Верхний переключатель табов высотой 64px со скользящей M3-пилюлей
          _M3SegmentedTabs(
            selectedTab: _activeTab,
            colors: colors,
            onTabChanged: (tab) => setState(() => _activeTab = tab),
          ),

          // Зазор между капсулой фильтров и списком
          const SizedBox(height: Dimens.gap),

          // 2. Основное окно очереди
          Expanded(
            child: FloatingPanel(
              color: colors.elevated,
              child: _QueueList(colors: colors),
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

  final _QueueTab selectedTab;
  final AppColors colors;
  final ValueChanged<_QueueTab> onTabChanged;

  @override
  Widget build(BuildContext context) {
    final isQueue = selectedTab == _QueueTab.queue;

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
                  onTap: () => onTabChanged(_QueueTab.queue),
                ),
              ),
              Expanded(
                child: _TabSegmentItem(
                  label: 'Track',
                  isSelected: !isQueue,
                  colors: colors,
                  onTap: () => onTabChanged(_QueueTab.track),
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

/// Список треков очереди
class _QueueList extends ConsumerWidget {
  const _QueueList({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerServiceProvider);

    return StreamBuilder<int>(
      stream: player.currentIndexStream,
      initialData: player.currentIndex,
      builder: (context, snap) {
        final current = snap.data ?? -1;
        final tracks = player.trackQueue;

        if (tracks.isEmpty) {
          return Center(
            child: Text(
              'Queue is empty',
              style: TextStyle(color: colors.textTertiary, fontSize: 13),
            ),
          );
        }

        return ListView.builder(
          itemCount: tracks.length,
          itemBuilder: (context, index) {
            final t = tracks[index];
            final isCurrent = index == current;
            return _QueueTileItem(
              artworkUrl: t.artworkUrl,
              title: t.title,
              artist: t.artist ?? '',
              duration: t.duration,
              isCurrent: isCurrent,
              colors: colors,
              onTap: () => player.skipToQueueItem(index),
            );
          },
        );
      },
    );
  }
}

/// Элемент списка трека
class _QueueTileItem extends StatelessWidget {
  const _QueueTileItem({
    required this.artworkUrl,
    required this.title,
    required this.artist,
    required this.duration,
    required this.isCurrent,
    required this.colors,
    required this.onTap,
  });

  final String? artworkUrl;
  final String title;
  final String artist;
  final Duration? duration;
  final bool isCurrent;
  final AppColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final durationStr = _fmt(duration);

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          Artwork(
            url: artworkUrl,
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
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  artist,
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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0),
      child: isCurrent
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
              onTap: onTap,
              child: content,
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