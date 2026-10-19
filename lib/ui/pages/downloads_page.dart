// lib/ui/pages/downloads_page.dart
//
// Downloads — единый экран загрузок и кэша (бывшие лист загрузок Soulseek
// и страница Cached tracks):
//  - сверху «Downloading» — идущие загрузки Soulseek с живым прогрессом и
//    приостановленные (пауза пользователя или закрытие приложения —
//    натив поднимает их после рестарта, их можно продолжить);
//  - «Failed» — упавшие в этой сессии, с повтором; ошибки прошлых запусков
//    не показываются (SoulseekSessionTransfers), отменённые пользователем —
//    тоже;
//  - ниже — готовые треки (стриминговый кэш + Soulseek) по дням: загрузка,
//    дошедшая до конца, появляется здесь же, в «Today».
// Тап играет, long-press открывает меню трека, свайп влево удаляет файл.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork_helper.dart';
import '../../core/cached_tracks_service.dart';
import '../../core/platform/haptic_helper.dart';
import '../../core/providers.dart';
import '../../sources/soulseek_models.dart';
import '../../sources/soulseek_platform_channel.dart';
import '../../sources/soulseek_session_transfers.dart';
import '../../sources/soulseek_source.dart';
import '../../sources/source_registry.dart';
import '../desktop/desktop_layout.dart';
import '../desktop/track_context_menu.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/artwork.dart';
import '../widgets/byte_format.dart';
import '../widgets/grouped_tiles.dart';
import '../widgets/snack.dart';
import '../widgets/soulseek_transfer_tile.dart';
import '../widgets/track_settings_sheet.dart';
import '../widgets/wave_bars.dart';

/// Открывает Downloads поверх всего приложения — для мест вне обычного
/// дерева навигации (top bar десктопа, шторка трека).
Future<void> openDownloadsPage(BuildContext context) {
  final nav = rootNavigatorKey.currentState ?? Navigator.of(context);
  return nav.push(MaterialPageRoute(builder: (_) => const DownloadsPage()));
}

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

  static const double radiusArtwork = 12;
}


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

