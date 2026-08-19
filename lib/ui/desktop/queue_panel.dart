// lib/ui/desktop/queue_panel.dart
//
// Правая колонка «плавающего» desktop-интерфейса: вкладки «Queue | Track»
// + список под ними.
//
// - «Queue»: реальная очередь воспроизведения (PlayerServiceInterface.trackQueue),
//   активный трек подсвечен, клик по элементу переключает трек
//   (skipToQueueItem). Перетаскивание ReorderableListView менят порядок.
// - «Track»: треки текущего плейлиста/контекста — показываем ту же очередь
//   (источник данных у desktop-проигрывателя один — trackQueue).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../widgets/artwork.dart';
import 'design/dimens.dart';
import 'design/floating_panel.dart';

/// Две вкладки правой панели.
enum _QueueTab {
  queue('Queue', Icons.queue_music_rounded),
  track('Track', Icons.library_music_rounded);

  const _QueueTab(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Правая панель «Queue / Track».
class QueuePanel extends StatefulWidget {
  const QueuePanel({super.key, this.width = 300});

  /// Фиксированная ширина правой колонки.
  final double width;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  _QueueTab _activeTab = _QueueTab.queue;

  @override
  Widget build(BuildContext context) {
    return FloatingPanel(
      width: widget.width,
      padding: const EdgeInsets.all(Dimens.pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Верх: пилюльные табы «Queue | Track».
          _QueueTabs(
            selected: _activeTab,
            onSelect: (tab) => setState(() => _activeTab = tab),
          ),
          const SizedBox(height: Dimens.gap),
          // Тело: скроллящийся список.
          Expanded(
            child: _QueueBody(tab: _activeTab),
          ),
        ],
      ),
    );
  }
}

/// Пилюльные табы «Queue | Track»: контейнер-«пилюля» с горизонтальным
/// рядом кнопок; активная вкладка подсвечена [AppColors.fixed.elevatedVariant].
class _QueueTabs extends StatelessWidget {
  const _QueueTabs({required this.selected, required this.onSelect});

  final _QueueTab selected;
  final ValueChanged<_QueueTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.fixed.elevated.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(Dimens.radiusPill),
      ),
      child: Row(
        children: [
          for (final tab in _QueueTab.values)
            Expanded(
              child: _QueueTabButton(
                tab: tab,
                active: tab == selected,
                onTap: () => onSelect(tab),
              ),
            ),
        ],
      ),
    );
  }
}

/// Отдельная кнопка-вкладка.
class _QueueTabButton extends StatelessWidget {
  const _QueueTabButton({
    required this.tab,
    required this.active,
    required this.onTap,
  });

