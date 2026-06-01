import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../sources/source_registry.dart';
import '../widgets/mini_player.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
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
      appBar: AppBar(
        title: const Text('Player'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(108),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Переключатель источников: YouTube / Muzmo / ...
              SizedBox(
                height: 40,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: sources.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final s = sources[i];
                    final selected = s.id == currentSourceId;
                    return ChoiceChip(
                      label: Text(s.displayName),
                      selected: selected,
                      onSelected: (_) => searchCtl.setSourceId(s.id),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Поиск треков...',
                    filled: true,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: state.loading
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _controller.clear();
                              ref.read(searchProvider.notifier).search('');
                            },
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (q) =>
                      ref.read(searchProvider.notifier).search(q),
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          if (state.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Colors.red.withValues(alpha: 0.1),
              child: Text(
                state.error!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          Expanded(
            child: state.results.isEmpty && !state.loading
                ? const Center(child: Text('Введите запрос для поиска'))
                : ListView.builder(
                    itemCount: state.results.length,
                    // Чуть меньше дефолтного (~250), чтобы не держать в
                    // дереве лишние CachedNetworkImage за пределами
                    // видимой области.
                    cacheExtent: 200,
                    itemBuilder: (context, i) {
                      final t = state.results[i];
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: t.artworkUrl != null
                              ? CachedNetworkImage(
                                  imageUrl: t.artworkUrl!,
                                  width: 48,
                                  height: 48,
                                  fit: BoxFit.cover,
                                  // Декодим картинку в памяти как 96x96
                                  // (× device pixel ratio Flutter добавит
                                  // сам). Исходный PNG с Genius может
                                  // быть 600x600 и весить под мегабайт —
                                  // декодировать его полным размером для
                                  // 48×48 виджета = впустую жечь CPU и
                                  // ~5 МБ RAM на КАЖДУЮ обложку.
                                  memCacheWidth: 96,
                                  memCacheHeight: 96,
                                  fadeInDuration: const Duration(
                                    milliseconds: 120,
                                  ),
                                  errorWidget: (context, url, error) =>
                                      const _ArtworkPlaceholder(),
                                )
                              : const _ArtworkPlaceholder(),
                        ),
                        title: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: t.duration != null
                            ? Text(_formatDuration(t.duration!))
                            : null,
                        onTap: () {
                          player.setQueue(state.results, startIndex: i);
                        },
                      );
                    },
                  ),
          ),
          const MiniPlayer(),
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

class _ArtworkPlaceholder extends StatelessWidget {
  const _ArtworkPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      color: Colors.grey.shade300,
      child: const Icon(Icons.music_note, color: Colors.white),
    );
  }
}
