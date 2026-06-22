import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/track.dart';
import '../../sources/source_registry.dart';
import 'artwork.dart';

Future<void> showTrackDetailsSheet(BuildContext context, Track track) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    builder: (sheetCtx) => _TrackDetailsSheet(track: track),
  );
}

class _TrackDetailsSheet extends ConsumerStatefulWidget {
  const _TrackDetailsSheet({required this.track});
  final Track track;

  @override
  ConsumerState<_TrackDetailsSheet> createState() => _TrackDetailsSheetState();
}

class _TrackDetailsSheetState extends ConsumerState<_TrackDetailsSheet> {
  int? _bitrate;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadBitrate();
  }

  Future<void> _loadBitrate() async {
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
    final colors = ref.watch(animatedPaletteProvider);
    final t = widget.track;
    final sourceName =
        SourceRegistry.instance.get(t.sourceId)?.displayName ?? t.sourceId;

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: colors.elevated,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 16),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.elevatedHi,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
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
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textSecondary,
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
              Divider(color: colors.outline, height: 1),
              const SizedBox(height: 8),

              _DetailRow(label: 'Source', value: sourceName, colors: colors),
              _DetailRow(
                label: 'Duration',
                value: t.duration != null ? _fmt(t.duration!) : '—',
                colors: colors,
              ),
              _BitrateRow(loading: _loading, bitrate: _bitrate, colors: colors),
            ],
          ),
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
  const _DetailRow({required this.label, required this.value, required this.colors});
  final String label;
  final String value;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 14,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _BitrateRow extends StatelessWidget {
  const _BitrateRow({required this.loading, required this.bitrate, required this.colors});
  final bool loading;
  final int? bitrate;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    Widget trailing;
    if (loading) {
      trailing = SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: colors.textPrimary),
      );
    } else if (bitrate == null || bitrate! <= 0) {
      trailing = Text(
        'unavailable',
        style: TextStyle(
          color: colors.textTertiary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      );
    } else {
      trailing = Text(
        '$bitrate kbps',
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Text(
            'Bitrate',
            style: TextStyle(color: colors.textSecondary, fontSize: 14),
          ),
          const Spacer(),
          trailing,
        ],
      ),
    );
  }
}