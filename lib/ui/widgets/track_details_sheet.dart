import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/track.dart';
import '../../sources/source_registry.dart';
import 'artwork.dart';
import '../desktop/desktop_layout.dart';

Future<void> showTrackDetailsSheet(BuildContext context, Track track) {
  return showDesktopModalSheet<void>(
    context: context,
    maxWidth: 520,
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

  /// QUALITY-01: fallback-метка качества («FLAC 24/96», «MP3 320») —
  /// показывается вместо «unavailable», когда точный битрейт неизвестен
  /// (типично для lossless: C# bridge не всегда даёт BitRate-атрибут).
  String? _qualityLabel;

  @override
  void initState() {
    super.initState();
    _qualityLabel = _labelFromTrack(widget.track);
    _loadBitrate();
  }

  /// Метка из трека: явный qualityLabel либо построенный из extra
  /// (extension/bitrate/sampleRate/bitDepth).
  String? _labelFromTrack(Track t) {
    final label = t.qualityLabel;
    if (label != null && label.isNotEmpty) return label;

    // extra мог принести атрибуты без готовой метки (кэш-треки) —
    // строим «FLAC 24/96»-подобную строку из компонентов.
    final ext = t.extra['extension'] as String?;
    if (ext == null || ext.isEmpty) return null;
    int? bitrate;
    if (t.extra['bitrate'] is int && t.extra['bitrate'] as int > 0) {
      bitrate = t.extra['bitrate'] as int;
    }
    final bitDepth = t.extra['bitDepth'] as int?;
    final sampleRate = t.extra['sampleRate'] as int?;

    if (bitrate == null && bitDepth == null && sampleRate == null) {
      return ext.toUpperCase();
    }
    if (bitDepth != null && sampleRate != null) {
      final khz = sampleRate >= 1000
          ? (sampleRate % 1000 == 0
              ? '${sampleRate ~/ 1000}'
              : (sampleRate / 1000).toStringAsFixed(1))
          : '$sampleRate';
      return '${ext.toUpperCase()} $bitDepth/$khz';
    }
    if (bitDepth != null) return '${ext.toUpperCase()} ${bitDepth}bit';
    return '${ext.toUpperCase()} $bitrate';
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
                    trackId: t.id,
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
              // QUALITY-01: при недоступном точном битрейте показываем
              // метку качества («FLAC 24/96») вместо «unavailable».
              _BitrateRow(
                loading: _loading,
                bitrate: _bitrate,
                qualityLabel: _qualityLabel,
                colors: colors,
              ),
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
  const _DetailRow({
    required this.label,
    required this.value,
    required this.colors,
  });
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
            style: TextStyle(color: colors.textSecondary, fontSize: 14),
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
  const _BitrateRow({
    required this.loading,
    required this.bitrate,
    this.qualityLabel,
    required this.colors,
  });
  final bool loading;
  final int? bitrate;
  final String? qualityLabel;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    Widget trailing;
    if (loading) {
      trailing = SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: colors.textPrimary,
        ),
      );
    } else if ((bitrate == null || bitrate! <= 0) &&
        (qualityLabel == null || qualityLabel!.isEmpty)) {
      trailing = Text(
        'unavailable',
        style: TextStyle(
          color: colors.textTertiary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      );
    } else if (bitrate != null && bitrate! > 0) {
      trailing = Text(
        '$bitrate kbps',
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      );
    } else {
      trailing = Text(
        qualityLabel!,
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
