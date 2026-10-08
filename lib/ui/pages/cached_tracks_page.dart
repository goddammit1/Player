import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork_helper.dart';
import '../../core/cached_tracks_service.dart';
import '../../core/platform/haptic_helper.dart';
import '../../core/providers.dart';
import '../../sources/source_registry.dart';
import '../desktop/desktop_layout.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/artwork.dart';
import '../widgets/byte_format.dart';
import '../widgets/snack.dart';
import '../widgets/track_settings_sheet.dart';
import '../widgets/wave_bars.dart';

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

BorderRadius _trackBorderRadius(bool isFirst, bool isLast) => BorderRadius.only(
  topLeft: Radius.circular(isFirst ? _Dimens.radiusM : _Dimens.radiusXS),
  topRight: Radius.circular(isFirst ? _Dimens.radiusM : _Dimens.radiusXS),
  bottomLeft: Radius.circular(isLast ? _Dimens.radiusM : _Dimens.radiusXS),
  bottomRight: Radius.circular(isLast ? _Dimens.radiusM : _Dimens.radiusXS),
);

String _fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$s';
  return '${m.toString().padLeft(2, '0')}:$s';
}

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// Заголовок группы по дате кэширования (как в истории).
String _dayLabel(DateTime? dt) {
  if (dt == null) return 'Earlier';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(dt.year, dt.month, dt.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return '${_monthNames[day.month - 1]} ${day.day}, ${day.year}';
}

final _currentTrackIdProvider = StreamProvider<String?>((ref) {
  final player = ref.watch(playerServiceProvider);
  return player.mediaItem.map((item) => item?.id);
});

// ═══════════════════════════════════════════════════════════════════════════
//  CACHED TRACKS PAGE
// ═══════════════════════════════════════════════════════════════════════════

/// Единый список кэшированных треков (стриминговый кэш + Soulseek),
/// сгруппированный по дате кэширования. Стиль карточек — как в истории
/// и плейлистах: тап играет, long-press открывает меню трека, свайп
/// влево удаляет файл из кэша, булавка закрепляет от LRU-эвикции.
class CachedTracksPage extends ConsumerStatefulWidget {
  const CachedTracksPage({super.key});

  @override
  ConsumerState<CachedTracksPage> createState() => _CachedTracksPageState();
}

class _CachedTracksPageState extends ConsumerState<CachedTracksPage> {
  final TextEditingController _searchCtl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _queryNormalized = '';

  List<CachedTrack> _items = const [];
  bool _loading = true;

  /// Поколение загрузки: результат устаревшего [_refresh] (например,
  /// начатого до свайп-удаления) не должен перетирать более свежий.
  int _loadGeneration = 0;

  CachedTracksService get _service => ref.read(cachedTracksServiceProvider);

  @override
  void initState() {
    super.initState();
    _searchCtl.addListener(_onSearchChanged);
    _refresh();
  }

  @override
  void dispose() {
    _searchCtl.removeListener(_onSearchChanged);
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final q = _searchCtl.text.trim().toLowerCase();
    if (q != _queryNormalized) setState(() => _queryNormalized = q);
  }

  Future<void> _refresh() async {
    final gen = ++_loadGeneration;
    List<CachedTrack> items;
    try {
      items = await _service.loadAll();
    } catch (_) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() => _loading = false);
      showSnack(context, 'Failed to load cached tracks');
      return;
    }
    if (!mounted || gen != _loadGeneration) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  static bool _sameEntry(CachedTrack a, CachedTrack b) =>
      a.store == b.store && a.key == b.key;

  List<CachedTrack> get _filtered {
    final q = _queryNormalized;
    if (q.isEmpty) return _items;
    return _items.where((i) {
      return i.track.title.toLowerCase().contains(q) ||
          i.track.artist.toLowerCase().contains(q);
    }).toList();
  }

  // ---- Действия ----

  /// Очередь — видимый (отфильтрованный) список, старт с выбранного.
  /// Фильтр «источник отключён» (как в истории) не нужен: файлы локальные
  /// и играют офлайн, даже если источник выключен для поиска.
  void _play(CachedTrack item, List<CachedTrack> visible) {
    final tracks = visible.map((i) => i.track).toList();
    final idx = tracks.indexWhere((t) => t.globalId == item.track.globalId);
    ref.read(playerServiceProvider).setQueue(
      tracks,
      startIndex: idx >= 0 ? idx : 0,
    );
  }

  Future<void> _showTrackMenu(CachedTrack item) async {
    await showTrackSettingsSheet(context, track: item.track);
    // В меню можно удалить загрузку — перечитываем список.
    if (mounted) await _refresh();
  }

  Future<void> _remove(CachedTrack item) async {
    // Dismissible требует убрать плитку из дерева синхронно; загрузка,
    // начатая до удаления, устаревает.
    _loadGeneration++;
    setState(() {
      _items = _items.where((i) => !_sameEntry(i, item)).toList();
    });
    try {
      await _service.remove(item);
      if (mounted) showSnack(context, 'Removed from cache');
    } on CacheActionException catch (e) {
      if (mounted) showSnack(context, e.message);
      await _refresh();
    } catch (_) {
      if (mounted) showSnack(context, 'Failed to remove from cache');
      await _refresh();
    }
  }

  Future<void> _togglePin(CachedTrack item) async {
    try {
      final updated = await _service.setPinned(item, !item.pinned);
      if (!mounted) return;
      setState(() {
        _items = [for (final i in _items) _sameEntry(i, item) ? updated : i];
      });
      showSnack(context, updated.pinned ? 'Pinned' : 'Unpinned');
    } catch (_) {
      if (mounted) showSnack(context, 'Failed to update pin status');
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await showAppConfirmDialog(
      context: context,
      title: 'Clear cached tracks',
      subtitle: 'All cached tracks, including pinned ones and Soulseek '
          'downloads, will be deleted.\nThis action cannot be undone.',
      confirmLabel: 'Clear',
      isDestructive: true,
    );
    if (confirmed != true) return;
    String message = 'Cached tracks cleared';
    try {
      await _service.clearAudio();
    } on CacheActionException catch (e) {
      message = e.message;
    } catch (_) {
      message = 'Failed to clear cached tracks';
    }
    if (!mounted) return;
    showSnack(context, message);
    await _refresh();
  }

  // ===================================================================
  //  BUILD
  // ===================================================================

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);
    final visible = _filtered;

    final Widget body;
    if (_loading) {
      body = Center(child: CircularProgressIndicator(color: colors.accent));
    } else if (_items.isEmpty) {
      body = _EmptyState(colors: colors);
    } else {
      body = RefreshIndicator(
        color: colors.accent,
        onRefresh: _refresh,
        child: _CachedBody(
          visible: visible,
          usage: CacheUsage.of(_items),
          hasQuery: _queryNormalized.isNotEmpty,
          colors: colors,
          onPlay: (item) => _play(item, visible),
          onMenu: _showTrackMenu,
          onRemove: _remove,
          onTogglePin: _togglePin,
          onClear: _confirmClear,
        ),
      );
    }

    return Scaffold(
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
                  hint: 'Find in cache',
                ),
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
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ТЕЛО СПИСКА
// ═══════════════════════════════════════════════════════════════════════════

class _CachedBody extends StatelessWidget {
  const _CachedBody({
    required this.visible,
    required this.usage,
    required this.hasQuery,
    required this.colors,
    required this.onPlay,
    required this.onMenu,
    required this.onRemove,
    required this.onTogglePin,
    required this.onClear,
  });

  final List<CachedTrack> visible;
  final CacheUsage usage;
  final bool hasQuery;
  final AppColors colors;
  final void Function(CachedTrack) onPlay;
  final void Function(CachedTrack) onMenu;
  final void Function(CachedTrack) onRemove;
  final void Function(CachedTrack) onTogglePin;
  final VoidCallback onClear;

  /// Заголовки дней + треки с флагами первого/последнего в группе.
  List<_RowItem> _buildItems() {
    final items = <_RowItem>[];
    String? currentDay;
    for (var i = 0; i < visible.length; i++) {
      final day = _dayLabel(visible[i].cachedAt);
      final isFirst = day != currentDay;
      if (isFirst) items.add(_RowItem.header(day));
      currentDay = day;
      final isLast = i == visible.length - 1 ||
          _dayLabel(visible[i + 1].cachedAt) != day;
      items.add(_RowItem.track(visible[i], isFirst: isFirst, isLast: isLast));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildItems();
    final summary = '${usage.trackCount} '
        '${usage.trackCount == 1 ? 'track' : 'tracks'} · '
        '${formatBytes(usage.totalBytes)}';

    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Cached',
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 32,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        summary,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
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
        if (visible.isEmpty && hasQuery)
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
              24 + MediaQuery.of(context).padding.bottom,
            ),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = items[index];
                final header = item.header;
                if (header != null) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                    child: Text(
                      header,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                }
                final cached = item.cached!;
                return _CachedTile(
                  key: ValueKey('${cached.store.name}:${cached.key}'),
                  item: cached,
                  isFirst: item.isFirst,
                  isLast: item.isLast,
                  onTap: () => onPlay(cached),
                  onLongPress: () => onMenu(cached),
                  onDismissed: () => onRemove(cached),
                  onTogglePin: () => onTogglePin(cached),
                );
              }, childCount: items.length),
            ),
          ),
      ],
    );
  }
}

