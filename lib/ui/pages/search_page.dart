import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../main.dart' show AppColors;
import '../../sources/source_registry.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/artwork.dart';
import '../widgets/mini_player.dart';

/// Экран поиска: открывается с главной по тапу на поисковую таблетку.
/// Тап на трек = play; long-press = bottom sheet «Add to playlist».
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Автофокус через post-frame, чтобы анимация перехода не глитчила.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchProvider);
    final player = ref.read(playerServiceProvider);
    final searchCtl = ref.read(searchProvider.notifier);
    final sources = SourceRegistry.instance.all;
    final currentSourceId = searchCtl.sourceId;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                _TopBar(
                  controller: _controller,
                  focus: _focus,
                  loading: state.loading,
                  onSubmit: (q) => searchCtl.search(q),
                  onClear: () {
                    _controller.clear();
                    searchCtl.search('');
                  },
                ),
                // Чипы переключения источников.
                SizedBox(
                  height: 44,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    itemCount: sources.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final s = sources[i];
                      final selected = s.id == currentSourceId;
                      return ChoiceChip(
                        label: Text(s.displayName),
                        selected: selected,
                        labelStyle: TextStyle(
                          color: selected
                              ? Colors.black
                              : AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        backgroundColor: AppColors.elevated,
                        selectedColor: AppColors.textPrimary,
                        side: BorderSide.none,
                        showCheckmark: false,
                        onSelected: (_) => searchCtl.setSourceId(s.id),
                      );
                    },
                  ),
                ),
                if (state.error != null)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      state.error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                Expanded(
                  child: state.results.isEmpty && !state.loading
                      ? const Center(
                          child: Text(
                            'Type to search...',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        )
                      // Стрим текущего MediaItem нужен, чтобы
                      // подсветить трек, который сейчас играет.
                      // Сравниваем по globalId — он же лежит в
                      // MediaItem.id (см. PlayerService._toMediaItem).
                      : StreamBuilder<MediaItem?>(
                          stream: player.mediaItem,
                          builder: (context, mediaSnap) {
                            final currentId = mediaSnap.data?.id;
                            return ListView.builder(
                              itemCount: state.results.length,
                              cacheExtent: 200,
                              padding: const EdgeInsets.fromLTRB(8, 8, 8, 120),
                              itemBuilder: (context, i) {
                                final t = state.results[i];
                                final isPlaying =
                                    currentId != null &&
                                    currentId == t.globalId;
                                return _TrackTile(
                                  track: t,
                                  isPlaying: isPlaying,
                                  player: player,
                                  duration: t.duration != null
                                      ? _formatDuration(t.duration!)
                                      : null,
                                  onTap: () => player.setQueue(
                                    state.results,
                                    startIndex: i,
                                  ),
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(top: false, child: MiniPlayer()),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Один элемент поисковой выдачи. Выделен в отдельный виджет ради:
/// 1. подсветки текущего проигрываемого трека (фон + цветной title +
///    маленький play-индикатор слева от обложки),
/// 2. локализации rebuild'ов: при изменении mediaItem ВСЕ tile'ы
///    перерисовываются всё равно из StreamBuilder, но виджет здесь
///    более структурирован и удобен для дальнейших правок.
class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.track,
    required this.isPlaying,
    required this.player,
    required this.onTap,
    this.duration,
  });

  final dynamic track;
  final bool isPlaying;
  final dynamic player;
  final VoidCallback onTap;
  final String? duration;

  @override
  Widget build(BuildContext context) {
    final accent = isPlaying
        ? const Color(0xFF6EE7B7) // мягкий мятный — отличается от текста
        : AppColors.textPrimary;

    return Container(
      // Фоновое выделение трека, который играет: едва заметная плашка,
      // чтобы пользователь сразу понимал «это я слушаю».
      decoration: isPlaying
          ? BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Stack(
          alignment: Alignment.center,
          children: [
            Artwork(url: track.artworkUrl, size: 48, borderRadius: 8),
            if (isPlaying)
              // Кружок-индикатор поверх обложки: показывает, что трек
              // активен. Не запускаем здесь анимацию (волны/эквалайзер)
              // — статичная иконка не отвлекает от скролла.
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.equalizer_rounded, color: accent, size: 22),
              ),
          ],
        ),
        title: Text(
          track.title as String,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: accent,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          track.artist as String,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
        trailing: duration != null
            ? Text(
                duration!,
                style: const TextStyle(color: AppColors.textSecondary),
              )
            : null,
        onTap: onTap,
        onLongPress: () => showAddToPlaylistSheet(context, track),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.controller,
    required this.focus,
    required this.loading,
    required this.onSubmit,
    required this.onClear,
  });
  final TextEditingController controller;
  final FocusNode focus;
  final bool loading;
  final ValueChanged<String> onSubmit;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded, size: 28),
            color: AppColors.textPrimary,
            // popUntil(first) — если в стеке между home и search
            // случайно оказалась player_page (например, после быстрого
            // тапа), back из поиска возвращает строго на home.
            onPressed: () => Navigator.of(context)
                .popUntil((route) => route.isFirst),
          ),
          Expanded(
            child: Container(
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.elevated,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 14),
                  const Icon(
                    Icons.search_rounded,
                    color: AppColors.textSecondary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focus,
                      textInputAction: TextInputAction.search,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                      ),
                      decoration: const InputDecoration(
                        hintText: 'Search',
                        hintStyle: TextStyle(
                          color: AppColors.textSecondary,
                        ),
                        border: InputBorder.none,
                        isCollapsed: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                      onSubmitted: onSubmit,
                    ),
                  ),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (controller.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppColors.textSecondary,
                        size: 20,
                      ),
                      onPressed: onClear,
                    )
                  else
                    const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
