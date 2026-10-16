// lib/ui/widgets/soulseek_transfer_sheet.dart
//
// Фаза 4 — нижний лист загрузок Soulseek (редизайн по
// plans/soulseek_pages_redesign_plan.md).
//
// Две группы плиток — «In progress» и «Finished» — со скруглениями как у
// списка треков. Плитка: обложка (ленивый поиск по artist/title, как в
// Cached tracks) · название и строка статуса · метка формата справа ·
// управление: кольцо прогресса с паузой/продолжением, отмена, повтор для
// упавших/отменённых. Цвета — только из AppColors; красный — лишь «Failed».
//
// Автообновление через transferEvents stream + периодический poll
// getActiveTransfers для состояний, которые не шлют события.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../sources/soulseek_artwork_query.dart';
import '../../sources/soulseek_models.dart';
import '../../sources/soulseek_platform_channel.dart';
import '../desktop/desktop_layout.dart';
import 'artwork.dart';
import 'byte_format.dart';
import 'grouped_tiles.dart';
import 'snack.dart';

/// Показывает нижний лист загрузок Soulseek.
Future<void> showSoulseekTransferSheet(BuildContext context) {
  if (isDesktop) {
    return showDesktopModalSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _TransferSheet(),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (_) => const _TransferSheet(),
  );
}

class _TransferSheet extends ConsumerStatefulWidget {
  const _TransferSheet();

  @override
  ConsumerState<_TransferSheet> createState() => _TransferSheetState();
}

class _TransferSheetState extends ConsumerState<_TransferSheet> {
  final _platform = SoulseekPlatformChannel.instance;

