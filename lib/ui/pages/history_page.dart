import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/history_repository.dart';
import '../../core/providers.dart';
import '../widgets/artwork.dart';
import '../widgets/now_playing_overlay.dart';
import '../widgets/track_settings_sheet.dart';
import 'settings_page.dart';

/// Страница истории прослушивания.
///
/// Хронологический список треков с поиском, группировкой по дням/часам,
/// возможностью очистки всей истории и управления воспроизведением.
class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  final TextEditingController _searchCtl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';
  String _queryNormalized = '';

  @override
  void initState() {
    super.initState();
    _searchCtl.addListener(() {
      final q = _searchCtl.text;
      if (q != _query) {
        setState(() {
          _query = q;
          _queryNormalized = q.trim().toLowerCase();
        });
      }
    });
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ---- Форматирование дат ----

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  String _dayLabel(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${_monthNames[day.month - 1]} ${day.day}, ${day.year}';
  }

  String _hourLabel(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    return '$h:00';
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

  // ---- Фильтрация ----

  List<HistoryEntry> _filtered(List<HistoryEntry> all) {
    if (_queryNormalized.isEmpty) return all;
    final q = _queryNormalized;
    return all.where((e) {
      return e.track.title.toLowerCase().contains(q) ||
          e.track.artist.toLowerCase().contains(q);
    }).toList();
  }

  // ---- Очистка истории ----

  Future<void> _confirmClear(AppColors colors) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.elevatedVariant,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Clear history',
          style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Remove all listening history? This cannot be undone.',
          style: TextStyle(color: colors.textSecondary, fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Clear',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(historyRepositoryProvider).clear();
    }
  }

  // ---- Воспроизведение ----

  void _play(HistoryEntry entry) {
    ref.read(playerServiceProvider).setQueue([entry.track]);
  }

  void _remove(HistoryEntry entry) {
    ref.read(historyRepositoryProvider).remove(entry);
  }

  // ===================================================================
  //  BUILD
  // ===================================================================

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);
    final async = ref.watch(listenHistoryProvider);
    final allHistory = async.value ?? const <HistoryEntry>[];
    final history = _filtered(allHistory);

    Widget body;
    if (async.isLoading && allHistory.isEmpty) {
      body = Center(
        child: CircularProgressIndicator(color: colors.accent),
      );
    } else if (async.hasError) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Failed to load history:\n${async.error}',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary, fontSize: 16),
          ),
        ),
      );
    } else if (allHistory.isEmpty) {
      body = Center(
        child: Text(
          'No listening history yet',
          style: TextStyle(color: colors.textSecondary, fontSize: 16),
        ),
      );
    } else {
      body = _HistoryBody(
        history: history,
        allHistory: allHistory,
        query: _query,
        colors: colors,
        dayLabel: _dayLabel,
        hourLabel: _hourLabel,
        durationText: _durationText,
        onPlay: _play,
        onDismissed: _remove,
        onClear: () => _confirmClear(colors),
      );
    }

    return Stack(
      children: [
        Scaffold(
          backgroundColor: colors.background,
          // ── Верхняя панель ──
          appBar: AppBar(
            backgroundColor: colors.background,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            toolbarHeight: 88,
            automaticallyImplyLeading: false,
            titleSpacing: 0,
            title: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: [
                  _CircleButton(
                    icon: Icons.arrow_back_rounded,
                    onTap: () => Navigator.of(context).pop(),
                    colors: colors,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _SearchPill(
                      colors: colors,
                      controller: _searchCtl,
                      focusNode: _searchFocus,
                    ),
                  ),
                  const SizedBox(width: 10),
                  _CircleButton(
                    icon: Icons.settings_rounded,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SettingsPage()),
                      );
                    },
                    colors: colors,
                  ),
                ],
              ),
            ),
          ),
          // ── Тело ──
          body: body,
        ),
        const NowPlayingOverlay(),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  КРУГЛАЯ КНОПКА (как в search_page.dart)
