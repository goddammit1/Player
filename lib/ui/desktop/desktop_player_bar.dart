// lib/ui/desktop/desktop_player_bar.dart
//
// Десктопная панель плеера (Windows/Linux/macOS): обложка, название,
// прогресс с перемоткой, цикл и управление воспроизведением.
// В отличие от мобильного NowPlayingOverlay это статичная панель внизу
// окна (классическая схема), а не разворачиваемый оверлей.
//
// Задел на доработку: сюда легко добавить кнопки «в очередь», «детали
// трека», буст громкости и т.п. — см. PlayerServiceInterface.

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../../core/player_service_interface.dart';
import '../../core/providers.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/artwork.dart';

/// Нижняя панель плеера в [DesktopShell].
///
/// Три блока (как в ТЗ):
///  1. Информация о треке (обложка, название, исполнитель + метаданные
///     «источник • качество» из extras MediaItem).
///  2. Управление воспроизведением (в очередь, shuffle, prev, play, next,
///     repeat) + прогресс с перемоткой.
///  3. Регулятор громкости.
class DesktopPlayerBar extends ConsumerWidget {
  const DesktopPlayerBar({super.key});

  /// Фиксированная высота панели. Используется shell'ом для раскладки.
  static const double height = 88;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerServiceProvider);
    final colors = ref.watch(animatedPaletteProvider);

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colors.elevated,
        border: Border(top: BorderSide(color: colors.outline)),
      ),
      child: StreamBuilder<MediaItem?>(
        stream: player.mediaItem,
        builder: (context, snap) {
          final item = snap.data;
          if (item == null) {
            return Center(
              child: Text(
                'No track',
                style: TextStyle(color: colors.textTertiary, fontSize: 13),
              ),
            );
          }

          return Row(
            children: [
              const SizedBox(width: 20),
              // ===== Блок 1: информация о треке =====
              SizedBox(
                width: 260,
                child: _TrackInfo(item: item, colors: colors),
              ),
              const SizedBox(width: 16),
              // ===== Блок 2: управление + прогресс =====
              Expanded(
                child: _Controls(player: player, colors: colors),
              ),
              const SizedBox(width: 16),
              // ===== Блок 3: громкость =====
              SizedBox(
                width: 200,
                child: _VolumeSlider(player: player, colors: colors),
              ),
              const SizedBox(width: 20),
            ],
          );
        },
      ),
    );
  }
}

/// Блок информации о треке с метаданными «источник • качество».
class _TrackInfo extends StatelessWidget {
  const _TrackInfo({required this.item, required this.colors});

  final MediaItem item;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final sourceId = (item.extras?['sourceId'] as String?)?.toUpperCase();
    final quality = (item.extras?['qualityLabel'] as String?)
        ?.toUpperCase();
    final meta = [if (sourceId != null && sourceId.isNotEmpty) sourceId,
      if (quality != null && quality.isNotEmpty) quality]
        .join(' • ');

    return Row(
      children: [
        Artwork(
          url: item.artUri?.toString(),
          size: 56,
          borderRadius: 8,
          trackId: (item.extras?['trackId'] as String?) ?? item.id,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item.artist ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textTertiary, fontSize: 10),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Блок управления: кнопки (в очередь, shuffle, prev, play, next, repeat)
/// над прогрессом с перемоткой.
class _Controls extends StatelessWidget {
  const _Controls({required this.player, required this.colors});

  final PlayerServiceInterface player;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    // Панель живёт ВЫШЕ Navigator'а (в MaterialApp.builder) — для открытия
    // шторки используем корневой navigator через [rootNavigatorKey].
    final navCtx = rootNavigatorKey.currentContext;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _SmallButton(
              icon: Icons.queue_music_rounded,
              tooltip: 'Add to queue',
              color: colors.textSecondary,
              onTap: () {
                final list = player.trackQueue;
                final idx = player.currentIndex;
                if (navCtx != null && idx >= 0 && idx < list.length) {
                  showAddToPlaylistSheet(navCtx, list[idx]);
                }
              },
            ),
            _SmallButton(
              icon: Icons.shuffle_rounded,
              tooltip: 'Shuffle',
              color: colors.textSecondary,
              onTap: player.shuffleQueue,
            ),
            _SmallButton(
              icon: Icons.skip_previous_rounded,
              tooltip: 'Previous',
              color: colors.textPrimary,
              onTap: player.skipToPrevious,
            ),
            _PlayPauseButton(player: player, colors: colors),
            _SmallButton(
              icon: Icons.skip_next_rounded,
              tooltip: 'Next',
              color: colors.textPrimary,
              onTap: player.skipToNext,
            ),
            _LoopButton(player: player, colors: colors),
          ],
        ),
        _SeekSlider(player: player, colors: colors),
      ],
    );
  }
}