/// Порядок в группе: сначала то, что качается сейчас.
int _statePriority(SoulseekTransferState s) {
  switch (s) {
    case SoulseekTransferState.downloading:
      return 0;
    case SoulseekTransferState.prebuffered:
      return 1;
    case SoulseekTransferState.connecting:
      return 2;
    case SoulseekTransferState.queued:
    case SoulseekTransferState.queuedRemotely:
      return 3;
    case SoulseekTransferState.searching:
      return 4;
    case SoulseekTransferState.paused:
      return 5;
    case SoulseekTransferState.failed:
      return 6;
    case SoulseekTransferState.cancelled:
      return 7;
    case SoulseekTransferState.completed:
    case SoulseekTransferState.idle:
      return 8;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  DOWNLOADS PAGE
// ═══════════════════════════════════════════════════════════════════════════

class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key, this.channel});

  /// Канал Soulseek (тесты); по умолчанию — платформенный.
  final SoulseekPlatformChannel? channel;

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  final TextEditingController _searchCtl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _queryNormalized = '';

  List<CachedTrack> _items = const [];
  late CacheUsage _usage = CacheUsage.of(_items);
  bool _loading = true;

  /// Поколение загрузки: результат устаревшего [_refresh] (например,
  /// начатого до свайп-удаления) не должен перетирать более свежий.
  int _loadGeneration = 0;

  // ── Загрузки Soulseek ──
  final Map<String, SoulseekTransferInfo> _transfers = {};
  StreamSubscription<SoulseekTransferEvent>? _transferSub;

  /// Номер последнего события по каждому трансферу: снимок, запрошенный
  /// раньше события, не откатывает и не удаляет более свежее состояние.
  final Map<String, int> _eventSeq = {};
  int _seq = 0;

  /// Скорость и прогресс не всегда приходят событиями — пока данные идут,
  /// список перечитывается раз в секунду.
  Timer? _pollTimer;

  /// Загрузка дошла до конца → трек появится в кэше. Натив дописывает
  /// запись кэша после события (у больших файлов — заметно позже), поэтому
  /// список перечитывается дважды.
  final List<Timer> _cacheRefreshTimers = [];

  CachedTracksService get _service => ref.read(cachedTracksServiceProvider);

  SoulseekPlatformChannel get _channel =>
      widget.channel ?? SoulseekPlatformChannel.instance;

  SoulseekSessionTransfers get _session => SoulseekSessionTransfers.instance;

  @override
  void initState() {
    super.initState();
    _searchCtl.addListener(_onSearchChanged);
    _refresh();
    if (_channel.isAvailable) {
      _transferSub = _channel.transferEvents.listen(
        _onTransferEvent,
        onError: (_) {},
      );
      _refreshTransfers();
    }
  }

  @override
  void dispose() {
    _searchCtl.removeListener(_onSearchChanged);
    _searchCtl.dispose();
    _searchFocus.dispose();
    _transferSub?.cancel();
    _pollTimer?.cancel();
    for (final t in _cacheRefreshTimers) {
      t.cancel();
    }
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
      showSnack(context, 'Failed to load downloads');
      return;
    }
    if (!mounted || gen != _loadGeneration) return;
    setState(() {
      _items = items;
      _usage = CacheUsage.of(items);
      _loading = false;
    });
  }

  Future<void> _refreshAll() async {
    await Future.wait([_refresh(), _refreshTransfers()]);
  }

  // ---- Загрузки ----

  void _onTransferEvent(SoulseekTransferEvent e) {
    if (!mounted) return;
    final info = e.transfer;
    // Событие пришло, пока страница открыта, — загрузка точно из этой
    // сессии (глобальный трекер мог подписаться позже, в тестах — нет).
    _session.add(info.downloadId);
    _eventSeq[info.downloadId] = ++_seq;
    if (_applyTransfer(info)) setState(() {});
    _syncPolling();
  }

  /// Обновляет запись (false — ничего не изменилось); завершение загрузки
  /// → перечитать кэш.
  bool _applyTransfer(SoulseekTransferInfo info) {
    final previous = _transfers[info.downloadId];
    if (previous != null && _sameTransfer(previous, info)) return false;
    _transfers[info.downloadId] = info;
    final completed = info.state == SoulseekTransferState.completed;
    // Первое, что страница узнала о загрузке этой сессии, — уже
    // «completed» (событие обогнало снимок): кэш тоже перечитываем.
    // Завершённые в прошлых запусках давно в кэше — их не трогаем.
    final justCompleted = completed &&
        (previous == null
            ? _session.contains(info.downloadId)
            : previous.state != SoulseekTransferState.completed);
    if (justCompleted) _scheduleCacheRefresh();
    return true;
  }

  static bool _sameTransfer(SoulseekTransferInfo a, SoulseekTransferInfo b) =>
      a.state == b.state &&
      a.bytesReceived == b.bytesReceived &&
      a.totalBytes == b.totalBytes &&
      a.bytesPerSecond == b.bytesPerSecond &&
      a.message == b.message &&
      a.title == b.title &&
      a.artist == b.artist &&
      a.remoteFilename == b.remoteFilename &&
      a.placeInQueue == b.placeInQueue &&
      a.queueStatus == b.queueStatus;

  void _scheduleCacheRefresh() {
    for (final t in _cacheRefreshTimers) {
      t.cancel();
    }
    _cacheRefreshTimers
      ..clear()
      ..add(Timer(const Duration(milliseconds: 600), _refresh))
      ..add(Timer(const Duration(milliseconds: 2500), _refresh));
  }

  Future<void> _refreshTransfers() async {
    if (!_channel.isAvailable) return;
    final requestedAt = _seq;
    final List<SoulseekTransferInfo> list;
    try {
      list = await _channel.getActiveTransfers(includeTerminal: true);
    } catch (_) {
      // Сервис ещё не поднят — загрузок нет, список появится с событием.
      if (mounted) _syncPolling();
      return;
    }
    if (!mounted) return;
    // Событие пришло, пока снимок был в пути, — оно свежее снимка.
    bool newerThanSnapshot(String id) => (_eventSeq[id] ?? 0) > requestedAt;
    var changed = false;
    final ids = <String>{};
    for (final t in list) {
      ids.add(t.downloadId);
      if (newerThanSnapshot(t.downloadId)) continue;
      if (_applyTransfer(t)) changed = true;
    }
    final before = _transfers.length;
    _transfers.removeWhere(
      (id, _) => !ids.contains(id) && !newerThanSnapshot(id),
    );
    if (_transfers.length != before) changed = true;
    if (changed) setState(() {});
    _syncPolling();
  }

  /// Данные идут — скорость и прогресс меняются каждую секунду. Очередь,
  /// пауза и прочие состояния меняются событиями, их не опрашиваем.
  static bool _isTransferring(SoulseekTransferInfo t) =>
      t.state == SoulseekTransferState.downloading ||
      t.state == SoulseekTransferState.prebuffered;

  void _syncPolling() {
    final busy = _transfers.values.any(_isTransferring);
    if (busy && _pollTimer == null) {
      _pollTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refreshTransfers(),
      );
    } else if (!busy) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  /// Идёт или стоит на паузе — группа «Downloading». Пауза показывается
  /// и из прошлых запусков: её поставил пользователь или закрытие
  /// приложения, а не ошибка, — загрузку можно продолжить.
  bool _isInProgress(SoulseekTransferInfo t) {
    switch (t.state) {
      case SoulseekTransferState.downloading:
      case SoulseekTransferState.prebuffered:
      case SoulseekTransferState.connecting:
      case SoulseekTransferState.queued:
      case SoulseekTransferState.queuedRemotely:
      case SoulseekTransferState.searching:
      case SoulseekTransferState.paused:
        return true;
      case SoulseekTransferState.failed:
      case SoulseekTransferState.cancelled:
      case SoulseekTransferState.completed:
      case SoulseekTransferState.idle:
        return false;
    }
  }

  /// Упала в этой сессии — группа «Failed». Отменённые пользователем не
  /// показываются: их убрали намеренно.
  bool _isFailed(SoulseekTransferInfo t) =>
      t.state == SoulseekTransferState.failed &&
      _session.contains(t.downloadId);

  bool _matchesQuery(SoulseekTransferInfo t) {
    final q = _queryNormalized;
    if (q.isEmpty) return true;
    return soulseekTransferTitle(t).toLowerCase().contains(q) ||
        (t.artist ?? '').toLowerCase().contains(q);
  }

  List<SoulseekTransferInfo> _visibleTransfers(
    bool Function(SoulseekTransferInfo) test,
  ) {
    return _transfers.values
        .where((t) => test(t) && _matchesQuery(t))
        .toList()
      ..sort(
        (a, b) => _statePriority(a.state).compareTo(_statePriority(b.state)),
      );
  }

  Future<void> _pause(String id) async {
    try {
      await _channel.pauseDownload(id);
    } catch (_) {
      if (mounted) showSnack(context, 'Failed to pause download');
    }
    await _refreshTransfers();
  }

  Future<void> _resume(String id) async {
    try {
      await _channel.resumeDownload(id);
    } catch (_) {
      if (mounted) showSnack(context, 'Failed to resume download');
    }
    await _refreshTransfers();
  }

  Future<void> _cancel(String id) async {
    try {
      await _channel.cancelDownload(id);
    } catch (_) {
      if (mounted) showSnack(context, 'Failed to cancel download');
    }
    await _refreshTransfers();
  }

  Future<void> _retry(String id) async {
    try {
      final restarted = await _channel.retryDownload(id);
      if (!restarted && mounted) {
        showSnack(context, "Couldn't retry this download");
      }
    } catch (_) {
      if (mounted) showSnack(context, "Couldn't retry this download");
    }
    await _refreshTransfers();
  }

  /// Убирает упавшие из списка (натив забывает и завершённые — они уже
  /// в кэше ниже).
  Future<void> _clearFailed() async {
    try {
      await _channel.clearFinishedTransfers();
    } catch (_) {
      if (mounted) showSnack(context, "Couldn't clear failed downloads");
    }
    await _refreshTransfers();
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

  // ---- Действия с готовыми треками ----

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

  /// Десктоп: правый клик. Кэшем управляет сам экран (remove через
  /// [_service] знает оба хранилища), поэтому Download-пункт меню скрыт.
  void _showContextMenu(CachedTrack item, Offset position) {
    showTrackContextMenu(
      context,
      track: item.track,
      position: position,
      showCacheAction: false,
      trailing: [
        TrackMenuAction(
          icon: Icons.delete_outline_rounded,
          label: 'Remove from downloads',
          destructive: true,
          onSelected: () => _remove(item),
        ),
      ],
    );
  }

  Future<void> _remove(CachedTrack item) async {
    // Dismissible требует убрать плитку из дерева синхронно; загрузка,
    // начатая до удаления, устаревает.
    _loadGeneration++;
    setState(() {
      _items = _items.where((i) => !_sameEntry(i, item)).toList();
      _usage = CacheUsage.of(_items);
    });
    try {
      await _service.remove(item);
      if (mounted) showSnack(context, 'Removed from downloads');
    } on CacheActionException catch (e) {
      if (mounted) showSnack(context, e.message);
      await _refresh();
    } catch (_) {
      if (mounted) showSnack(context, 'Failed to remove');
      await _refresh();
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await showAppConfirmDialog(
      context: context,
      title: 'Clear downloads',
      subtitle: 'All downloaded and cached tracks, including Soulseek '
          'downloads, will be deleted.\nThis action cannot be undone.',
      confirmLabel: 'Clear',
      isDestructive: true,
    );
    if (confirmed != true) return;
    String message = 'Downloads cleared';
    try {
      await _service.clearAudio();
    } on CacheActionException catch (e) {
      message = e.message;
    } catch (_) {
      message = 'Failed to clear downloads';
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
    final inProgress = _visibleTransfers(_isInProgress);
    final failed = _visibleTransfers(_isFailed);
    final hasTransfers = _transfers.values.any(
      (t) => _isInProgress(t) || _isFailed(t),
    );

    final Widget body;
    if (_loading && !hasTransfers) {
      body = Center(child: CircularProgressIndicator(color: colors.accent));
    } else if (_items.isEmpty && !hasTransfers) {
      body = _EmptyState(colors: colors);
    } else {
      body = RefreshIndicator(
        color: colors.accent,
        onRefresh: _refreshAll,
        child: _DownloadsBody(
          visible: visible,
          inProgress: inProgress,
          failed: failed,
          usage: _usage,
          hasQuery: _queryNormalized.isNotEmpty,
          colors: colors,
          transferTile: (t, {required isFirst, required isLast}) =>
              SoulseekTransferTile(
                key: ValueKey('transfer_${t.downloadId}'),
                transfer: t,
                colors: colors,
                isFirst: isFirst,
                isLast: isLast,
                onPause: () => _pause(t.downloadId),
                onResume: () => _resume(t.downloadId),
                onCancel: () => _cancel(t.downloadId),
                onRetry: () => _retry(t.downloadId),
              ),
          onPlay: (item) => _play(item, visible),
          onMenu: _showTrackMenu,
          onContextMenu: _showContextMenu,
          onRemove: _remove,
          onClear: _confirmClear,
          onClearFailed: _clearFailed,
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
                  hint: 'Find in downloads',
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

typedef _TransferTileBuilder = Widget Function(
  SoulseekTransferInfo transfer, {
  required bool isFirst,
  required bool isLast,
});

class _DownloadsBody extends StatelessWidget {
  const _DownloadsBody({
    required this.visible,
    required this.inProgress,
    required this.failed,
    required this.usage,
    required this.hasQuery,
    required this.colors,
    required this.transferTile,
    required this.onPlay,
    required this.onMenu,
    required this.onContextMenu,
    required this.onRemove,
    required this.onClear,
    required this.onClearFailed,
  });

  final List<CachedTrack> visible;
  final List<SoulseekTransferInfo> inProgress;
  final List<SoulseekTransferInfo> failed;
  final CacheUsage usage;
  final bool hasQuery;
  final AppColors colors;
  final _TransferTileBuilder transferTile;
  final void Function(CachedTrack) onPlay;
  final void Function(CachedTrack) onMenu;
  final void Function(CachedTrack, Offset globalPosition) onContextMenu;
  final void Function(CachedTrack) onRemove;
  final VoidCallback onClear;
  final VoidCallback onClearFailed;

  /// Группы загрузок, затем заголовки дней + треки с флагами
  /// первого/последнего в группе.
  List<_RowItem> _buildItems() {
    final items = <_RowItem>[];

    void addTransfers(
      String title,
      List<SoulseekTransferInfo> list, {
      String? trailing,
      VoidCallback? onTrailing,
    }) {
      if (list.isEmpty) return;
      items.add(_RowItem.header(
        title,
        trailing: trailing,
        onTrailing: onTrailing,
      ));
      for (var i = 0; i < list.length; i++) {
        items.add(_RowItem.transfer(
          list[i],
          isFirst: i == 0,
          isLast: i == list.length - 1,
        ));
      }
    }

    final speed = inProgress.fold<int>(0, (s, t) => s + t.bytesPerSecond);
    addTransfers(
      'Downloading',
      inProgress,
      trailing: speed > 0 ? formatSpeed(speed) : null,
    );
    addTransfers(
      'Failed',
      failed,
      trailing: 'Clear',
      onTrailing: onClearFailed,
    );

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
                        'Downloads',
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
                if (usage.trackCount > 0)
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
        if (items.isEmpty && hasQuery)
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
                  return _SectionHeader(
                    title: header,
                    trailing: item.trailing,
                    onTrailing: item.onTrailing,
                    colors: colors,
                  );
                }
                final transfer = item.transfer;
                if (transfer != null) {
                  return transferTile(
                    transfer,
                    isFirst: item.isFirst,
                    isLast: item.isLast,
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
                  onContextMenu: (pos) => onContextMenu(cached, pos),
                  onDismissed: () => onRemove(cached),
                );
              }, childCount: items.length),
            ),
          ),
      ],
    );
  }
}

class _RowItem {
  const _RowItem.header(this.header, {this.trailing, this.onTrailing})
      : cached = null,
        transfer = null,
        isFirst = false,
        isLast = false;

  const _RowItem.track(
    this.cached, {
    required this.isFirst,
    required this.isLast,
  })  : header = null,
        transfer = null,
        trailing = null,
        onTrailing = null;

  const _RowItem.transfer(
    this.transfer, {
    required this.isFirst,
    required this.isLast,
  })  : header = null,
        cached = null,
        trailing = null,
        onTrailing = null;

  final String? header;

  /// Подпись справа от заголовка группы (скорость или кнопка «Clear»).
  final String? trailing;
  final VoidCallback? onTrailing;

  final CachedTrack? cached;
  final SoulseekTransferInfo? transfer;
  final bool isFirst;
  final bool isLast;
}

/// Заголовок группы: день кэширования или группа загрузок.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.colors,
    this.trailing,
    this.onTrailing,
  });

  final String title;
  final AppColors colors;
  final String? trailing;
  final VoidCallback? onTrailing;

  @override
  Widget build(BuildContext context) {
    final trailingStyle = TextStyle(
      color: colors.textSecondary,
      fontSize: 14,
      fontWeight: FontWeight.w500,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 0, 8),
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (trailing != null)
              onTrailing == null
                  ? Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(trailing!, style: trailingStyle),
                    )
                  : TextButton(
                      onPressed: onTrailing,
                      style: TextButton.styleFrom(
                        foregroundColor: colors.textSecondary,
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(trailing!, style: trailingStyle),
                    ),
          ],
        ),
      ),
    );
  }
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
    required this.onContextMenu,
  });

  final CachedTrack item;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDismissed;
  final ValueChanged<Offset> onContextMenu;

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
    final borderRadius = groupedTileRadius(isFirst, isLast);
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
          onSecondaryTapDown:
              isDesktop ? (d) => onContextMenu(d.globalPosition) : null,
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
                  if (track.duration != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      _fmtDuration(track.duration!),
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
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
    // Soulseek: title/artist выдачи бывают сырыми («09 Without Me», папка
    // «1-10» вместо исполнителя) — обложку ищем тем же очищенным запросом,
    // что и поиск, иначе она не находится.
    final query = item.store == CacheStore.soulseek
        ? SoulseekSource.artworkQuery(track)
        : (artist: track.artist, title: track.title);
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
              artist: query.artist,
              title: query.title,
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
              'No downloads yet',
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
