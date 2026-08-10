import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/playlist_backup.dart';
import '../../core/providers.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../sources/source_registry.dart';
import '../widgets/artwork.dart';
import '../../core/artwork_helper.dart';
import '../widgets/now_playing_overlay.dart';
import '../widgets/track_settings_sheet.dart';
import 'settings_page.dart';
import '../../core/haptic_helper.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════

abstract final class _Dimens {
  const _Dimens._();

  static const double appBarHeight = 88;
  static const double buttonHeight = 60;
  static const double circleButtonSize = 60;
  static const double menuButtonSize = 60;
  static const double searchHeight = 60;
  static const double artworkSize = 188;
  static const double trackArtwork = 56;
  static const double trackRowHeight = 64;

  static const double radiusL = 24;
  static const double radiusM = 15;
  static const double radiusXS = 5;
  static const double radiusArtwork = 12;
}

// ═══════════════════════════════════════════════════════════════════════════
//  HELPERS
// ═══════════════════════════════════════════════════════════════════════════

BorderRadius _trackBorderRadius(bool isFirst, bool isLast) => BorderRadius.only(
      topLeft: Radius.circular(isFirst ? _Dimens.radiusM : _Dimens.radiusXS),
      topRight: Radius.circular(isFirst ? _Dimens.radiusM : _Dimens.radiusXS),
      bottomLeft: Radius.circular(isLast ? _Dimens.radiusM : _Dimens.radiusXS),
      bottomRight: Radius.circular(isLast ? _Dimens.radiusM : _Dimens.radiusXS),
    );

String _fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  final mStr = m.toString().padLeft(2, '0');
  final sStr = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:$mStr:$sStr';
  return '$mStr:$sStr';
}

