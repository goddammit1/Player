import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/history_repository.dart';
import '../../core/providers.dart';
import '../widgets/artwork.dart';
import '../widgets/track_settings_sheet.dart';

/// Страница истории прослушивания.
///
/// Список записей «новые сверху», сгруппированный по дням
/// (Today / Yesterday / дата). Тап — играть трек, свайп — удалить запись,
/// long press — меню трека. Кнопка в шапке очищает всю историю.
class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);
    final async = ref.watch(listenHistoryProvider);
    final history = async.value ?? const <HistoryEntry>[];

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.chevron_left_rounded,
            size: 28,
            color: colors.textPrimary,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'History',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
        actions: [
          if (history.isNotEmpty)
            IconButton(
              icon: Icon(Icons.delete_sweep_rounded, color: colors.textPrimary),
              onPressed: () => _confirmClear(context, ref, colors),
            ),
        ],
      ),
      body: history.isEmpty
          ? Center(
              child: Text(
                'No listening history yet',
                style: TextStyle(color: colors.textSecondary, fontSize: 15),
              ),
            )
          : _HistoryList(history: history, colors: colors),
    );
  }

  Future<void> _confirmClear(
    BuildContext context,
    WidgetRef ref,
    dynamic colors,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.elevated,
        title: Text(
          'Clear history',
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          'Remove all listening history? This cannot be undone.',
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(historyRepositoryProvider).clear();
    }
  }
}

class _HistoryList extends ConsumerWidget {
  const _HistoryList({required this.history, required this.colors});

  final List<HistoryEntry> history;
  final dynamic colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Плоский список: заголовки дней, под ними подзаголовки-часы,
    // внутри часа — записи (новые сверху).
    final items = <_RowItem>[];
    String? lastDayLabel;
    String? lastHourLabel;
    for (final entry in history) {
      final dayLabel = _dayLabel(entry.playedAt);
      if (dayLabel != lastDayLabel) {
        items.add(_RowItem.forHeader(dayLabel));
        lastDayLabel = dayLabel;
        lastHourLabel = null;
      }
      final hourLabel = _hourLabel(entry.playedAt);
      if (hourLabel != lastHourLabel) {
        items.add(_RowItem.forHourHeader(hourLabel));
        lastHourLabel = hourLabel;
      }
      items.add(_RowItem.forEntry(entry));
    }

    return ListView.builder(
      padding: EdgeInsets.only(
        top: 4,
        bottom: 16 + MediaQuery.of(context).padding.bottom,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        if (item.isDayHeader) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text(
              item.header!.toUpperCase(),
              style: TextStyle(
                color: colors.textTertiary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          );
        }
        if (item.isHourHeader) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
            child: Text(
              item.hourHeader!,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          );
        }
        final entry = item.entry!;
        return _HistoryTile(
          entry: entry,
          colors: colors,
          onTap: () => _play(ref, entry),
          onDismissed: () =>
              ref.read(historyRepositoryProvider).remove(entry),
        );
      },
    );
  }

  void _play(WidgetRef ref, HistoryEntry entry) {
    ref.read(playerServiceProvider).setQueue([entry.track]);
  }

  String _dayLabel(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    final dd = day.day.toString().padLeft(2, '0');
    final mm = day.month.toString().padLeft(2, '0');
    return '$dd.$mm.${day.year}';
  }

  String _hourLabel(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    return '$h:00';
  }
}

class _RowItem {
  const _RowItem.forHeader(this.header)
      : hourHeader = null,
        entry = null;
  const _RowItem.forHourHeader(this.hourHeader)
      : header = null,
        entry = null;
  const _RowItem.forEntry(this.entry)
      : header = null,
        hourHeader = null;

  final String? header;
  final String? hourHeader;
  final HistoryEntry? entry;

  bool get isDayHeader => header != null;
  bool get isHourHeader => hourHeader != null;
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.entry,
    required this.colors,
    required this.onTap,
    required this.onDismissed,
  });

  final HistoryEntry entry;
  final dynamic colors;
  final VoidCallback onTap;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final track = entry.track;
    return Dismissible(
      key: ValueKey(
        '${track.globalId}_${entry.playedAt.millisecondsSinceEpoch}',
      ),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDismissed(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(
          Icons.delete_outline_rounded,
          color: Colors.redAccent,
          size: 26,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: () => showTrackSettingsSheet(context, track: track),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Artwork(url: track.artworkUrl, size: 48, borderRadius: 8),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        letterSpacing: 0,
                      ),
                    ),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _durationText(track.duration),
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _durationText(Duration? d) {
    if (d == null) return '--:--';
    final totalSeconds = d.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final mm = minutes.toString().padLeft(2, '0');
      return '$hours:$mm:$ss';
    }
    return '$minutes:$ss';
  }
}