/// Небольшая иконка-кнопка для блока управления.
class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String? tooltip;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasOverlay = Overlay.maybeOf(context) != null;
    return IconButton(
      tooltip: hasOverlay ? tooltip : null,
      iconSize: 24,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, color: color),
      onPressed: onTap,
    );
  }
}

/// Регулятор громкости: иконка + ползунок 0..1.
class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({required this.player, required this.colors});

  final PlayerServiceInterface player;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.volume_down_rounded,
          size: 18,
          color: colors.textSecondary,
        ),
        Expanded(
          child: StreamBuilder<double>(
            stream: player.volumeStream,
            builder: (context, snap) {
              final v = (snap.data ?? 1.0).clamp(0.0, 1.0);
              return SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                  activeTrackColor: colors.textPrimary,
                  inactiveTrackColor: colors.outline,
                  thumbColor: colors.textPrimary,
                  overlayColor: colors.textPrimary.withValues(alpha: 0.15),
                ),
                child: SizedBox(
                  // Slider по умолчанию занимает 48px высоты; в компактной
                  // панели это выталкивает Column за пределы (flex overflow).
                  height: 24,
                  child: Slider(
                    key: const Key('volume_slider'),
                    value: v,
                    onChanged: (val) => player.setVolume(val),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Слайдер перемотки: во время drag показывает локальную позицию и
/// применяет seek только на отпускании — как в десктопных плеерах.
class _SeekSlider extends StatefulWidget {
  const _SeekSlider({required this.player, required this.colors});

  final PlayerServiceInterface player;
  final AppColors colors;

  @override
  State<_SeekSlider> createState() => _SeekSliderState();
}

class _SeekSliderState extends State<_SeekSlider> {
  Duration? _dragValue;

  /// Позиция прореживается раз в 100 мс. Поток создаётся ОДИН раз в
  /// initState — создание в build'е заставляло StreamBuilder переподписываться
  /// на каждой пересборке и терять последнее значение.
  late final Stream<Duration> _positionThrottled;

  StreamSubscription<MediaItem?>? _itemSub;

  @override
  void initState() {
    super.initState();
    _positionThrottled = widget.player.positionStream
        .throttleTime(const Duration(milliseconds: 100));
    // Сбрасываем «локальную» позицию при смене трека: иначе после
    // автоперехода слайдер какое-то время показывает позицию старого трека
    // (его длительность), а не начало нового.
    _itemSub = widget.player.mediaItem.listen((_) {
      if (_dragValue != null && mounted) {
        setState(() => _dragValue = null);
      }
    });
  }

  @override
  void dispose() {
    _itemSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: _positionThrottled,
      builder: (context, posSnap) {
        return StreamBuilder<Duration?>(
          stream: widget.player.durationStream,
          builder: (context, durSnap) {
            final pos = _dragValue ?? posSnap.data ?? Duration.zero;
            // durationStream может не отдать длительность (частый случай на
            // Windows для стримов/локальных файлов). Фолбэк — длительность
            // из MediaItem, который сервис заполняет из Track.duration.
            final dur =
                durSnap.data ??
                widget.player.mediaItemValue?.duration ??
                Duration.zero;
            final known = dur > Duration.zero;
            final maxMs = known
                ? dur.inMilliseconds.toDouble().clamp(1.0, double.infinity)
                : 1.0;
            final valueMs = known
                ? pos.inMilliseconds.toDouble().clamp(0.0, maxMs)
                : 0.0;

            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    activeTrackColor: widget.colors.textPrimary,
                    inactiveTrackColor: widget.colors.outline,
                    // Явные «отключённые» цвета: по умолчанию M3 для disabled
                    // слайдера рисует полосу на всю ширину (onSurface 12%),
                    // что на тёмной теме выглядит как «залитый» трек — ровно
                    // та жалоба, что была на Windows при неизвестной
                    // длительности стрима.
                    disabledActiveTrackColor: widget.colors.elevatedHi,
                    disabledInactiveTrackColor: widget.colors.elevatedHi,
                    disabledThumbColor: widget.colors.elevatedVariant,
                    thumbColor: widget.colors.textPrimary,
                    overlayColor: widget.colors.textPrimary.withValues(
                      alpha: 0.15,
                    ),
                  ),
                  child: SizedBox(
                    // Компактный слайдер (см. _VolumeSlider).
                    height: 24,
                    child: Slider(
                      key: const Key('seek_slider'),
                      value: valueMs,
                      max: maxMs,
                      // При неизвестной длительности слайдер неактивен и не
                      // рисует ложную заливку на всю ширину.
                      onChanged: known
                          ? (v) => setState(
                                () => _dragValue =
                                    Duration(milliseconds: v.round()),
                              )
                          : null,
                      onChangeStart: known
                          ? (v) => setState(
                                () => _dragValue =
                                    Duration(milliseconds: v.round()),
                              )
                          : null,
                      onChangeEnd: known
                          ? (v) {
                              widget.player.seek(
                                Duration(milliseconds: v.round()),
                              );
                              setState(() => _dragValue = null);
                            }
                          : null,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        // Неизвестная длительность: честное «--:--», а не
                        // вводящее в заблуждение «00:00 / 00:00».
                        _fmt(known ? pos : null),
                        style: TextStyle(
                          color: widget.colors.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                      Text(
                        _fmt(known ? dur : null),
                        style: TextStyle(
                          color: widget.colors.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}


String _fmt(Duration? d) {
  if (d == null) return '--:--';
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Play/Pause с индикатором буферизации.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.player, required this.colors});

  final PlayerServiceInterface player;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: player.playbackState,
      builder: (context, snap) {
        final st = snap.data;
        final loading =
            st != null &&
            (st.processingState == AudioProcessingState.loading ||
                st.processingState == AudioProcessingState.buffering);
        if (loading) {
          return Padding(
            padding: const EdgeInsets.all(13),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.textPrimary,
              ),
            ),
          );
        }
        // Иконка и клик опираются на playingStream (Dart-состояние just_audio),
        // а не на PlaybackState. На Windows нативные команды системного
        // медиа-бара (SMTC) меняют playing через data-события, которые не
        // проходят через playbackEventStream, — PlaybackState мог бы застрять
        // в устаревшем значении и кнопка показывала бы «инверсию».
        return StreamBuilder<bool>(
          stream: player.playingStream,
          builder: (context, playingSnap) {
            final playing = playingSnap.data ?? st?.playing ?? false;
            return IconButton(
              iconSize: 28,
              padding: const EdgeInsets.all(6),
              visualDensity: VisualDensity.compact,
              icon: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: colors.textPrimary,
              ),
              onPressed: () => playing ? player.pause() : player.play(),
            );
          },
        );
      },
    );
  }
}

/// Кнопка цикла: off → all → one.
class _LoopButton extends StatelessWidget {
  const _LoopButton({required this.player, required this.colors});

  final PlayerServiceInterface player;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<LoopMode>(
      stream: player.loopModeStream,
      builder: (context, snap) {
        final mode = snap.data ?? LoopMode.off;
        final active = mode != LoopMode.off;
        // Панель живёт в MaterialApp.builder — ВЫШЕ Navigator'а, где нет
        // Overlay. Tooltip под капотом использует OverlayPortal и без
        // Overlay-предка кидает «No Overlay widget found» на каждой
        // пересборке (видно в логах). Показываем тултип только если
        // Overlay реально есть.
        final hasOverlay = Overlay.maybeOf(context) != null;
        return IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: hasOverlay
              ? (mode == LoopMode.off
                    ? 'Loop: off'
                    : mode == LoopMode.all
                    ? 'Loop: all'
                    : 'Loop: one')
              : null,
          icon: Icon(
            mode == LoopMode.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            color: active ? colors.accent : colors.textSecondary,
          ),
          onPressed: player.cycleLoopMode,
        );
      },
    );
  }
}


