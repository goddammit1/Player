// lib/ui/widgets/soulseek_transfer_sheet.dart
//
// Фаза 4 — нижний лист активных загрузок Soulseek.
//
// Показывает список активных/недавних трансферов с:
//  - идентификатором загрузки (и именем файла из localPath, если доступно)
//  - индикатором статуса (queued / downloading / paused / completed / failed)
//  - прогресс-баром с процентами
//  - скоростью (KB/s) и размером (получено / всего)
//  - кнопками Pause / Resume / Cancel
//
// Автообновление через transferEvents stream + периодический poll
// getActiveTransfers для состояний, которые не шлют события.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../sources/soulseek_models.dart';
import '../../sources/soulseek_platform_channel.dart';
import '../desktop/desktop_layout.dart';
import 'snack.dart';

/// Показывает нижний лист активных загрузок Soulseek.
Future<void> showSoulseekTransferSheet(BuildContext context) {
  if (isDesktop) {
    return showDesktopModalSheet(
      context: context,
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

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.85;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHandle(colors),
          _buildHeader(colors),
          const Divider(height: 1),
          Flexible(
            child: _loading
                ? _buildLoading(colors)
                : _transfers.isEmpty
                    ? _buildEmpty(colors)
                    : _buildList(colors, media.padding.bottom),
          ),
        ],
      ),
    );
  }

  Widget _buildHandle(dynamic colors) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: colors.textTertiary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader(dynamic colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
      child: Row(
        children: [
          Icon(Icons.download_rounded, color: colors.textPrimary, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Downloads',
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_transfers.any(_isActive))
            Text(
              '${_transfers.where(_isActive).length} active',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(Icons.close_rounded, color: colors.textSecondary),
            iconSize: 22,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  bool _isActive(SoulseekTransferInfo t) => t.state.isActive;

  Widget _buildLoading(dynamic colors) {
    return SizedBox(
      height: 120,
      child: Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: colors.accent,
        ),
      ),
    );
  }

  Widget _buildEmpty(dynamic colors) {
    return SizedBox(
      height: 200,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_download_rounded,
              size: 40,
              color: colors.textTertiary,
            ),
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
              style: TextStyle(
                color: colors.textTertiary,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(dynamic colors, double bottomInset) {
    // Сортировка: активные первыми, затем completed, затем failed/cancelled.
    final sorted = [..._transfers]..sort((a, b) {
        final pa = _statePriority(a.state);
        final pb = _statePriority(b.state);
        return pa.compareTo(pb);
      });

    return ListView.separated(
      shrinkWrap: true,
      padding: EdgeInsets.only(top: 4, bottom: 16 + bottomInset),
      itemCount: sorted.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        indent: 16,
        endIndent: 16,
        color: colors.outline.withValues(alpha: 0.3),
      ),
      itemBuilder: (context, index) {
        final t = sorted[index];
        return _TransferTile(
          transfer: t,
          colors: colors,
          onPause: () => _pause(t.downloadId),
          onResume: () => _resume(t.downloadId),
          onCancel: () => _cancel(t.downloadId),
        );
      },
    );
  }

  int _statePriority(SoulseekTransferState s) {
    switch (s) {
      case SoulseekTransferState.downloading:
        return 0;
      case SoulseekTransferState.queued:
        return 1;
      case SoulseekTransferState.connecting:
        return 2;
      case SoulseekTransferState.searching:
        return 3;
      case SoulseekTransferState.prebuffered:
        return 4;
      case SoulseekTransferState.paused:
        return 5;
      case SoulseekTransferState.completed:
        return 6;
      case SoulseekTransferState.failed:
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
    required this.transfer,
    required this.colors,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
  });

  final SoulseekTransferInfo transfer;
  final dynamic colors;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    // progress может быть null (если totalBytes <= 0) — используем 0.0.
    final progressValue = t.progress ?? 0.0;
    final percent = (progressValue * 100).clamp(0, 100).round();
    final isActive = t.state == SoulseekTransferState.downloading ||
        t.state == SoulseekTransferState.queued ||
        t.state == SoulseekTransferState.connecting ||
        t.state == SoulseekTransferState.searching;
    final isPaused = t.state == SoulseekTransferState.paused;

    // Отображаемое имя: из localPath (если есть), иначе из downloadId.
    final displayName = _displayName(t);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Строка: иконка статуса + имя ──
          Row(
            children: [
              _StateIcon(state: t.state, colors: colors),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (t.downloadId != displayName)
                      Text(
                        t.downloadId,
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
              // ── Кнопки управления ──
              if (isActive || isPaused) ...[
                if (isPaused)
                  _ControlButton(
                    icon: Icons.play_arrow_rounded,
                    colors: colors,
                    onTap: onResume,
                  )
                else
                  _ControlButton(
                    icon: Icons.pause_rounded,
                    colors: colors,
                    onTap: onPause,
                  ),
                _ControlButton(
                  icon: Icons.close_rounded,
                  colors: colors,
                  onTap: onCancel,
                  destructive: true,
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),

          // ── Прогресс-бар ──
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progressValue,
              minHeight: 6,
              backgroundColor: colors.elevated,
              color: _progressColor(t.state, colors),
            ),
          ),
          const SizedBox(height: 6),

          // ── Строка: процент / размер / скорость / сообщение ──
          Row(
            children: [
              Text(
                '$percent%',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _formatSize(t.bytesReceived, t.totalBytes),
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (t.bytesPerSecond > 0 && isActive) ...[
                const SizedBox(width: 10),
                Text(
                  _formatSpeed(t.bytesPerSecond),
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
              const Spacer(),
              if (t.state == SoulseekTransferState.failed &&
                  t.message != null &&
                  t.message!.isNotEmpty)
                Expanded(
                  child: Text(
                    t.message!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: 11,
                    ),
                  ),
                )
              else
                Text(
                  _stateLabel(t.state),
                  style: TextStyle(
                    color: colors.textTertiary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Извлекает отображаемое имя из [localPath] (если есть) или из [downloadId].
  String _displayName(SoulseekTransferInfo t) {
    if (t.localPath != null && t.localPath!.isNotEmpty) {
      return _basename(t.localPath!);
    }
    return t.downloadId;
  }

  String _basename(String path) {
    final i = path.lastIndexOf('/');
    final j = path.lastIndexOf('\\');
    final idx = i > j ? i : j;
    if (idx >= 0 && idx < path.length - 1) return path.substring(idx + 1);
    return path;
  }

  String _formatSize(int received, int total) {
    final r = _humanBytes(received);
    if (total > 0) return '$r / ${_humanBytes(total)}';
    return r;
  }

  String _formatSpeed(int bytesPerSec) => '${_humanBytes(bytesPerSec)}/s';

  String _humanBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    if (unit == 0) return '$bytes B';
    return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[unit]}';
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

  Color _progressColor(SoulseekTransferState s, dynamic colors) {
    switch (s) {
      case SoulseekTransferState.completed:
        return Colors.greenAccent;
      case SoulseekTransferState.failed:
        return Colors.redAccent;
      case SoulseekTransferState.cancelled:
        return colors.textTertiary as Color;
      case SoulseekTransferState.paused:
        return Colors.orangeAccent;
      default:
        return colors.accent as Color;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Small widgets
// ═══════════════════════════════════════════════════════════════════════

class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.state, required this.colors});

  final SoulseekTransferState state;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (state) {
      SoulseekTransferState.downloading => (
        Icons.downloading_rounded,
        colors.accent as Color,
      ),
      SoulseekTransferState.queued => (
        Icons.hourglass_top_rounded,
        colors.textTertiary as Color,
      ),
      SoulseekTransferState.connecting => (
        Icons.wifi_find_rounded,
        colors.textTertiary as Color,
      ),
      SoulseekTransferState.searching => (
        Icons.search_rounded,
        colors.textTertiary as Color,
      ),
      SoulseekTransferState.prebuffered => (
        Icons.memory_rounded,
        colors.textTertiary as Color,
      ),
      SoulseekTransferState.paused => (
        Icons.pause_circle_outline_rounded,
        Colors.orangeAccent,
      ),
      SoulseekTransferState.completed => (
        Icons.check_circle_rounded,
        Colors.greenAccent,
      ),
      SoulseekTransferState.failed => (
        Icons.error_outline_rounded,
        Colors.redAccent,
      ),
      SoulseekTransferState.cancelled => (
        Icons.cancel_rounded,
        colors.textTertiary as Color,
      ),
      SoulseekTransferState.idle => (
        Icons.circle_outlined,
        colors.textTertiary as Color,
      ),
    };

    return Icon(icon, color: color, size: 22);
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.colors,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final dynamic colors;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 20,
            color: destructive
                ? Colors.redAccent
                : colors.textSecondary as Color,
          ),
        ),
      ),
    );
  }
}