String _fmt(Duration d) {
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

// ═══════════════════════════════════════════════════════════════════════════
//  PROVIDERS
// ═══════════════════════════════════════════════════════════════════════════

final _currentTrackIdProvider = StreamProvider<String?>((ref) {
  final player = ref.watch(playerServiceProvider);
  return player.mediaItem.map((item) => item?.id);
});

final _isPlayingProvider = StreamProvider<bool>((ref) {
  final player = ref.watch(playerServiceProvider);
  return player.playingStream;
});

// ═══════════════════════════════════════════════════════════════════════════
//  SORT MODE
// ═══════════════════════════════════════════════════════════════════════════

enum _SortMode {
  date('By date'),
  title('By title'),
  artist('By artist'),
  manual('Manual');

  final String label;
  const _SortMode(this.label);
}

// ═══════════════════════════════════════════════════════════════════════════
//  PLAYLIST PAGE
// ═══════════════════════════════════════════════════════════════════════════

class PlaylistPage extends ConsumerStatefulWidget {
  const PlaylistPage({super.key, required this.playlistId});
  final String playlistId;

  @override
  ConsumerState<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends ConsumerState<PlaylistPage> {
  final TextEditingController _searchCtl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _filterKey = GlobalKey();
  String _query = '';

  _SortMode _sortMode = _SortMode.date;
  bool _sortReversed = false;
  bool _isMenuOpen = false;
  bool _isShuffling = false;

  @override
  void initState() {
    super.initState();
    _searchCtl.addListener(_onSearchChanged);
  }

  void _onSearchChanged() {
    final q = _searchCtl.text;
    if (q != _query) setState(() => _query = q);
  }

  @override
  void dispose() {
    _searchCtl.removeListener(_onSearchChanged);
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _scrollToFilters() async {
    // 1. Захватываем контекст ДО асинхронной паузы
    final targetContext = _filterKey.currentContext;
    if (targetContext == null) return;

    await Future.delayed(const Duration(milliseconds: 90));

    // 2. Проверяем и текущий State, и сам целевой контекст
    if (!mounted) return;
    if (!targetContext.mounted) return;

    Scrollable.ensureVisible(
      targetContext,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }
  // ---- Фильтрация и сортировка ----

  List<Track> _filterAndSort(List<Track> tracks) {
    var result = [...tracks];

    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      result = result.where((t) {
        return t.title.toLowerCase().contains(q) ||
            t.artist.toLowerCase().contains(q);
      }).toList();
    }

    switch (_sortMode) {
      case _SortMode.date:
      case _SortMode.manual:
        break;
      case _SortMode.title:
        result.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case _SortMode.artist:
        result.sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
        break;
    }

    if (_sortReversed) result = result.reversed.toList();
    return result;
  }

  static Duration _totalDuration(List<Track> tracks) => tracks.fold<Duration>(
        Duration.zero,
        (prev, t) => prev + (t.duration ?? Duration.zero),
      );

  // ---- BottomSheet меню плейлиста ----

  Future<void> _showPlaylistMenu(BuildContext context, Playlist p) async {
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
                leading: Icon(Icons.edit_rounded, color: colors.textPrimary),
                title: Text('Rename', style: TextStyle(color: colors.textPrimary)),
                onTap: () async {
                  HapticHelper.light(ref: ref);
                  Navigator.of(sheetCtx).pop();
                  await _askRename(context, p);
                },
              ),
              if (p.coverCustomPath != null)
                ListTile(
                  leading: Icon(Icons.remove_circle_outline_rounded, color: colors.textSecondary),
                  title: Text('Remove cover image', style: TextStyle(color: colors.textSecondary)),
                  onTap: () async {
                    HapticHelper.light(ref: ref);
                    Navigator.of(sheetCtx).pop();
                    await _removeCoverImage(context, p);
                  },
                ),
              ListTile(
                leading: Icon(Icons.add_photo_alternate_rounded, color: colors.textPrimary),
                title: Text('Set cover image', style: TextStyle(color: colors.textPrimary)),
                onTap: () async {
                  HapticHelper.light(ref: ref);
                  Navigator.of(sheetCtx).pop();
                  await _setCoverImage(context, p);
                },
              ),
              ListTile(
                leading: Icon(Icons.ios_share_rounded, color: colors.textPrimary),
                title: Text('Export playlist', style: TextStyle(color: colors.textPrimary)),
                onTap: () async {
                  HapticHelper.light(ref: ref);
                  Navigator.of(sheetCtx).pop();
                  await _exportPlaylist(context, p);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                title: const Text('Delete playlist', style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  HapticHelper.confirmDelete(ref: ref);
                  Navigator.of(sheetCtx).pop();
                  ref.read(playlistRepositoryProvider).delete(p.id);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _exportPlaylist(BuildContext context, Playlist p) async {
    try {
      await PlaylistBackup.exportAndShare([p]);
      HapticHelper.success(ref: ref);
    } catch (e) {
      if (!context.mounted) return;
      HapticHelper.error(ref: ref);
      _showInfo(context, title: 'Export failed', body: e.toString());
    }
  }

  void _showInfo(BuildContext context, {required String title, required String body}) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        actions: [
          TextButton(
            onPressed: () {
              HapticHelper.light(ref: ref);
              Navigator.of(ctx).pop();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _askRename(BuildContext context, Playlist p) async {
    final colors = ref.read(currentPaletteProvider);
    final controller = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.elevated,
        title: Text('Rename playlist', style: TextStyle(color: colors.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: colors.textPrimary),
          decoration: InputDecoration(
            hintText: 'Name',
            hintStyle: TextStyle(color: colors.textTertiary),
            border: InputBorder.none,
          ),
          onSubmitted: (v) {
            HapticHelper.success(ref: ref);
            Navigator.of(ctx).pop(v.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              HapticHelper.light(ref: ref);
              Navigator.of(ctx).pop();
            },
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              HapticHelper.success(ref: ref);
              Navigator.of(ctx).pop(controller.text.trim());
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      ref.read(playlistRepositoryProvider).rename(p.id, name);
    }
  }

  Future<void> _setCoverImage(BuildContext context, Playlist playlist) async {
    final path = await ArtworkHelper.pickCustomArtwork();
    if (path == null || !mounted) return;

    final repo = ref.read(playlistRepositoryProvider);
    repo.setCoverImage(playlist.id, path);
  }

  Future<void> _removeCoverImage(BuildContext context, Playlist playlist) async {
    final repo = ref.read(playlistRepositoryProvider);
    // Сначала удаляем файл с диска
    if (playlist.coverCustomUrl != null) {
      await ArtworkHelper.removePlaylistCover(playlist.coverCustomUrl!);
    }
    repo.removeCoverImage(playlist.id);
  }

  Future<void> _showReplacementSheet(
    BuildContext context,
    Playlist playlist,
    Track unavailableTrack,
  ) async {
    final query = '${unavailableTrack.artist} ${unavailableTrack.title}';
    final repo = ref.read(playlistRepositoryProvider);
    final player = ref.read(playerServiceProvider);
    final colors = ref.read(currentPaletteProvider);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.elevated,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollController) {
            return _ReplacementSheetBody(
              query: query,
              unavailableTrack: unavailableTrack,
              scrollController: scrollController,
              onReplace: (Track replacement) {
                HapticHelper.success(ref: ref);
                repo.replaceTrack(playlist.id, unavailableTrack.globalId, replacement);
                Navigator.of(sheetCtx).pop();
              },
              onPreview: (Track track) {
                HapticHelper.light(ref: ref);
                player.setQueue([track]);
              },
            );
          },
        );
      },
    );
  }

  // ---- Sort picker ----

  void _showSortPicker() {
    final colors = ref.read(currentPaletteProvider);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.elevated,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(_Dimens.radiusM)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Text(
                    'Sort by',
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ..._SortMode.values.map((mode) {
                  final isSelected = _sortMode == mode;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    leading: isSelected
                        ? Icon(Icons.check_rounded, color: colors.accent, size: 22)
                        : const SizedBox(width: 22),
                    title: Text(
                      mode.label,
                      style: TextStyle(
                        color: isSelected ? colors.accent : colors.textPrimary,
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 16,
                      ),
                    ),
                    onTap: () {
                      HapticHelper.light(ref: ref);
                      Navigator.of(ctx).pop();
                      setState(() => _sortMode = mode);
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  // ===================================================================
  //  BUILD
  // ===================================================================

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(playlistsProvider);
    final list = async.value ?? const <Playlist>[];
    final colors = ref.watch(animatedPaletteProvider);

    final playlist = list.cast<Playlist?>().firstWhere(
          (p) => p?.id == widget.playlistId,
          orElse: () => null,
        );

    if (playlist == null) {
      return _PageAnimator(
        child: Scaffold(
          backgroundColor: colors.background,
          appBar: AppBar(
            backgroundColor: colors.background,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            leading: _CircleButton(
              icon: Icons.chevron_left_rounded,
              onTap: () {
                HapticHelper.light(ref: ref);
                Navigator.of(context).pop();
              },
              colors: colors,
            ),
          ),
          body: Center(
            child: Text('Playlist deleted', style: TextStyle(color: colors.textSecondary)),
          ),
        ),
      );
    }

    final p = playlist;
    final player = ref.watch(playerServiceProvider);

    // Сначала фильтруем и сортируем (чтобы порядок совпадал с экраном)
    final displayedTracks = _filterAndSort(p.tracks);
    
    // Получаем ТОЛЬКО доступные треки ИЗ ОТОБРАЖАЕМОГО (отсортированного) списка
    final playableDisplayedTracks = displayedTracks
        .where((t) => !SourceRegistry.instance.isDisabled(t.sourceId))
        .toList();

    final totalDur = _totalDuration(p.tracks);
    
    final isPlaying = ref.watch(_isPlayingProvider.select((a) => a.valueOrNull ?? false));
    final currentId = ref.watch(_currentTrackIdProvider.select((a) => a.valueOrNull));

    // Проверяем, играет ли этот плейлист сейчас
    final isThisPlaylist = currentId != null &&
        p.tracks.any((t) => t.globalId == currentId);
    final showPause = isPlaying && isThisPlaylist;

    return _PageAnimator(
      child: Scaffold(
        backgroundColor: colors.background,
        body: Stack(
          children: [
            CustomScrollView(
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              slivers: [
                // ── Top Bar ──
                SliverAppBar(
                  pinned: true,
                  floating: false,
                  snap: false,
                  backgroundColor: colors.background,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  toolbarHeight: _Dimens.appBarHeight,
                  automaticallyImplyLeading: false,
                  titleSpacing: 0,
                  title: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    child: Row(
                      children: [
                        _CircleButton(
                          icon: Icons.chevron_left_rounded,
                          onTap: () {
                            HapticHelper.light(ref: ref);
                            Navigator.of(context).pop();
                          },
                          colors: colors,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _SearchPill(
                            colors: colors,
                            controller: _searchCtl,
                            focusNode: _searchFocus,
                            hint: 'In playlist?',
                            onTap: () {
                              HapticHelper.light(ref: ref);
                              _scrollToFilters(); // ВЫЗЫВАЕМ ПРОКРУТКУ
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        _CircleButton(
                          icon: Icons.settings_rounded,
                          onTap: () {
                            HapticHelper.light(ref: ref);
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const SettingsPage()),
                            );
                          },
                          colors: colors,
                        ),
                      ],
                    ),
                  ),
                ),

                // ── Artwork ──
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Center(
                      child: Container(
                        width: _Dimens.artworkSize,
                        height: _Dimens.artworkSize,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(_Dimens.radiusL),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x40000000),
                              blurRadius: 24,
                              offset: Offset(0, 0),
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(_Dimens.radiusL),
                          child: ArtworkMosaic(
                            urls: p.coverThumbnails,
                            trackIds: p.coverTrackIds,
                            size: _Dimens.artworkSize,
                            borderRadius: 0,
                            coverCustomUrl: p.coverCustomPath,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // ── Playlist Name ──
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 24, left: 16, right: 16),
                    child: Text(
                      p.name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),

                // ── Track count · Duration ──
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${p.tracks.length} song${p.tracks.length == 1 ? '' : 's'}',
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '·',
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _fmtDuration(totalDur),
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── Play / Shuffle / Menu buttons ──
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
                    child: SizedBox(
                      height: _Dimens.buttonHeight, // 60px
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Play / Pause Button
                          Expanded(
                            child: _AnimatedActionButton(
                              onTap: playableDisplayedTracks.isEmpty
                                  ? null
                                  : () {
                                      HapticHelper.medium(ref: ref);
                                      if (showPause) {
                                        player.pause();
                                      } else {
                                        player.setQueue(playableDisplayedTracks);
                                      }
                                    },
                              backgroundColor: colors.elevatedHi,
                              radiusBuilder: (isPressed) => (showPause || isPressed)
                                  ? BorderRadius.circular(30)
                                  : const BorderRadius.horizontal(
                                      left: Radius.circular(30),
                                      right: Radius.circular(5),
                                    ),
                              builder: (isPressed) => Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    showPause ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                    color: colors.textPrimary,
                                    size: 26,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    showPause ? 'Pause' : 'Play',
                                    style: TextStyle(
                                      color: colors.textPrimary,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 16,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // Shuffle Button
                          Expanded(
                            child: _AnimatedActionButton(
                              onTap: playableDisplayedTracks.isEmpty
                                  ? null
                                  : () {
                                      HapticHelper.medium(ref: ref);
                                      final shuffled = [...playableDisplayedTracks]..shuffle();
                                      player.setQueue(shuffled);
                                      
                                      setState(() => _isShuffling = true);
                                      Future.delayed(const Duration(milliseconds: 400), () {
                                        if (mounted) setState(() => _isShuffling = false);
                                      });
                                    },
                              backgroundColor: colors.elevated,
                              radiusBuilder: (isPressed) => (isPressed || _isShuffling)
                                  ? BorderRadius.circular(30)
                                  : BorderRadius.circular(5),
                              builder: (isPressed) => Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.shuffle_rounded,
                                    color: colors.textPrimary,
                                    size: 22,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Shuffle',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 16,
                                      color: colors.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // Menu Button
                          SizedBox(
                            width: _Dimens.menuButtonSize,
                            child: _AnimatedActionButton(
                              onTap: () async {
                                HapticHelper.light(ref: ref);
                                
                                setState(() => _isMenuOpen = true);
                                await _showPlaylistMenu(context, p);
                                if (mounted) setState(() => _isMenuOpen = false);
                              },
                              backgroundColor: colors.elevated,
                              radiusBuilder: (isPressed) => (isPressed || _isMenuOpen)
                                  ? BorderRadius.circular(30)
                                  : const BorderRadius.horizontal(
                                      left: Radius.circular(5),
                                      right: Radius.circular(30),
                                    ),
                              builder: (isPressed) {
                                // Если кнопка скруглена полностью - убираем смещение
                                final isRounded = isPressed || _isMenuOpen;
                                
                                return AnimatedPadding(
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeOutCubic,
                                  padding: isRounded 
                                      ? EdgeInsets.zero 
                                      : const EdgeInsets.only(right: 6), // Двигаем иконку чуть левее для баланса плоской стороны
                                  child: Center(
                                    child: Icon(
                                      Icons.more_vert_rounded,
                                      color: colors.textPrimary,
                                      size: 24,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // ── Filter / Sort bar ──
                SliverToBoxAdapter(
                  child: Padding(
                    key: _filterKey,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 95,
                          height: 48,
                          child: Material(
                            color: colors.elevatedHi,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(24),
                              bottomLeft: Radius.circular(24),
                              topRight: Radius.circular(5),
                              bottomRight: Radius.circular(5),
                            ),
                            child: InkWell(
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(24),
                                bottomLeft: Radius.circular(24),
                                topRight: Radius.circular(5),
                                bottomRight: Radius.circular(5),
                              ),
                              onTap: () {
                                HapticHelper.light(ref: ref);
                                _showSortPicker();
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      _sortMode.label,
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
                        ),
                        const SizedBox(width: 4),
                        SizedBox(
                          width: 48,
                          height: 48,
                          child: Material(
                            color: colors.elevatedHi,
                            borderRadius: _sortReversed 
                                ? BorderRadius.circular(24)
                                : const BorderRadius.only(
                                    topLeft: Radius.circular(5),
                                    bottomLeft: Radius.circular(5),
                                    topRight: Radius.circular(24),
                                    bottomRight: Radius.circular(24),
                                  ),
                            child: InkWell(
                              borderRadius: _sortReversed 
                                  ? BorderRadius.circular(24)
                                  : const BorderRadius.only(
                                      topLeft: Radius.circular(5),
                                      bottomLeft: Radius.circular(5),
                                      topRight: Radius.circular(24),
                                      bottomRight: Radius.circular(24),
                                    ),
                              onTap: () {
                                HapticHelper.light(ref: ref);
                                setState(() => _sortReversed = !_sortReversed);
                              },
                              child: AnimatedPadding(
                                duration: const Duration(milliseconds: 200),
                                padding: _sortReversed 
                                    ? const EdgeInsets.all(0)
                                    : const EdgeInsets.only(right: 4),
                                child: Center(
                                  child: AnimatedRotation(
                                    turns: _sortReversed ? 0.5 : 0,
                                    duration: const Duration(milliseconds: 200),
                                    child: Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      color: colors.textPrimary,
                                      size: 24,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                      ],
                    ),
                  ),
                ),

                // ── Track list or empty state ──
                if (displayedTracks.isEmpty && _query.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 48),
                      child: Center(
                        child: Text(
                          'Nothing found',
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  )
                else if (p.tracks.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 48),
                      child: Center(
                        child: Text(
                          'No tracks yet.\nFind some via Search 🔍',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.textSecondary,
                            height: 1.5,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
                    sliver: SliverList.builder(
                      itemCount: displayedTracks.length,
                      itemBuilder: (context, i) {
                        final t = displayedTracks[i];
                        return _TrackTile(
                          key: ValueKey(t.globalId),
                          track: t,
                          playlist: p,
                          playableDisplayedTracks: playableDisplayedTracks,
                          isFirst: i == 0,
                          isLast: i == displayedTracks.length - 1,
                          onReplaceTap: () {
                            HapticHelper.light(ref: ref);
                            _showReplacementSheet(context, p, t);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
            const NowPlayingOverlay(),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ANIMATED ACTION BUTTON (PLAY / SHUFFLE / MENU)
// ═══════════════════════════════════════════════════════════════════════════

class _AnimatedActionButton extends StatefulWidget {
  const _AnimatedActionButton({
    required this.builder, // Заменили child на builder
    this.onTap,
    required this.radiusBuilder,
    required this.backgroundColor,
  });

  // Теперь виджет перестраивается в зависимости от состояния нажатия
  final Widget Function(bool isPressed) builder; 
  final VoidCallback? onTap;
  final BorderRadius Function(bool isPressed) radiusBuilder;
  final Color backgroundColor;

  @override
  State<_AnimatedActionButton> createState() => _AnimatedActionButtonState();
}

class _AnimatedActionButtonState extends State<_AnimatedActionButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final radius = widget.radiusBuilder(_isPressed);
    final isDisabled = widget.onTap == null;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: widget.backgroundColor.withValues(alpha: isDisabled ? 0.5 : 1.0),
        borderRadius: radius,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onHighlightChanged: (val) {
            if (!isDisabled) setState(() => _isPressed = val);
          },
          onTap: widget.onTap,
          child: widget.builder(_isPressed), // Передаем состояние внутрь
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  TRACK TILE
// ═══════════════════════════════════════════════════════════════════════════

class _TrackTile extends ConsumerWidget {
  const _TrackTile({
    super.key,
    required this.track,
    required this.playlist,
    required this.playableDisplayedTracks,
    required this.isFirst,
    required this.isLast,
    required this.onReplaceTap,
  });

  final Track track;
  final Playlist playlist;
  final List<Track> playableDisplayedTracks;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onReplaceTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);
    final repo = ref.watch(playlistRepositoryProvider);
    final player = ref.watch(playerServiceProvider);

    final isDisabled = SourceRegistry.instance.isDisabled(track.sourceId);
    final borderRadius = _trackBorderRadius(isFirst, isLast);
    final isCurrentTrack = ref.watch(
      _currentTrackIdProvider.select((id) => id.valueOrNull == track.globalId),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Dismissible(
        key: ValueKey(track.globalId),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.2),
            borderRadius: borderRadius,
          ),
          child: const Icon(
            Icons.delete_outline_rounded,
            color: Colors.redAccent,
          ),
        ),
        onDismissed: (_) {
          HapticHelper.confirmDelete(ref: ref);
          repo.removeTrack(playlist.id, track.globalId);
        },
        child: InkWell(
          onTap: isDisabled
              ? onReplaceTap
              : () {
                  HapticHelper.light(ref: ref);
                  final idx = playableDisplayedTracks.indexWhere(
                      (pt) => pt.globalId == track.globalId);
                  player.setQueue(
                    playableDisplayedTracks,
                    startIndex: idx >= 0 ? idx : 0,
                  );
                },
          onLongPress: () {
            HapticHelper.medium(ref: ref);
            showTrackSettingsSheet(context, track: track);
          },
          borderRadius: borderRadius,
          child: Container(
            decoration: BoxDecoration(
              color: isCurrentTrack
                  ? colors.elevatedHi.withValues(alpha: 0.5)
                  : colors.elevated,
              borderRadius: borderRadius,
            ),
            child: SizedBox(
              height: _Dimens.trackRowHeight,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: _TrackArtwork(
                      track: track,
                      isDisabled: isDisabled,
                      isCurrentTrack: isCurrentTrack,
                      colors: colors,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isDisabled
                                ? colors.textSecondary
                                : colors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isDisabled
                              ? '${track.artist} · YouTube unavailable'
                              : track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isDisabled
                                ? Colors.orange
                                : colors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (isDisabled)
                    IconButton(
                      icon: const Icon(
                        Icons.find_replace_rounded,
                        color: Colors.orange,
                        size: 22,
                      ),
                      tooltip: 'Find replacement',
                      onPressed: onReplaceTap,
                    )
                  else if (track.duration != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(
                        _fmt(track.duration!),
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 12,
                          fontFeatures: const [
                            FontFeature.tabularFigures()
                          ],
                        ),
                      ),
                    )
                  else
                    const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  CIRCLE BUTTON
// ═══════════════════════════════════════════════════════════════════════════

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
          width: _Dimens.circleButtonSize,
          height: _Dimens.circleButtonSize,
          child: Center(
            child: Icon(icon, color: colors.textPrimary, size: 20),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  SEARCH PILL
// ═══════════════════════════════════════════════════════════════════════════

class _SearchPill extends StatelessWidget {
  const _SearchPill({
    required this.colors,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onTap,
  });

  final AppColors colors;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.elevated,
      borderRadius: BorderRadius.circular(32),
      child: InkWell(
        borderRadius: BorderRadius.circular(32),
        onTap: () {
          // Срабатывает, если тапнуть по краям (padding) кнопки
          onTap();
          focusNode.requestFocus();
        },
        child: SizedBox(
          height: _Dimens.searchHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onTap: onTap,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      hintText: hint,
                      hintStyle: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isCollapsed: true,
                    ),
                    cursorColor: colors.accent,
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

// ═══════════════════════════════════════════════════════════════════════════
//  TRACK ARTWORK
// ═══════════════════════════════════════════════════════════════════════════

class _TrackArtwork extends StatelessWidget {
  const _TrackArtwork({
    required this.track,
    required this.isDisabled,
    required this.isCurrentTrack,
    required this.colors,
  });

  final Track track;
  final bool isDisabled;
  final bool isCurrentTrack;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _Dimens.trackArtwork,
      height: _Dimens.trackArtwork,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(_Dimens.radiusArtwork),
            child: Opacity(
              opacity: isDisabled ? 0.4 : 1.0,
              child: Artwork(
                trackId: track.id,
                url: track.artworkUrl,
                size: _Dimens.trackArtwork,
                borderRadius: 0,
                aspectRatio: artAspectRatio(track),
              ),
            ),
          ),
          if (isCurrentTrack)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(_Dimens.radiusArtwork),
                ),
                alignment: Alignment.center,
                child: RepaintBoundary(
                  child: _WaveBars(color: colors.elevatedHi),
                ),
              ),
            ),
          if (isDisabled)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: Colors.orange,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.warning_rounded, size: 12, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ANIMATED WAVE BARS
// ═══════════════════════════════════════════════════════════════════════════

class _WaveBars extends StatefulWidget {
  const _WaveBars({required this.color});
  final Color color;

  @override
  State<_WaveBars> createState() => _WaveBarsState();
}

class _WaveBarsState extends State<_WaveBars> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  static const _barCount = 5;
  static const _barWidth = 3.0;
  static const _barGap = 2.0;
  static const _maxHeight = 20.0;
  static const _minHeight = 4.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(_barCount, (i) {
            final phase = (i / _barCount) * 2 * math.pi;
            final wave = math.sin(t * 2 * math.pi + phase) * 0.5 +
                         math.sin(t * 4 * math.pi + phase * 1.5) * 0.3;
            final height = _minHeight +
                (_maxHeight - _minHeight) *
                ((wave + 0.8) / 1.6).clamp(0.0, 1.0);

            return Container(
              width: _barWidth,
              height: height,
              margin: EdgeInsets.only(right: i < _barCount - 1 ? _barGap : 0),
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(_barWidth / 2),
              ),
            );
          }),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  PAGE ANIMATOR
// ═══════════════════════════════════════════════════════════════════════════

class _PageAnimator extends StatefulWidget {
  const _PageAnimator({required this.child});
  final Widget child;

  @override
  State<_PageAnimator> createState() => _PageAnimatorState();
}

class _PageAnimatorState extends State<_PageAnimator> with SingleTickerProviderStateMixin {
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
    _anim.forward();
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

// ═══════════════════════════════════════════════════════════════════════════
//  REPLACEMENT SHEET BODY
// ═══════════════════════════════════════════════════════════════════════════

class _ReplacementSheetBody extends ConsumerStatefulWidget {
  const _ReplacementSheetBody({
    required this.query,
    required this.unavailableTrack,
    required this.scrollController,
    required this.onReplace,
    required this.onPreview,
  });

  final String query;
  final Track unavailableTrack;
  final ScrollController scrollController;
  final ValueChanged<Track> onReplace;
  final ValueChanged<Track> onPreview;

  @override
  ConsumerState<_ReplacementSheetBody> createState() => _ReplacementSheetBodyState();
}

class _ReplacementSheetBodyState extends ConsumerState<_ReplacementSheetBody> {
  List<Track> _results = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final sources = SourceRegistry.instance.searchable;
      final lists = await Future.wait(
        sources.map((s) async {
          try {
            return await s.search(widget.query, limit: 10);
          } catch (_) {
            return <Track>[];
          }
        }),
      );

      final merged = <Track>[];
      var i = 0;
      var added = true;
      while (added) {
        added = false;
        for (final list in lists) {
          if (i < list.length) {
            merged.add(list[i]);
            added = true;
          }
        }
        i++;
      }

      if (mounted) {
        setState(() {
          _results = merged;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Text(
            'Replace "${widget.unavailableTrack.title}"',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text(
            'Tap to preview · Long press to replace',
            style: TextStyle(color: colors.textSecondary, fontSize: 12),
          ),
        ),
        if (_loading)
          const Expanded(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Search failed: $_error',
                  style: const TextStyle(color: Colors.redAccent),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          )
        else if (_results.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                'No results found',
                style: TextStyle(color: colors.textSecondary),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              controller: widget.scrollController,
              itemCount: _results.length,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
              itemBuilder: (context, i) {
                final t = _results[i];
                return ListTile(
                  leading: Artwork(
                    url: t.artworkUrl,
                    size: 44,
                    borderRadius: 8,
                    aspectRatio: artAspectRatio(t),
                  ),
                  title: Text(
                    t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  subtitle: Text(
                    '${t.artist} · ${t.sourceId}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.textSecondary, fontSize: 11),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.swap_horiz_rounded, color: Colors.green),
                    tooltip: 'Use this track',
                    onPressed: () => widget.onReplace(t),
                  ),
                  onTap: () => widget.onPreview(t),
                );
              },
            ),
          ),
      ],
    );
  }
}