  final _QueueTab tab;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = active
        ? AppColors.fixed.textPrimary
        : AppColors.fixed.textTertiary;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(Dimens.radiusPill),
      child: InkWell(
        borderRadius: BorderRadius.circular(Dimens.radiusPill),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(
            vertical: Dimens.gapSmall,
            horizontal: 6,
          ),
          decoration: BoxDecoration(
            color: active ? AppColors.fixed.elevatedVariant : Colors.transparent,
            borderRadius: BorderRadius.circular(Dimens.radiusPill),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(tab.icon, color: fg, size: 18),
              const SizedBox(width: 8),
              Text(
                tab.label,
                style: TextStyle(
                  color: fg,
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Тело панели: тонкий скроллбар (скрыт до hover) вокруг списка.
class _QueueBody extends ConsumerStatefulWidget {
  const _QueueBody({required this.tab});

  final _QueueTab tab;

  @override
  ConsumerState<_QueueBody> createState() => _QueueBodyState();
}

class _QueueBodyState extends ConsumerState<_QueueBody> {
  late final ScrollController _controller = ScrollController();
  bool _hovered = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerServiceProvider);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Scrollbar(
        controller: _controller,
        // Тонкий скроллбар, видимый только при наведении.
        thumbVisibility: _hovered,
        thickness: 4,
        radius: const Radius.circular(2),
        child: StreamBuilder<int>(
          stream: player.currentIndexStream,
          initialData: player.currentIndex,
          builder: (context, iSnap) {
            final current = iSnap.data ?? -1;
            final tracks = player.trackQueue;

            if (tracks.isEmpty) {
              return widget.tab == _QueueTab.queue
                  ? const _QueueEmptyPlaceholder()
                  : const _TrackEmptyPlaceholder();
            }

            return ListView.builder(
              controller: _controller,
              padding: const EdgeInsets.symmetric(vertical: Dimens.gap),
              itemCount: tracks.length,
              itemBuilder: (context, index) {
                final t = tracks[index];
                final isCurrent = index == current;
                return QueueTile(
                  trackId: t.id,
                  artworkUrl: t.artworkUrl,
                  title: t.title,
                  artist: t.artist,
                  duration: t.duration,
                  isCurrent: isCurrent,
                  onTap: () => player.skipToQueueItem(index),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// Заглушка, когда очередь пуста.
class _QueueEmptyPlaceholder extends StatelessWidget {
  const _QueueEmptyPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const _EmptyPlaceholder(
      icon: Icons.queue_music_rounded,
      title: 'Queue empty',
      subtitle: 'Add tracks to start a session',
    );
  }
}

/// Заглушка, когда трек ещё не выбран.
class _TrackEmptyPlaceholder extends StatelessWidget {
  const _TrackEmptyPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const _EmptyPlaceholder(
      icon: Icons.music_note_rounded,
      title: 'No track',
      subtitle: 'Nothing playing right now',
    );
  }
}

/// Общий placeholder для пустого состояния списка.
class _EmptyPlaceholder extends StatelessWidget {
  const _EmptyPlaceholder({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Dimens.padLarge),
      child: Column(
        children: [
          Icon(
            icon,
            color: AppColors.fixed.textTertiary,
            size: 36,
          ),
          const SizedBox(height: Dimens.gapSmall),
          Text(
            title,
            style: TextStyle(
              color: AppColors.fixed.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.fixed.textTertiary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Элемент очереди: обложка, название, исполнитель, длительность.
/// Активный трек подсвечен по [isCurrent].
class QueueTile extends StatelessWidget {
  const QueueTile({
    super.key,
    this.trackId,
    required this.artworkUrl,
    required this.title,
    required this.artist,
    required this.duration,
    this.isCurrent = false,
    this.onTap,
  });

  /// ID трека в источнике — нужен для рендера кастомной обложки
  /// ([Artwork] ищет по нему перезаписанные artwork в базе).
  final String? trackId;

  final String? artworkUrl;
  final String title;
  final String artist;
  final Duration? duration;
  final bool isCurrent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.fixed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: isCurrent
            ? colors.elevatedVariant.withValues(alpha: 0.35)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(Dimens.radiusCard),
        child: InkWell(
          borderRadius: BorderRadius.circular(Dimens.radiusCard),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Dimens.gapSmall,
              vertical: 6,
            ),
            child: Row(
              children: [
                Artwork(
                  url: artworkUrl,
                  size: 44,
                  borderRadius: Dimens.radiusCard,
                  trackId: trackId,
                ),
                const SizedBox(width: Dimens.gap),
                // Индикатор «играет».
                if (isCurrent) ...[
                  Icon(Icons.graphic_eq_rounded,
                      size: 14, color: colors.accent),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent
                              ? colors.textPrimary
                              : colors.textSecondary,
                          fontSize: 13,
                          fontWeight:
                              isCurrent ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.fixed.textTertiary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Dimens.gapSmall),
                Text(
                  _fmtDuration(duration),
                  style: TextStyle(
                    color: AppColors.fixed.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _fmtDuration(Duration? d) {
  if (d == null) return '--:--';
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}