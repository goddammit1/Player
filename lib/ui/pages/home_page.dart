import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/playlist_backup.dart';
import '../../core/providers.dart';
import '../../models/playlist.dart';
import '../widgets/artwork.dart';
import '../widgets/now_playing_overlay.dart';

import 'history_page.dart';
import 'playlist_page.dart';
import 'search_history_page.dart';
import 'settings_page.dart';

/// Главный экран: топ-бар, заголовок «Playlists», сетка плейлистов
/// 2-в-ряд (последняя ячейка — «Add new»). Мини-плеер прикреплён
/// поверх контента через `Stack` — это позволяет ему «парить» над
/// нижней частью списка и иметь скруглённые углы по дизайну.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(playlistsProvider);
    final playlists = async.value ?? const <Playlist>[];
    final colors = ref.watch(animatedPaletteProvider);

    return _HomePageAnimator(
      child: Scaffold(
        backgroundColor: colors.background,
        body: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  const SliverToBoxAdapter(child: _TopBar()),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                      child: Text(
                        'Playlists',
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 32,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: 0.82,
                      ),
                      itemCount: playlists.length + 1,
                      itemBuilder: (context, i) {
                        if (i == playlists.length) return const _AddNewCard();
                        final p = playlists[i];
                        return _PlaylistCard(playlist: p, colors: colors);
                      },
                    ),
                  ),
                ],
              ),
            ),
            const NowPlayingOverlay(),
          ],
        ),
      ),
    );
  }
}

/// Отдельный StatefulWidget для анимации — не трогает HomePage
class _HomePageAnimator extends StatefulWidget {
  const _HomePageAnimator({required this.child});
  final Widget child;

  @override
  State<_HomePageAnimator> createState() => _HomePageAnimatorState();
}

