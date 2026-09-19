import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork_helper.dart';
import '../../core/platform/haptic_helper.dart';
import '../../core/providers.dart';
import '../../core/repositories/history_repository.dart';
import '../../models/track.dart';
import '../../sources/source_registry.dart';
import '../desktop/desktop_layout.dart';
import '../widgets/artwork.dart';
import '../widgets/now_playing_overlay.dart';
import '../widgets/snack.dart';
import '../widgets/track_settings_sheet.dart';
import '../widgets/app_dialogs.dart';
import 'settings_page.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════

abstract final class _Dimens {
  const _Dimens._();

  static const double appBarHeight = 88;
  static const double circleButtonSize = 60;
  static const double searchHeight = 60;
  static const double trackArtwork = 56;
  static const double trackRowHeight = 64;

  static const double radiusM = 15;
  static const double radiusXS = 5;
  static const double radiusArtwork = 12;
}

// ═══════════════════════════════════════════════════════════════════════════
//  HELPERS
// ═══════════════════════════════════════════════════════════════════════════

BorderRadius _trackBorderRadius(bool isFirst, bool isLast) => BorderRadius.only(
  topLeft: Radius.circular(isFirst ? _Dimens.radiusM : _Dimens.radiusXS),
  topRight: Radius.circular(isFirst ? _Dimens.radiusM : _Dimens.radiusXS),
  bottomLeft: Radius.circular(isLast ? _Dimens.radiusM : _Dimens.radiusXS),
  bottomRight: Radius.circular(isLast ? _Dimens.radiusM : _Dimens.radiusXS),
);

String _fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:$s';
  }
  return '${m.toString().padLeft(2, '0')}:$s';
}

// ═══════════════════════════════════════════════════════════════════════════
//  PROVIDERS
// ═══════════════════════════════════════════════════════════════════════════

final _currentTrackIdProvider = StreamProvider<String?>((ref) {
  final player = ref.watch(playerServiceProvider);
  return player.mediaItem.map((item) => item?.id);
});

// ═══════════════════════════════════════════════════════════════════════════
//  HISTORY PAGE
// ═══════════════════════════════════════════════════════════════════════════