  List<SoulseekTransferInfo> _transfers = const [];
  StreamSubscription<SoulseekTransferEvent>? _eventSub;
  Timer? _pollTimer;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
    _subscribeEvents();
    _startPolling();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final list = await _platform.getActiveTransfers(includeTerminal: true);
      if (mounted) {
        setState(() {
          _transfers = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _subscribeEvents() {
    if (!_platform.isAvailable) return;
    _eventSub = _platform.transferEvents.listen(
      (_) => _refresh(),
      onError: (_) {},
    );
  }

  /// Периодический poll — страховка для состояний, которые не шлют события
  /// (например, изменение скорости каждую секунду).
  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) _refresh();
    });
  }

  // ── Действия ──

  Future<void> _pause(String downloadId) async {
    try {
      await _platform.pauseDownload(downloadId);
    } catch (_) {
      if (mounted) showSnack(context, 'Failed to pause download');
    }
  }

  Future<void> _resume(String downloadId) async {
    try {
      await _platform.resumeDownload(downloadId);
    } catch (_) {
      if (mounted) showSnack(context, 'Failed to resume download');
    }
  }

  Future<void> _cancel(String downloadId) async {
    try {
      await _platform.cancelDownload(downloadId);
      if (mounted) showSnack(context, 'Download cancelled');
    } catch (_) {
      if (mounted) showSnack(context, 'Failed to cancel download');
    }
  }

  Future<void> _retry(String downloadId) async {
    try {
      final restarted = await _platform.retryDownload(downloadId);
      if (!restarted && mounted) {
        showSnack(context, "Couldn't retry this download");
      }
    } catch (_) {
      if (mounted) showSnack(context, "Couldn't retry this download");
    }
    await _refresh();
  }

  Future<void> _clearFinished() async {
    try {
      await _platform.clearFinishedTransfers();
    } catch (_) {
      if (mounted) showSnack(context, "Couldn't clear finished downloads");
    }
    await _refresh();
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.85;

    final inProgress = _transfers.where((t) => !_isFinished(t.state)).toList()
      ..sort(
        (a, b) => _statePriority(a.state).compareTo(_statePriority(b.state)),
      );
    final finished = _transfers.where((t) => _isFinished(t.state)).toList()
      ..sort(
        (a, b) => _statePriority(a.state).compareTo(_statePriority(b.state)),
      );

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHandle(colors),
          _buildHeader(colors, inProgress, hasFinished: finished.isNotEmpty),
          Flexible(
            child: _loading
                ? _buildLoading(colors)
                : _transfers.isEmpty
                ? _buildEmpty(colors)
                : _buildList(
                    colors,
                    inProgress,
                    finished,
                    media.padding.bottom,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHandle(AppColors colors) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 10),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: colors.textTertiary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader(
    AppColors colors,
    List<SoulseekTransferInfo> inProgress, {
    required bool hasFinished,
  }) {
    final active = inProgress.where((t) => t.state.isActive).length;
    final speed = inProgress
        .where((t) => t.state == SoulseekTransferState.downloading)
        .fold<int>(0, (sum, t) => sum + t.bytesPerSecond);
    final summary = active == 0
        ? null
        : speed > 0
        ? '$active active · ${formatSpeed(speed)}'
        : '$active active';

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 12, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Downloads',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (summary != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    summary,
                    style: TextStyle(
                      color: colors.textTertiary,
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (hasFinished)
            TextButton(
              onPressed: _clearFinished,
              style: TextButton.styleFrom(
                foregroundColor: colors.textSecondary,
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              child: const Text('Clear'),
            ),
        ],
      ),
    );
  }

  Widget _buildLoading(AppColors colors) {
    return SizedBox(
      height: 120,
      child: Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: colors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildEmpty(AppColors colors) {
    return SizedBox(
      height: 200,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_rounded, size: 36, color: colors.textTertiary),
            const SizedBox(height: 12),
            Text(
              'No active downloads',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Downloads from Soulseek will appear here',
              style: TextStyle(color: colors.textTertiary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
    AppColors colors,
    List<SoulseekTransferInfo> inProgress,
    List<SoulseekTransferInfo> finished,
    double bottomInset,
  ) {
    Widget tile(SoulseekTransferInfo t) => _TransferTile(
      key: ValueKey(t.downloadId),
      transfer: t,
      colors: colors,
      onPause: () => _pause(t.downloadId),
      onResume: () => _resume(t.downloadId),
      onCancel: () => _cancel(t.downloadId),
      onRetry: () => _retry(t.downloadId),
    );

    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.only(bottom: 16 + bottomInset),
      children: [
        if (inProgress.isNotEmpty) ...[
          GroupedTilesLabel(title: 'In progress', colors: colors, top: 18),
          GroupedTiles(colors: colors, children: inProgress.map(tile).toList()),
        ],
        if (finished.isNotEmpty) ...[
          GroupedTilesLabel(title: 'Finished', colors: colors, top: 18),
          GroupedTiles(colors: colors, children: finished.map(tile).toList()),
        ],
      ],
    );
  }

  static bool _isFinished(SoulseekTransferState s) =>
      s == SoulseekTransferState.completed ||
      s == SoulseekTransferState.failed ||
      s == SoulseekTransferState.cancelled;

  int _statePriority(SoulseekTransferState s) {
    switch (s) {
      case SoulseekTransferState.downloading:
        return 0;
      case SoulseekTransferState.queued:
        return 1;
      case SoulseekTransferState.queuedRemotely:
        return 1;
      case SoulseekTransferState.connecting:
        return 2;
      case SoulseekTransferState.searching:
        return 3;
      case SoulseekTransferState.prebuffered:
        return 4;
      case SoulseekTransferState.paused:
        return 5;
      case SoulseekTransferState.failed:
        return 6;
      case SoulseekTransferState.completed:
        return 7;
      case SoulseekTransferState.cancelled:
        return 8;
      case SoulseekTransferState.idle:
        return 9;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  _TransferTile — отдельный элемент загрузки
// ═══════════════════════════════════════════════════════════════════════

class _TransferTile extends StatelessWidget {
  const _TransferTile({
    super.key,
    required this.transfer,
    required this.colors,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onRetry,
  });

  static const double _artSize = 44;

  final SoulseekTransferInfo transfer;
  final AppColors colors;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final title = _displayName(t);
    final format = _format(t);
    final dimmed = t.state == SoulseekTransferState.cancelled;

    // Обложку ищем тем же очищенным запросом, что и Cached tracks:
    // title/artist выдачи бывают сырыми («09 Without Me»).
    final remote = t.remoteFilename;
    final query = (remote != null && remote.isNotEmpty)
        ? soulseekArtworkQuery(
            remote,
            fallbackArtist: t.artist ?? '',
            fallbackTitle: title,
          )
        : (artist: t.artist ?? '', title: title);

    // Приглушается только содержимое отменённой загрузки — кнопка «Retry»
    // остаётся яркой, это главное действие плитки.
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: Opacity(
              opacity: dimmed ? 0.55 : 1,
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Artwork(
                      // id Soulseek-трека — его cacheKey (downloadId = dl_<cacheKey>):
                      // та же своя обложка и тот же кэш поиска, что в Cached tracks.
                      trackId: t.downloadId.replaceFirst('dl_', ''),
                      url: null,
                      artist: query.artist.isEmpty ? null : query.artist,
                      title: query.title,
                      size: _artSize,
                      borderRadius: 0,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text.rich(
                          _statusLine(t),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textTertiary,
                            fontSize: 12,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (format != null) ...[
                    const SizedBox(width: 8),
                    _FormatBadge(label: format, colors: colors),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 2),
          ..._controls(t),
        ],
      ),
    );
  }

  /// Строка под названием: исполнитель · прогресс/статус.
  TextSpan _statusLine(SoulseekTransferInfo t) {
    final percent = ((t.progress ?? 0.0) * 100).clamp(0, 100).round();
    final parts = <InlineSpan>[];
    void add(String text, {Color? color}) {
      if (parts.isNotEmpty) parts.add(const TextSpan(text: ' · '));
      parts.add(
        TextSpan(
          text: text,
          style: color == null ? null : TextStyle(color: color),
        ),
      );
    }

    final artist = t.artist;
    if (artist != null && artist.isNotEmpty) add(artist);

    switch (t.state) {
      case SoulseekTransferState.downloading:
      case SoulseekTransferState.prebuffered:
        // Скорость — суммой в заголовке листа: в плитке рядом с метой и
        // двумя кнопками ей не хватает места.
        add('$percent%');
      case SoulseekTransferState.paused:
        add('$percent%');
        add('Paused');
      case SoulseekTransferState.completed:
        add(t.totalBytes > 0 ? humanBytes(t.totalBytes) : 'Completed');
      case SoulseekTransferState.failed:
        add('Failed', color: Colors.redAccent);
        final message = t.message;
        if (message != null && message.isNotEmpty) add(message);
      default:
        add(_stateLabel(t.state));
    }
    return TextSpan(children: parts);
  }

  List<Widget> _controls(SoulseekTransferInfo t) {
    final progress = t.progress ?? 0.0;
    switch (t.state) {
      case SoulseekTransferState.downloading:
        return [
          _IconTap(
            icon: Icons.close_rounded,
            tooltip: 'Cancel',
            colors: colors,
            onTap: onCancel,
          ),
          _ProgressRing(
            value: progress,
            icon: Icons.pause_rounded,
            tooltip: 'Pause',
            colors: colors,
            onTap: onPause,
          ),
        ];
      case SoulseekTransferState.paused:
        return [
          _IconTap(
            icon: Icons.close_rounded,
            tooltip: 'Cancel',
            colors: colors,
            onTap: onCancel,
          ),
          _ProgressRing(
            value: progress,
            icon: Icons.play_arrow_rounded,
            tooltip: 'Resume',
            colors: colors,
            onTap: onResume,
          ),
        ];
      case SoulseekTransferState.queued:
      case SoulseekTransferState.queuedRemotely:
      case SoulseekTransferState.connecting:
      case SoulseekTransferState.searching:
        return [
          _ProgressRing(
            value: 0,
            icon: Icons.close_rounded,
            tooltip: 'Cancel',
            colors: colors,
            onTap: onCancel,
          ),
        ];
      case SoulseekTransferState.prebuffered:
        return [_ProgressRing(value: progress, colors: colors)];
      case SoulseekTransferState.completed:
        return [
          SizedBox.square(
            dimension: 36,
            child: Icon(
              Icons.check_rounded,
              size: 20,
              color: colors.textSecondary,
            ),
          ),
        ];
      case SoulseekTransferState.failed:
      case SoulseekTransferState.cancelled:
        return [
          _IconTap(
            icon: Icons.refresh_rounded,
            tooltip: 'Retry',
            colors: colors,
            onTap: onRetry,
            size: 20,
          ),
        ];
      case SoulseekTransferState.idle:
        return const [SizedBox(width: 36)];
    }
  }

  /// Название загрузки: title, иначе имя файла у пира без расширения.
  /// [localPath] и [downloadId] — хэши, поэтому только крайний фолбэк.
  String _displayName(SoulseekTransferInfo t) {
    final title = t.title;
    if (title != null && title.isNotEmpty) return title;
    final remote = t.remoteFilename;
    if (remote != null && remote.isNotEmpty) {
      final name = _basename(remote);
      final dot = name.lastIndexOf('.');
      return dot > 0 ? name.substring(0, dot) : name;
    }
    if (t.localPath != null && t.localPath!.isNotEmpty) {
      return _basename(t.localPath!);
    }
    return t.downloadId;
  }

  /// Формат файла — расширение исходного имени у пира (FLAC, MP3…).
  String? _format(SoulseekTransferInfo t) {
    final remote = t.remoteFilename;
    if (remote == null || remote.isEmpty) return null;
    final name = _basename(remote);
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot >= name.length - 1) return null;
    final ext = name.substring(dot + 1);
    if (ext.length > 4) return null;
    return ext.toUpperCase();
  }

  String _basename(String path) {
    final i = path.lastIndexOf('/');
    final j = path.lastIndexOf('\\');
    final idx = i > j ? i : j;
    if (idx >= 0 && idx < path.length - 1) return path.substring(idx + 1);
    return path;
  }

  String _stateLabel(SoulseekTransferState s) {
    switch (s) {
      case SoulseekTransferState.idle:
        return 'Idle';
      case SoulseekTransferState.connecting:
        return 'Connecting';
      case SoulseekTransferState.searching:
        return 'Searching';
      case SoulseekTransferState.queued:
        return 'Queued';
      case SoulseekTransferState.queuedRemotely:
        return 'Queued at peer';
      case SoulseekTransferState.downloading:
        return 'Downloading';
      case SoulseekTransferState.prebuffered:
        return 'Prebuffered';
      case SoulseekTransferState.completed:
        return 'Completed';
      case SoulseekTransferState.paused:
        return 'Paused';
      case SoulseekTransferState.failed:
        return 'Failed';
      case SoulseekTransferState.cancelled:
        return 'Cancelled';
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Small widgets
// ═══════════════════════════════════════════════════════════════════════

class _FormatBadge extends StatelessWidget {
  const _FormatBadge({required this.label, required this.colors});

  final String label;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.outline, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: colors.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Кольцо прогресса (как индикатор загрузок на десктопе) с иконкой
/// действия внутри. Без [onTap] — только индикатор.
class _ProgressRing extends StatelessWidget {
  const _ProgressRing({
    required this.value,
    required this.colors,
    this.icon,
    this.tooltip,
    this.onTap,
  });

  final double value;
  final AppColors colors;
  final IconData? icon;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ring = SizedBox.square(
      dimension: 36,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(
              value: value.clamp(0.0, 1.0),
              strokeWidth: 2,
              strokeCap: StrokeCap.round,
              color: colors.textPrimary,
              backgroundColor: colors.outline,
            ),
          ),
          if (icon != null) Icon(icon, size: 16, color: colors.textPrimary),
        ],
      ),
    );
    if (onTap == null) return ring;
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: ring),
      ),
    );
  }
}

class _IconTap extends StatelessWidget {
  const _IconTap({
    required this.icon,
    required this.tooltip,
    required this.colors,
    required this.onTap,
    this.size = 18,
  });

  final IconData icon;
  final String tooltip;
  final AppColors colors;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.square(
            dimension: 36,
            child: Icon(icon, size: size, color: colors.textSecondary),
          ),
        ),
      ),
    );
  }
}
