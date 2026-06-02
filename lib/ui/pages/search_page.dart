import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../main.dart' show AppColors;
import '../../sources/source_registry.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/artwork.dart';
import '../widgets/now_playing_overlay.dart';


/// Экран поиска: открывается с главной по тапу на поисковую таблетку.
///
/// Дизайн (строгий тёмный список / минимализм):
/// - сверху — крупная строка поиска (скруглённый прямоугольник): стрелка
///   «назад» слева, текстовое поле по центру, крестик «очистить» справа;
/// - под ней — горизонтальный ряд pill-фильтров (иконка + текст). Активный
///   выделен светлым фоном, неактивные — тёмно-серым;
/// - основная часть — вертикальный список треков: квадратная миниатюра,
///   двухстрочный текстовый блок (белый заголовок + серый подзаголовок),
///   длительность справа;
/// - снизу поверх списка закреплён мини-плеер (NowPlayingOverlay).
///
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
    // Берём активный источник из СТЕЙТА (а не из приватного поля), чтобы
    // чип переключался сразу по watch — даже при пустом запросе.
    final currentSourceId = state.sourceId;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                _SearchBar(
                  controller: _controller,
                  focus: _focus,
                  loading: state.loading,
                  onSubmit: (q) => searchCtl.search(q),
                  onClear: () {
                    _controller.clear();
                    searchCtl.search('');
                    setState(() {});
                  },
                  onChanged: (_) => setState(() {}),
                ),
                // Pill-фильтры переключения источников.
                _FilterChips(
                  sources: sources,
                  currentSourceId: currentSourceId,
                  onSelected: searchCtl.setSourceId,
                ),
                if (state.error != null)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      state.error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                Expanded(
                  child: state.results.isEmpty && !state.loading
                      ? const _EmptyState()
                      // Стрим текущего MediaItem нужен, чтобы подсветить
                      // трек, который сейчас играет. Сравниваем по
                      // globalId — он же лежит в MediaItem.id.
                      : StreamBuilder<MediaItem?>(
                          stream: player.mediaItem,
                          builder: (context, mediaSnap) {
                            final currentId = mediaSnap.data?.id;
                            return ListView.builder(
                              itemCount: state.results.length,
                              cacheExtent: 200,
                              // Верхний отступ подобран так, чтобы зазор от
                              // фильтров до ВЕРХНЕЙ ГРАНИЦЫ обложки первого
                              // трека был 16: 16 - margin(3) - padding(8) = 5.
                              padding:
                                  const EdgeInsets.fromLTRB(12, 5, 12, 132),
                              itemBuilder: (context, i) {
                                final t = state.results[i];
                                final isPlaying = currentId != null &&
                                    currentId == t.globalId;
                                return _TrackTile(
                                  track: t,
                                  isPlaying: isPlaying,
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
          const NowPlayingOverlay(),
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

/// Заглушка пустого состояния: строгая, приглушённый серый.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_rounded,
            color: AppColors.textTertiary,
            size: 48,
          ),
          SizedBox(height: 12),
          Text(
            'Начните вводить запрос',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

/// Горизонтальный ряд pill-фильтров (иконка + текст источника).
class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.sources,
    required this.currentSourceId,
    required this.onSelected,
  });

  final List<dynamic> sources;
  final String currentSourceId;
  final ValueChanged<String> onSelected;

  // Сопоставление машинного id источника с иконкой. TrackSource не несёт
  // иконку, поэтому решаем это здесь — централизованно и без правок API.
  static IconData _iconFor(String id) {
    switch (id) {
      case kAllSourcesId:
        return Icons.public_rounded;
      case 'youtube':
        return Icons.play_circle_fill_rounded;
      case 'muzmo':
        return Icons.music_note_rounded;
      default:
        return Icons.library_music_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Первый чип — виртуальный «All» (поиск во всех источниках сразу),
    // далее — реальные источники из реестра.
    final entries = <({String id, String label})>[
      (id: kAllSourcesId, label: 'Все'),
      for (final s in sources)
        (id: s.id as String, label: s.displayName as String),
    ];

    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (context, i) {
          final e = entries[i];
          final selected = e.id == currentSourceId;
          return _FilterPill(
            icon: _iconFor(e.id),
            label: e.label,
            selected: selected,
            onTap: () => onSelected(e.id),
          );
        },
      ),
    );
  }
}


/// Одна кнопка-таблетка фильтра. Активная — светлый фон + тёмные иконка
/// и текст; неактивная — тёмно-серый фон + светлый текст.
class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.black : AppColors.textPrimary;
    return Material(
      color: selected ? AppColors.textPrimary : AppColors.elevated,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Один элемент поисковой выдачи: квадратная обложка, двухстрочный текст,
/// длительность справа. Текущий проигрываемый трек подсвечивается фоном,
/// акцентным title и иконкой-эквалайзером поверх обложки.
class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.track,
    required this.isPlaying,
    required this.onTap,
    this.duration,
  });

  final dynamic track;
  final bool isPlaying;
  final VoidCallback onTap;
  final String? duration;

  @override
  Widget build(BuildContext context) {
    final accent = isPlaying
        ? const Color(0xFF6EE7B7) // мягкий мятный — отличается от текста
        : AppColors.textPrimary;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: isPlaying ? AppColors.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: () => showAddToPlaylistSheet(context, track),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                // Квадратная миниатюра со скруглёнными краями.
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Artwork(
                      url: track.artworkUrl,
                      size: 54,
                      borderRadius: 10,
                    ),
                    if (isPlaying)
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.equalizer_rounded,
                          color: accent,
                          size: 22,
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                // Текстовый блок: заголовок + подзаголовок.
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        track.title as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        track.artist as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w500,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                // Длительность трека — мелким белым шрифтом справа.
                if (duration != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    duration!,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Верхняя строка поиска: стрелка «назад», текстовое поле, крестик/спиннер.
/// Крупный прямоугольник с сильно скруглёнными углами и фоном светлее
/// основного.
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focus,
    required this.loading,
    required this.onSubmit,
    required this.onClear,
    required this.onChanged,
  });
  final TextEditingController controller;
  final FocusNode focus;
  final bool loading;
  final ValueChanged<String> onSubmit;
  final VoidCallback onClear;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          color: AppColors.elevated,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            // Слева: иконка «Назад».
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 24),
              color: AppColors.textPrimary,
              // popUntil(first) — если в стеке между home и search случайно
              // оказалась player_page, back из поиска вернёт строго на home.
              onPressed: () => Navigator.of(context)
                  .popUntil((route) => route.isFirst),
            ),
            // По центру: текстовое поле с поисковым запросом.
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focus,
                textInputAction: TextInputAction.search,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                ),
                decoration: const InputDecoration(
                  hintText: 'Поиск',
                  hintStyle: TextStyle(color: AppColors.textSecondary),
                  border: InputBorder.none,
                  isCollapsed: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                ),
                onChanged: onChanged,
                onSubmitted: onSubmit,
              ),
            ),
            // Справа: спиннер при загрузке, иначе крестик очистки.
            if (loading)
              const Padding(
                padding: EdgeInsets.only(right: 16),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (controller.text.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 22),
                color: AppColors.textPrimary,
                onPressed: onClear,
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}