/// Страница истории прослушивания с поиском, группировкой по времени
/// и идентичным `PlaylistPage` стилем контейнеров треков.
class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key, this.showNowPlayingOverlay = true});

  final bool showNowPlayingOverlay;

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
    _searchCtl.addListener(_onSearchChanged);
  }

  void _onSearchChanged() {
    final q = _searchCtl.text;
    if (q != _query) {
      setState(() {
        _query = q;
        _queryNormalized = q.trim().toLowerCase();
      });
    }
  }

  @override
  void dispose() {
    _searchCtl.removeListener(_onSearchChanged);
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
    final confirmed = await showAppConfirmDialog(
      context: context,
      title: 'Clear History',
      subtitle: 'Remove all listening history?\nThis action cannot be undone.',
      confirmLabel: 'Clear',
      isDestructive: true, // Включит красный фон кнопки и мягкое красное свечение шапки
    );

    if (confirmed == true) {
      await ref.read(historyRepositoryProvider).clear();
    }
  }

  // ---- Воспроизведение ----

  void _play(HistoryEntry entry, List<HistoryEntry> currentList) {
    final playableTracks = currentList
        .map((e) => e.track)
        .where((t) => !SourceRegistry.instance.isDisabled(t.sourceId))
        .toList();

    final idx = playableTracks.indexWhere((t) => t.globalId == entry.track.globalId);
    ref.read(playerServiceProvider).setQueue(
      playableTracks,
      startIndex: idx >= 0 ? idx : 0,
    );
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
      body = Center(child: CircularProgressIndicator(color: colors.accent));
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
        onPlay: (entry) => _play(entry, history),
        onDismissed: _remove,
        onClear: () => _confirmClear(colors),
      );
    }

    return Stack(
      children: [
        Scaffold(
          backgroundColor: colors.background,
          appBar: AppBar(
            backgroundColor: colors.background,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            toolbarHeight: _Dimens.appBarHeight,
            automaticallyImplyLeading: false,
            titleSpacing: 0,
            title: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: [
                  if (Navigator.of(context).canPop()) ...[
                    _CircleButton(
                      icon: Icons.chevron_left_rounded,
                      onTap: () {
                        HapticHelper.light(ref: ref);
                        Navigator.of(context).maybePop();
                      },
                      colors: colors,
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: _SearchPill(
                      colors: colors,
                      controller: _searchCtl,
                      focusNode: _searchFocus,
                      hint: 'Played before?',
                    ),
                  ),
                  const SizedBox(width: 10),
                  _CircleButton(
                    icon: Icons.settings_rounded,
                    onTap: () {
                      HapticHelper.light(ref: ref);
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
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isDesktop ? 900 : double.infinity,
              ),
              child: body,
            ),
          ),
        ),
        if (widget.showNowPlayingOverlay && !isDesktop)
          const NowPlayingOverlay(),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  КРУГЛАЯ КНОПКА
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
          width: _Dimens.circleButtonSize,
          height: _Dimens.circleButtonSize,
          child: Center(child: Icon(icon, color: colors.textPrimary, size: 20)),
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
    required this.hint,
  });

  final AppColors colors;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.elevated,
      borderRadius: BorderRadius.circular(32),
      child: InkWell(
        borderRadius: BorderRadius.circular(32),
        onTap: () => focusNode.requestFocus(),
        child: SizedBox(
          height: _Dimens.searchHeight,
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
                      hintText: hint,
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
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ТЕЛО СПИСКА
// ═══════════════════════════════════════════════════════════════════════════

class _HistoryBody extends StatelessWidget {
  const _HistoryBody({
    required this.history,
    required this.allHistory,
    required this.query,
    required this.colors,
    required this.dayLabel,
    required this.hourLabel,
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
  final void Function(HistoryEntry) onPlay;
  final void Function(HistoryEntry) onDismissed;
  final VoidCallback onClear;

  /// Формирует элементы списка с расчетом [isFirst] и [isLast]
  /// для каждого блока треков внутри часа.
  List<_RowItem> _buildItems() {
    final items = <_RowItem>[];
    var i = 0;

    while (i < history.length) {
      final currentDay = dayLabel(history[i].playedAt);
      if (i == 0 || dayLabel(history[i - 1].playedAt) != currentDay) {
        items.add(_RowItem.forHeader(currentDay));
      }

      final currentHour = hourLabel(history[i].playedAt);
      if (i == 0 ||
          dayLabel(history[i - 1].playedAt) != currentDay ||
          hourLabel(history[i - 1].playedAt) != currentHour) {
        items.add(_RowItem.forHourHeader(currentHour));
      }

      // Определяем диапазон треков текущей часовой группы
      final groupStart = i;
      var groupEnd = i;
      while (groupEnd + 1 < history.length &&
          dayLabel(history[groupEnd + 1].playedAt) == currentDay &&
          hourLabel(history[groupEnd + 1].playedAt) == currentHour) {
        groupEnd++;
      }

      for (var j = groupStart; j <= groupEnd; j++) {
        items.add(
          _RowItem.forEntry(
            history[j],
            isFirst: j == groupStart,
            isLast: j == groupEnd,
          ),
        );
      }

      i = groupEnd + 1;
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildItems();

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
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
                      Icons.delete_outline_rounded,
                      color: colors.textSecondary,
                      size: 20,
                    ),
                    label: Text(
                      'Clear',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
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
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              120 + MediaQuery.of(context).padding.bottom,
            ),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = items[index];
                if (item.isDayHeader) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                    child: Text(
                      item.header!,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                }
                if (item.isHourHeader) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                    child: Text(
                      item.hourHeader!,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                }
                final entry = item.entry!;
                return _HistoryTile(
                  key: ValueKey(
                    '${entry.track.globalId}_${entry.playedAt.millisecondsSinceEpoch}',
                  ),
                  entry: entry,
                  isFirst: item.isFirst,
                  isLast: item.isLast,
                  onTap: () => onPlay(entry),
                  onDismissed: () => onDismissed(entry),
                );
              }, childCount: items.length),
            ),
          ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ROW ITEM
// ═══════════════════════════════════════════════════════════════════════════

class _RowItem {
  const _RowItem.forHeader(this.header)
      : hourHeader = null,
        entry = null,
        isFirst = false,
        isLast = false;

  const _RowItem.forHourHeader(this.hourHeader)
      : header = null,
        entry = null,
        isFirst = false,
        isLast = false;

  const _RowItem.forEntry(
    this.entry, {
    required this.isFirst,
    required this.isLast,
  })  : header = null,
        hourHeader = null;

  final String? header;
  final String? hourHeader;
  final HistoryEntry? entry;
  final bool isFirst;
  final bool isLast;

  bool get isDayHeader => header != null;
  bool get isHourHeader => hourHeader != null;
}

// ═══════════════════════════════════════════════════════════════════════════
//  КАРТОЧКА ТРЕКА (Стилизована аналогично _TrackTile из PlaylistPage)
// ═══════════════════════════════════════════════════════════════════════════

class _HistoryTile extends ConsumerWidget {
  const _HistoryTile({
    super.key,
    required this.entry,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
    required this.onDismissed,
  });

  final HistoryEntry entry;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = entry.track;
    final colors = ref.watch(animatedPaletteProvider);
    final isDisabled = SourceRegistry.instance.isDisabled(track.sourceId);
    final borderRadius = _trackBorderRadius(isFirst, isLast);

    final isCurrentTrack = ref.watch(
      _currentTrackIdProvider.select((id) => id.valueOrNull == track.globalId),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Dismissible(
        key: ValueKey(
          '${track.globalId}_${entry.playedAt.millisecondsSinceEpoch}',
        ),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.2),
            borderRadius: borderRadius,
          ),
          child: const Icon(
            Icons.delete_outline_rounded,
            color: Colors.redAccent,
          ),
        ),
        onDismissed: (_) {
          HapticHelper.confirmDelete(ref: ref);
          onDismissed();
        },
        child: InkWell(
          onTap: () {
            if (isDisabled) {
              HapticHelper.error(ref: ref);
              showSnack(context, 'Source unavailable for this track');
            } else {
              HapticHelper.light(ref: ref);
              onTap();
            }
          },
          onLongPress: () {
            HapticHelper.medium(ref: ref);
            showTrackSettingsSheet(context, track: track);
          },
          borderRadius: borderRadius,
          child: Container(
            decoration: BoxDecoration(
              color: isCurrentTrack
                  ? colors.elevatedHi.withValues(alpha: 0.5)
                  : colors.elevated,
              borderRadius: borderRadius,
            ),
            child: SizedBox(
              height: _Dimens.trackRowHeight,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: _TrackArtwork(
                      track: track,
                      isDisabled: isDisabled,
                      isCurrentTrack: isCurrentTrack,
                      colors: colors,
                    ),
                  ),
                  const SizedBox(width: 8),
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
                            color: isDisabled
                                ? colors.textSecondary
                                : colors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isDisabled
                              ? '${track.artist} · Source unavailable'
                              : track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isDisabled
                                ? Colors.orange
                                : colors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (track.duration != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Text(
                        _fmt(track.duration!),
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    )
                  else
                    const SizedBox(width: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  TRACK ARTWORK
// ═══════════════════════════════════════════════════════════════════════════

class _TrackArtwork extends StatelessWidget {
  const _TrackArtwork({
    required this.track,
    required this.isDisabled,
    required this.isCurrentTrack,
    required this.colors,
  });

  final Track track;
  final bool isDisabled;
  final bool isCurrentTrack;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _Dimens.trackArtwork,
      height: _Dimens.trackArtwork,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(_Dimens.radiusArtwork),
            child: Opacity(
              opacity: isDisabled ? 0.4 : 1.0,
              child: Artwork(
                trackId: track.id,
                url: track.artworkUrl,
                size: _Dimens.trackArtwork,
                borderRadius: 0,
                aspectRatio: artAspectRatio(track),
              ),
            ),
          ),
          if (isCurrentTrack)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(_Dimens.radiusArtwork),
                ),
                alignment: Alignment.center,
                child: RepaintBoundary(
                  child: _WaveBars(color: colors.elevatedHi),
                ),
              ),
            ),
          if (isDisabled)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: Colors.orange,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.warning_rounded,
                  size: 12,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ANIMATED WAVE BARS
// ═══════════════════════════════════════════════════════════════════════════

class _WaveBars extends StatefulWidget {
  const _WaveBars({required this.color});
  final Color color;

  @override
  State<_WaveBars> createState() => _WaveBarsState();
}

class _WaveBarsState extends State<_WaveBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  static const _barCount = 5;
  static const _barWidth = 3.0;
  static const _barGap = 2.0;
  static const _maxHeight = 20.0;
  static const _minHeight = 4.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(_barCount, (i) {
            final phase = (i / _barCount) * 2 * math.pi;
            final wave =
                math.sin(t * 2 * math.pi + phase) * 0.5 +
                math.sin(t * 4 * math.pi + phase * 1.5) * 0.3;
            final height =
                _minHeight +
                (_maxHeight - _minHeight) *
                    ((wave + 0.8) / 1.6).clamp(0.0, 1.0);

            return Container(
              width: _barWidth,
              height: height,
              margin: EdgeInsets.only(right: i < _barCount - 1 ? _barGap : 0),
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(_barWidth / 2),
              ),
            );
          }),
        );
      },
    );
  }
}