// ═══════════════════════════════════════════════════════════════════════════

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    required this.colors,
  });

  final IconData icon;
  final VoidCallback onTap;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.elevated,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 60,
          height: 60,
          child: Icon(icon, color: colors.textPrimary, size: 20),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ПОИСКОВАЯ ПИЛЮЛЯ
// ═══════════════════════════════════════════════════════════════════════════

class _SearchPill extends StatelessWidget {
  const _SearchPill({
    required this.colors,
    required this.controller,
    required this.focusNode,
  });

  final AppColors colors;
  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.elevated,
      borderRadius: BorderRadius.circular(32),
      child: SizedBox(
        height: 60,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Played before?',
                    hintStyle: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isCollapsed: true,
                  ),
                  cursorColor: colors.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ТЕЛО СПИСКА (скроллируемая область)
// ═══════════════════════════════════════════════════════════════════════════

class _HistoryBody extends StatelessWidget {
  const _HistoryBody({
    required this.history,
    required this.allHistory,
    required this.query,
    required this.colors,
    required this.dayLabel,
    required this.hourLabel,
    required this.durationText,
    required this.onPlay,
    required this.onDismissed,
    required this.onClear,
  });

  final List<HistoryEntry> history;
  final List<HistoryEntry> allHistory;
  final String query;
  final AppColors colors;
  final String Function(DateTime) dayLabel;
  final String Function(DateTime) hourLabel;
  final String Function(Duration?) durationText;
  final void Function(HistoryEntry) onPlay;
  final void Function(HistoryEntry) onDismissed;
  final VoidCallback onClear;

  List<_RowItem> _buildItems() {
    final items = <_RowItem>[];
    String? lastDayLabel;
    String? lastHourLabel;
    for (final entry in history) {
      final dl = dayLabel(entry.playedAt);
      if (dl != lastDayLabel) {
        items.add(_RowItem.forHeader(dl));
        lastDayLabel = dl;
        lastHourLabel = null;
      }
      final hl = hourLabel(entry.playedAt);
      if (hl != lastHourLabel) {
        items.add(_RowItem.forHourHeader(hl));
        lastHourLabel = hl;
      }
      items.add(_RowItem.forEntry(entry));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildItems();

    return CustomScrollView(
      slivers: [
        // ── Заголовок HISTORY + кнопка Clear ──
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'History',
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (allHistory.isNotEmpty)
                  TextButton.icon(
                    onPressed: onClear,
                    icon: Icon(
                      Icons.delete_rounded,
                      color: colors.textSecondary,
                      size: 18,
                    ),
                    label: Text(
                      'Clear',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
          ),
        ),
        // ── Пустой результат поиска ──
        if (history.isEmpty && query.isNotEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                'Nothing found',
                style: TextStyle(color: colors.textSecondary, fontSize: 16),
              ),
            ),
          )
        else
          // ── Группированный список ──
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: 120 + MediaQuery.of(context).padding.bottom,
            ),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final item = items[index];
                  if (item.isDayHeader) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text(
                        item.header!,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    );
                  }
                  if (item.isHourHeader) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text(
                        item.hourHeader!,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    );
                  }
                  final entry = item.entry!;
                  return _HistoryTile(
                    entry: entry,
                    colors: colors,
                    durationText: durationText,
                    onTap: () => onPlay(entry),
                    onDismissed: () => onDismissed(entry),
                  );
                },
                childCount: items.length,
              ),
            ),
          ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ROW ITEM — элемент группировки
// ═══════════════════════════════════════════════════════════════════════════

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

// ═══════════════════════════════════════════════════════════════════════════
//  КАРТОЧКА ТРЕКА
// ═══════════════════════════════════════════════════════════════════════════

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.entry,
    required this.colors,
    required this.durationText,
    required this.onTap,
    required this.onDismissed,
  });

  final HistoryEntry entry;
  final AppColors colors;
  final String Function(Duration?) durationText;
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
              Artwork(url: track.artworkUrl, trackId: track.id, size: 52, borderRadius: 10),
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
                        fontSize: 16,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                durationText(track.duration),
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
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
}
