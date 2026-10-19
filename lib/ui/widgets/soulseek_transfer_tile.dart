// lib/ui/widgets/soulseek_transfer_tile.dart
//
// Плитка загрузки Soulseek на странице Downloads. Внешне — как карточка
// кэшированного трека под ней (обложка 56, название 16/w600, строка
// статуса), чтобы идущая загрузка после завершения «перетекала» в список
// без смены стиля. Формат файла — в строке статуса (справа место занимают
// кнопки, иначе название обрезается). Управление: кольцо прогресса с
// паузой/продолжением, отмена, повтор для упавших/отменённых. Цвета —
// только из AppColors; красный — лишь «Failed».

import 'package:flutter/material.dart';

import '../../core/providers.dart';
import '../../sources/soulseek_artwork_query.dart';
import '../../sources/soulseek_models.dart';
import 'artwork.dart';
import 'byte_format.dart';
import 'grouped_tiles.dart';

class SoulseekTransferTile extends StatelessWidget {
  const SoulseekTransferTile({
    super.key,
    required this.transfer,
    required this.colors,
    required this.isFirst,
    required this.isLast,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onRetry,
  });

  static const double _artSize = 56;
  static const double _rowHeight = 64;

  final SoulseekTransferInfo transfer;
  final AppColors colors;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final title = soulseekTransferTitle(t);
    final dimmed = t.state == SoulseekTransferState.cancelled;

    // Обложку ищем тем же очищенным запросом, что и у кэшированных треков:
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
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        height: _rowHeight,
        decoration: BoxDecoration(
          color: colors.elevated,
          borderRadius: groupedTileRadius(isFirst, isLast),
        ),
        padding: const EdgeInsets.only(right: 4),
        child: Row(
          children: [
            Expanded(
              child: Opacity(
                opacity: dimmed ? 0.55 : 1,
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Artwork(
                          // id Soulseek-трека — его cacheKey (downloadId =
                          // dl_<cacheKey>): та же своя обложка и тот же кэш
                          // поиска, что у трека после загрузки.
                          trackId: t.downloadId.replaceFirst('dl_', ''),
                          url: null,
                          artist: query.artist.isEmpty ? null : query.artist,
                          title: query.title,
                          size: _artSize,
                          borderRadius: 0,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
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
                          const SizedBox(height: 2),
                          Text.rich(
                            _statusLine(t),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 13,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 2),
            ..._controls(t),
          ],
        ),
      ),
    );
  }

  /// Строка под названием: формат · исполнитель · прогресс/статус.
  /// Скорость — суммой в заголовке группы.
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

    final format = _format(t);
    if (format != null) {
      parts.add(TextSpan(
        text: format,
        style: TextStyle(
          color: colors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ));
    }
    final artist = t.artist;
    if (artist != null && artist.isNotEmpty) add(artist);

    switch (t.state) {
      case SoulseekTransferState.downloading:
      case SoulseekTransferState.prebuffered:
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
            dimension: 48,
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
            size: 22,
          ),
        ];
      case SoulseekTransferState.idle:
        return const [SizedBox(width: 48)];
    }
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

/// Название загрузки: title, иначе имя файла у пира без расширения.
/// [SoulseekTransferInfo.localPath] и downloadId — хэши, поэтому только
/// крайний фолбэк.
String soulseekTransferTitle(SoulseekTransferInfo t) {
  final title = t.title;
  if (title != null && title.isNotEmpty) return title;
  final remote = t.remoteFilename;
  if (remote != null && remote.isNotEmpty) {
    final name = _basename(remote);
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
  final local = t.localPath;
  if (local != null && local.isNotEmpty) return _basename(local);
  return t.downloadId;
}

String _basename(String path) {
  final i = path.lastIndexOf('/');
  final j = path.lastIndexOf('\\');
  final idx = i > j ? i : j;
  if (idx >= 0 && idx < path.length - 1) return path.substring(idx + 1);
  return path;
}

// ═══════════════════════════════════════════════════════════════════════
//  Small widgets
// ═══════════════════════════════════════════════════════════════════════

/// Кольцо прогресса с иконкой действия внутри. Без [onTap] — только
/// индикатор.
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
      dimension: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.square(
            dimension: 30,
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
            dimension: 48,
            child: Icon(icon, size: size, color: colors.textSecondary),
          ),
        ),
      ),
    );
  }
}