class _RowItem {
  const _RowItem.header(this.header)
      : cached = null,
        isFirst = false,
        isLast = false;

  const _RowItem.track(
    this.cached, {
    required this.isFirst,
    required this.isLast,
  }) : header = null;

  final String? header;
  final CachedTrack? cached;
  final bool isFirst;
  final bool isLast;
}

// ═══════════════════════════════════════════════════════════════════════════
//  КАРТОЧКА ТРЕКА (как _HistoryTile)
// ═══════════════════════════════════════════════════════════════════════════

class _CachedTile extends ConsumerWidget {
  const _CachedTile({
    super.key,
    required this.item,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
    required this.onLongPress,
    required this.onDismissed,
    required this.onTogglePin,
  });

  final CachedTrack item;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDismissed;
  final VoidCallback onTogglePin;

  String _subtitle() {
    final source = SourceRegistry.instance.get(item.track.sourceId);
    final parts = [
      item.track.artist,
      source?.displayName ?? item.track.sourceId,
      formatBytes(item.sizeBytes),
    ];
    return parts.where((p) => p.isNotEmpty).join(' · ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = item.track;
    final colors = ref.watch(animatedPaletteProvider);
    final borderRadius = _trackBorderRadius(isFirst, isLast);
    final isCurrentTrack = ref.watch(
      _currentTrackIdProvider.select((id) => id.valueOrNull == track.globalId),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Dismissible(
        key: ValueKey('dismiss_${item.store.name}:${item.key}'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.2),
            borderRadius: borderRadius,
          ),
          child: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
        ),
        onDismissed: (_) {
          HapticHelper.confirmDelete(ref: ref);
          onDismissed();
        },
        child: InkWell(
          onTap: () {
            HapticHelper.light(ref: ref);
            onTap();
          },
          onLongPress: () {
            HapticHelper.medium(ref: ref);
            onLongPress();
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
                      item: item,
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
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitle(),
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
                  if (track.duration != null)
                    Text(
                      _fmtDuration(track.duration!),
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  IconButton(
                    onPressed: onTogglePin,
                    tooltip: item.pinned ? 'Unpin' : 'Pin',
                    icon: Icon(
                      item.pinned
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined,
                      size: 20,
                      color: item.pinned ? colors.accent : colors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackArtwork extends StatelessWidget {
  const _TrackArtwork({
    required this.item,
    required this.isCurrentTrack,
    required this.colors,
  });

  final CachedTrack item;
  final bool isCurrentTrack;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final track = item.track;
    return SizedBox(
      width: _Dimens.trackArtwork,
      height: _Dimens.trackArtwork,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(_Dimens.radiusArtwork),
            child: Artwork(
              trackId: track.id,
              url: track.artworkUrl,
              artist: track.artist,
              title: track.title,
              size: _Dimens.trackArtwork,
              borderRadius: 0,
              aspectRatio: artAspectRatio(track),
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
                  child: WaveBars(color: colors.elevatedHi),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  МЕЛКИЕ ВИДЖЕТЫ
// ═══════════════════════════════════════════════════════════════════════════

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_done_rounded, size: 40, color: colors.textTertiary),
            const SizedBox(height: 12),
            Text(
              'No cached tracks',
              style: TextStyle(color: colors.textSecondary, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              'Played and downloaded tracks will appear here',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textTertiary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

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
    final textStyle = TextStyle(
      color: colors.textPrimary,
      fontSize: 16,
      fontWeight: FontWeight.w600,
    );
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
            child: Center(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                style: textStyle,
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: textStyle.copyWith(color: colors.textSecondary),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  isCollapsed: true,
                ),
                cursorColor: colors.accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
