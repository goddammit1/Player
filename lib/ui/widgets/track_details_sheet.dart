import 'package:flutter/material.dart';

import '../../main.dart' show AppColors;
import '../../models/track.dart';
import '../../sources/source_registry.dart';
import 'artwork.dart';

/// Bottom sheet «Детали трека».
///
/// Показывает обложку, название, исполнителя, источник, длительность и
/// битрейт аудио. Битрейт резолвится лениво (он НЕ запрашивается при
/// поиске, чтобы не тормозить выдачу): при открытии шита вызывается
/// [TrackSource.resolveBitrate] — для YouTube это запрос манифеста
/// (несколько секунд), для Muzmo — Range-GET к mp3. Пока идёт загрузка,
/// показываем индикатор.
Future<void> showTrackDetailsSheet(BuildContext context, Track track) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _TrackDetailsSheet(track: track),
  );
}

class _TrackDetailsSheet extends StatefulWidget {
  const _TrackDetailsSheet({required this.track});
  final Track track;

  @override
  State<_TrackDetailsSheet> createState() => _TrackDetailsSheetState();
}

class _TrackDetailsSheetState extends State<_TrackDetailsSheet> {
  /// null — ещё грузим; -1 — не удалось определить; иначе — kbps.
  int? _bitrate;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadBitrate();
  }

  Future<void> _loadBitrate() async {
    // Если битрейт уже известен из трека — берём его сразу.
    if (widget.track.qualityScore != null) {
      setState(() {
        _bitrate = widget.track.qualityScore;
        _loading = false;
      });
      return;
    }

    int? kbps;
    try {
      final source = SourceRegistry.instance.get(widget.track.sourceId);
      kbps = await source?.resolveBitrate(widget.track);
    } catch (_) {
      kbps = null;
    }
    if (!mounted) return;
    setState(() {
      _bitrate = kbps ?? -1;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    final sourceName =
        SourceRegistry.instance.get(t.sourceId)?.displayName ?? t.sourceId;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Шапка: обложка + название/исполнитель.
            Row(
              children: [
                Artwork(
                  url: t.artworkUrl,
                  size: 64,
                  borderRadius: 12,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        t.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        t.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(color: AppColors.outline, height: 1),
            const SizedBox(height: 8),

            _DetailRow(label: 'Источник', value: sourceName),
            _DetailRow(
              label: 'Длительность',
              value: t.duration != null ? _fmt(t.duration!) : '—',
            ),
            _BitrateRow(loading: _loading, bitrate: _bitrate),
          ],
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(h > 0 ? 2 : 1, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Отдельная строка для битрейта: пока грузится — крутилка, потом
/// значение либо «недоступно».
class _BitrateRow extends StatelessWidget {
  const _BitrateRow({required this.loading, required this.bitrate});
  final bool loading;
  final int? bitrate;

  @override
  Widget build(BuildContext context) {
    Widget trailing;
    if (loading) {
      trailing = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (bitrate == null || bitrate! <= 0) {
      trailing = const Text(
        'недоступно',
        style: TextStyle(
          color: AppColors.textTertiary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      );
    } else {
      trailing = Text(
        '$bitrate kbps',
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const Text(
            'Битрейт',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
          ),
          const Spacer(),
          trailing,
        ],
      ),
    );
  }
}