class _HomePageAnimatorState extends State<_HomePageAnimator>
    with SingleTickerProviderStateMixin {

  late final AnimationController _anim;
  late final Animation<double> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slide = Tween<double>(begin: 10, end: 0).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic),
    );
    _fade = Tween<double>(begin: 0.7, end: 1).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOut),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _anim.forward();
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) => Transform.translate(
        offset: Offset(0, _slide.value),
        child: Opacity(
          opacity: _fade.value,
          child: widget.child,
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        children: [
          _CircleButton(
            icon: Icons.history_rounded,
            // Та же системная анимация перехода, что и у Settings,
            // но отражённая по горизонтали — страница прилетает слева
            // (кнопка истории в левом углу).
            onTap: () => Navigator.of(context).push(
              _MirroredPageRoute(builder: (_) => const HistoryPage()),
            ),
            colors: colors,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _SearchPill(
              colors: colors,
              onTap: () {
                Navigator.of(context).push(
                  PageRouteBuilder(
                    pageBuilder: (context, animation, secondaryAnimation) =>
                        const SearchHistoryPage(),
                    transitionsBuilder:
                        (context, animation, secondaryAnimation, child) {
                      return child;
                    },
                    transitionDuration: Duration.zero,
                    reverseTransitionDuration: Duration.zero,
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 10),
          _CircleButton(
            icon: Icons.settings_rounded,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
            colors: colors,
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    required this.colors,
  });
  final IconData icon;
  final VoidCallback onTap;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.elevated,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 60,
          height: 60,
          child: Icon(icon, color: colors.textPrimary, size: 20),
        ),
      ),
    );
  }
}

class _SearchPill extends StatelessWidget {
  const _SearchPill({required this.colors, required this.onTap});
  final AppColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.elevated,
      borderRadius: BorderRadius.circular(32),
      child: InkWell(
        borderRadius: BorderRadius.circular(32),
        onTap: onTap,
        child: SizedBox(
          height: 60,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Text(
                  'Search',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({required this.playlist, required this.colors});
  final Playlist playlist;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlaylistPage(playlistId: playlist.id),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: LayoutBuilder(
              builder: (_, c) => Stack(
                children: [
                  Positioned.fill(
                    child: ArtworkMosaic(
                      urls: playlist.coverThumbnails,
                      size: c.maxWidth,
                      borderRadius: 20,
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: _CountBadge(count: playlist.tracks.length, colors: colors),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.colors});
  final int count;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        // Полупрозрачный тёмный круг — поверх любой обложки читается.
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AddNewCard extends ConsumerWidget {
  const _AddNewCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _showAddOptions(context, ref),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                color: colors.elevated,
                borderRadius: BorderRadius.circular(18),
              ),
              alignment: Alignment.center,
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: colors.textPrimary,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.add_rounded,
                  color: Colors.black,
                  size: 32,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add new',
            textAlign: TextAlign.center,
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

  /// Показывает выбор: создать пустой плейлист или импортировать из файла.
  Future<void> _showAddOptions(BuildContext context, WidgetRef ref) async {
    final colors = ref.read(currentPaletteProvider);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.elevated,
      showDragHandle: true,
      builder: (sheetCtx) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  Icons.add_rounded,
                  color: colors.textPrimary,
                ),
                title: Text(
                  'Create empty playlist',
                  style: TextStyle(color: colors.textPrimary),
                ),
                onTap: () async {
                  Navigator.of(sheetCtx).pop();
                  await _showCreateDialog(context, ref);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.file_download_outlined,
                  color: colors.textPrimary,
                ),
                title: Text(
                  'Import from file',
                  style: TextStyle(color: colors.textPrimary),
                ),
                onTap: () async {
                  Navigator.of(sheetCtx).pop();
                  await _importPlaylist(context, ref);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _importPlaylist(BuildContext context, WidgetRef ref) async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: false,
      );
    } catch (e) {
      if (!context.mounted) return;
      _showInfo(context, ref, title: 'Import failed', body: e.toString());
      return;
    }

    final path = picked?.files.single.path;
    if (path == null) return; // отмена

    if (!context.mounted) return;
    final strategy = await _askImportStrategy(context, ref);
    if (strategy == null) return; // отмена

    try {
      final result = await PlaylistBackup.importFromFile(
        path,
        strategy: strategy,
      );
      if (!context.mounted) return;
      _showInfo(
        context, ref,
        title: 'Import complete',
        body: 'Added: ${result.added}\nReplaced: ${result.replaced}\nSkipped: ${result.skipped}',
      );
    } catch (e) {
      if (!context.mounted) return;
      _showInfo(
        context, ref,
        title: 'Import failed',
        body: e is FormatException ? e.message : e.toString(),
      );
    }
  }

  /// Спрашивает, что делать с плейлистами, у которых `id` уже есть.
  Future<ImportStrategy?> _askImportStrategy(BuildContext context, WidgetRef ref) {
    final colors = ref.read(currentPaletteProvider);

    return showDialog<ImportStrategy>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: colors.elevated,
          title: Text(
            'Import playlist',
            style: TextStyle(color: colors.textPrimary),
          ),
          content: Text(
            'If a playlist already exists, what should happen?',
            style: TextStyle(color: colors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(ImportStrategy.keepBoth),
              child: const Text('Keep both'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(ImportStrategy.skip),
              child: const Text('Skip existing'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(ImportStrategy.replace),
              child: const Text('Replace'),
            ),
          ],
        );
      },
    );
  }

  void _showInfo(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String body,
  }) {
    final colors = ref.read(currentPaletteProvider);

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: colors.elevated,
          title: Text(
            title,
            style: TextStyle(color: colors.textPrimary),
          ),
          content: Text(
            body,
            style: TextStyle(color: colors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showCreateDialog(BuildContext context, WidgetRef ref) async {
    final colors = ref.read(currentPaletteProvider);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: colors.elevated,
          title: Text(
            'New playlist',
            style: TextStyle(color: colors.textPrimary),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: TextStyle(color: colors.textPrimary),
            decoration: InputDecoration(
              hintText: 'Name',
              hintStyle: TextStyle(color: colors.textTertiary),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    if (name == null) return;
    final p = ref.read(playlistRepositoryProvider).create(name);
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlaylistPage(playlistId: p.id)),
    );
  }
}

/// Маршрут со стандартной системной анимацией перехода (ровно такой же,
/// как у Settings через MaterialPageRoute), но отражённой по горизонтали,
/// чтобы страница прилетала слева, а не справа. Дважды применяем
/// горизонтальный flip: внешний отражает геометрию перехода
/// (right-slide → left-slide), внутренний возвращает контент в норму,
/// чтобы текст и иконки не были зеркальными.
class _MirroredPageRoute<T> extends MaterialPageRoute<T> {
  _MirroredPageRoute({required super.builder});

  static final Matrix4 _flipX = Matrix4.diagonal3Values(-1, 1, 1);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final mirroredChild = Transform(
      alignment: Alignment.center,
      transform: _flipX,
      child: child,
    );
    return Transform(
      alignment: Alignment.center,
      transform: _flipX,
      child: super.buildTransitions(
        context,
        animation,
        secondaryAnimation,
        mirroredChild,
      ),
    );
  }
}
