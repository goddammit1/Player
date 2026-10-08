import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cached_tracks_service.dart';
import '../../core/repositories/history_repository.dart';
import '../../core/providers.dart';
import '../../core/repositories/playlist_repository.dart';
import '../../core/soulseek_settings_repository.dart';
import '../../core/youtube_cache.dart';
import '../../sources/artwork_provider.dart';
import '../../sources/soulseek_platform_channel.dart';
import '../desktop/desktop_layout.dart';
import '../widgets/byte_format.dart';
import 'cached_tracks_page.dart';

/// Страница управления кэшем.
///
/// - Audio cache: общий для всех источников — стриминговый кэш
///   (muzmo/SoundCloud, легаси YouTube) и Soulseek (только Android).
///   Размер и очистка — суммарные, лимиты у хранилищ раздельные
///   (у каждого своя LRU-эвикция). Список треков — [CachedTracksPage].
/// - Artwork cache: обложки (CachedNetworkImage хранит сам, мы лишь
///   ограничиваем его размер через ImageCache + свой дисковый кэш)
class CachePage extends ConsumerStatefulWidget {
  const CachePage({super.key});

  @override
  ConsumerState<CachePage> createState() => _CachePageState();
}

class _CachePageState extends ConsumerState<CachePage> {
  // ===== Состояние =====
  CacheUsage? _audioUsage;
  int? _artworkSize;
  int? _artworkCount;

  late int _audioLimitMB;
  late int _artworkLimitMB;
  int _soulseekLimitMB = SoulseekSettingsRepository.defaultCacheLimitMB;

  // Опции лимита: 0 = unlimited
  static const List<int> _limitOptions = [100, 500, 1024, 5120, 0];
  static const List<String> _limitLabels = [
    '100 MB',
    '500 MB',
    '1 GB',
    '5 GB',
    'Unlimited',
  ];

  // Опции лимита Soulseek (перенесены из настроек Soulseek).
  static const List<int> _soulseekLimitOptions = [500, 1024, 2048, 5120, 0];
  static const List<String> _soulseekLimitLabels = [
    '500 MB',
    '1 GB',
    '2 GB',
    '5 GB',
    'Unlimited',
  ];

  /// Soulseek-кэш есть только на Android.
  bool get _hasSoulseek => SoulseekPlatformChannel.instance.isAvailable;

  CachedTracksService get _tracks => ref.read(cachedTracksServiceProvider);

  @override
  void initState() {
    super.initState();
    _audioLimitMB = YoutubeCache.maxAudioCacheMB;
    _artworkLimitMB = YoutubeCache.maxArtworkCacheMB;
    _loadSoulseekLimit();
    _refreshStats();
  }

  Future<void> _loadSoulseekLimit() async {
    if (!_hasSoulseek) return;
    try {
      final settings = await SoulseekSettingsRepository.instance.loadAll();
      if (mounted) setState(() => _soulseekLimitMB = settings.cacheLimitMB);
    } catch (_) {}
  }

  // ===== Статистика =====

  Future<void> _refreshStats() async {
    // Инициализирует пути кэша, если их ещё никто не трогал.
    final artworkDir = await YoutubeCache.instance.ensureArtworkDir();

    final cached = await _tracks.loadAll();
    final artworkStats = await _calcDirStats(artworkDir);

    if (mounted) {
      setState(() {
        _audioUsage = CacheUsage.of(cached);
        _artworkSize = artworkStats.$1;
        _artworkCount = artworkStats.$2;
      });
    }
  }

  Future<(int bytes, int count)> _calcDirStats(Directory? dir) async {
    if (dir == null) return (0, 0);
    int bytes = 0;
    int count = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          final stat = await entity.stat();
          bytes += stat.size;
          count++;
        }
      }
    } catch (_) {}
    return (bytes, count);
  }

  // ===== Форматирование =====

  double? _usagePercent(int? usedBytes, int limitMB) {
    if (usedBytes == null || limitMB == 0) return null;
    final limitBytes = limitMB * 1024 * 1024;
    return (usedBytes / limitBytes).clamp(0.0, 1.0);
  }

  String _sizeSummary(int? bytes, String? count) {
    final sizeStr = bytes != null ? formatBytes(bytes) : '...';
    return count == null ? sizeStr : '$sizeStr • $count';
  }

  // ===== Действия =====

  Future<void> _openCachedTracks() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CachedTracksPage()),
    );
    // Треки могли удалить/открепить в списке.
    if (mounted) await _refreshStats();
  }

  Future<void> _clearAudioCache() async {
    final confirmed = await _showConfirmDialog(
      title: 'Clear audio cache?',
      body: 'All cached tracks from every source, including Soulseek '
          'downloads, will be deleted. They will be re-downloaded on next play.',
    );
    if (confirmed != true) return;

    final error = await _guardClear(_tracks.clearAudio);
    await _refreshStats();

    if (mounted) _showSnack(error ?? 'Audio cache cleared');
  }

  Future<void> _clearArtworkCache() async {
    final confirmed = await _showConfirmDialog(
      title: 'Clear artwork cache?',
      body:
          'All cached artwork will be deleted. They will be re-downloaded on next view.',
    );
    if (confirmed != true) return;

    // Чистим Flutter ImageCache (RAM)
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    // Дисковый кэш CachedNetworkImage чистит YoutubeCache.
    await YoutubeCache.instance.clearArtworkCache();

    // Сбрасываем кэш НАЙДЕННЫХ URL обложек (in-memory + SQLite), чтобы
    // «очистка кэша обложек» действительно перезапросила Genius/iTunes
    // заново и подхватила самую свежую обложку на стороне провайдера.
    await ArtworkProvider.instance.clearCache();

    // Сбрасываем artworkUrl у треков в ПЛЕЙЛИСТАХ И ИСТОРИИ, чтобы они
    // перезапросили обложки через Genius/iTunes (фоновое обогащение
    // запускается самим сбросом).
    PlaylistRepository.instance.resetAllTrackArtworks();
    HistoryRepository.instance.resetAllTrackArtworks();

    await _refreshStats();
    if (mounted) _showSnack('Artwork cache cleared');
  }

  Future<void> _clearAllCache() async {
    final confirmed = await _showConfirmDialog(
      title: 'Clear all cache?',
      body:
          'All cached tracks and artwork will be deleted. This cannot be undone.',
    );
    if (confirmed != true) return;

    await YoutubeCache.instance.clearAllCache();
    final error = await _guardClear(_tracks.clearSoulseek);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    // Сбрасываем кэш найденных URL обложек + artworkUrl у треков
    // в плейлистах и истории (см. комментарий в _clearArtworkCache).
    await ArtworkProvider.instance.clearCache();
    PlaylistRepository.instance.resetAllTrackArtworks();
    HistoryRepository.instance.resetAllTrackArtworks();

    await _refreshStats();

    if (mounted) _showSnack(error ?? 'All cache cleared');
  }

  /// Выполняет очистку; возвращает текст ошибки для снэкбара или null.
  Future<String?> _guardClear(Future<Object?> Function() clear) async {
    try {
      await clear();
      return null;
    } on CacheActionException catch (e) {
      return e.message;
    } catch (_) {
      return 'Failed to clear audio cache';
    }
  }

  Future<bool?> _showConfirmDialog({
    required String title,
    required String body,
  }) {
    final colors = ref.read(animatedPaletteProvider);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.elevated,
        title: Text(title, style: TextStyle(color: colors.textPrimary)),
        content: Text(body, style: TextStyle(color: colors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Clear', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  void _showSnack(String msg) {
    final colors = ref.read(animatedPaletteProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: TextStyle(color: colors.textPrimary)),
        backgroundColor: colors.elevated,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ===== UI =====

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 132,                       // ← было 134
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.fromLTRB(16, 64, 16, 8), // ← было 16,16,16,8
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (Navigator.of(context).canPop())
                _CircleButton(
                  icon: Icons.chevron_left_rounded,
                  onTap: () => Navigator.of(context).maybePop(),
                  colors: colors,
                ),
              const SizedBox(height: 16),
              Text(
                'Cache',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 48), // ← добавить
            ],

          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: colors.textSecondary),
            onPressed: _refreshStats,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isDesktop ? 760 : double.infinity,
              maxHeight: c.maxHeight,
            ),
            child: ListView(
              padding: EdgeInsets.only(
                top: 0,
                bottom: 8 + MediaQuery.of(context).padding.bottom,
              ),
              children: [
                // === AUDIO CACHE ===
                _buildSectionHeader('Audio Cache', colors),
                _buildAudioCard(colors),

                const SizedBox(height: 16),

                // === ARTWORK CACHE ===
                _buildSectionHeader('Artwork Cache', colors),
                _buildCard(
                  colors: colors,
                  children: [
                    _buildCardHeader(
                      icon: Icons.image_rounded,
                      title: 'Cached artwork',
                      subtitle: _sizeSummary(
                        _artworkSize,
                        _artworkCount == null ? null : '$_artworkCount files',
                      ),
                      colors: colors,
                      onClear: _clearArtworkCache,
                    ),
                    _buildLimitBlock(
                      usedBytes: _artworkSize,
                      limitMB: _artworkLimitMB,
                      options: _limitOptions,
                      labels: _limitLabels,
                      colors: colors,
                      onLimitChanged: (mb) async {
                        setState(() => _artworkLimitMB = mb);
                        await YoutubeCache.setArtworkLimitMB(mb);
                        await _refreshStats();
                      },
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // === CLEAR ALL ===
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _buildDangerButton(
                    icon: Icons.delete_sweep_rounded,
                    label: 'Clear all cache',
                    onTap: _clearAllCache,
                    colors: colors,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, dynamic colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: colors.textTertiary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
        ),
      ),
    );
  }

  /// Общая карточка аудио-кэша: суммарный размер, переход к списку
  /// треков и лимиты хранилищ.
  Widget _buildAudioCard(AppColors colors) {
    final usage = _audioUsage;
    final count = usage?.trackCount;
    return _buildCard(
      colors: colors,
      children: [
        _buildCardHeader(
          icon: Icons.music_note_rounded,
          title: 'Cached tracks',
          subtitle: _sizeSummary(
            usage?.totalBytes,
            count == null ? null : '$count ${count == 1 ? 'track' : 'tracks'}',
          ),
          colors: colors,
          onClear: _clearAudioCache,
          onTap: _openCachedTracks,
        ),
        _buildLimitBlock(
          title: 'Streaming',
          usedBytes: usage?.streamingBytes,
          limitMB: _audioLimitMB,
          options: _limitOptions,
          labels: _limitLabels,
          colors: colors,
          onLimitChanged: (mb) async {
            setState(() => _audioLimitMB = mb);
            await YoutubeCache.setAudioLimitMB(mb);
            await _refreshStats();
          },
        ),
        if (_hasSoulseek)
          _buildLimitBlock(
            title: 'Soulseek',
            usedBytes: usage?.soulseekBytes,
            limitMB: _soulseekLimitMB,
            options: _soulseekLimitOptions,
            labels: _soulseekLimitLabels,
            colors: colors,
            onLimitChanged: (mb) async {
              setState(() => _soulseekLimitMB = mb);
              // Репозиторий синхронизирует лимит с нативным кэшем, а
              // натив может сразу вычистить лишнее — обновляем размер.
              await SoulseekSettingsRepository.instance.setCacheLimitMB(mb);
              await _refreshStats();
            },
          ),
      ],
    );
  }

  Widget _buildCard({
    required AppColors colors,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: colors.elevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.outline, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  /// Заголовок карточки: иконка, название, размер, кнопка очистки.
  /// С [onTap] строка кликабельна (стрелка справа от названия).
  Widget _buildCardHeader({
    required IconData icon,
    required String title,
    required String subtitle,
    required AppColors colors,
    required VoidCallback onClear,
    VoidCallback? onTap,
  }) {
    final row = Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: colors.textPrimary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (onTap != null)
                      Icon(
                        Icons.chevron_right_rounded,
                        color: colors.textSecondary,
                        size: 20,
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          // Кнопка очистки
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onClear,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent.withValues(alpha: 0.8),
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        onTap: onTap,
        child: row,
      ),
    );
  }

  /// Прогресс заполнения и чипы лимита одного хранилища.
  Widget _buildLimitBlock({
    String? title,
    required int? usedBytes,
    required int limitMB,
    required List<int> options,
    required List<String> labels,
    required AppColors colors,
    required ValueChanged<int> onLimitChanged,
  }) {
    final percent = _usagePercent(usedBytes, limitMB);
    final used = usedBytes != null ? formatBytes(usedBytes) : '...';
    final limitIndex = options.indexOf(limitMB);
    final limitText = limitMB == 0
        ? 'no limit'
        : 'of ${limitIndex >= 0 ? labels[limitIndex] : '$limitMB MB'}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title == null ? 'Size limit' : '$title size limit',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                '$used $limitText',
                style: TextStyle(
                  color: colors.textTertiary,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (percent != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: percent,
                backgroundColor: colors.background,
                valueColor: AlwaysStoppedAnimation<Color>(
                  percent > 0.9
                      ? Colors.orangeAccent
                      : percent > 0.75
                      ? Colors.yellowAccent
                      : colors.accent,
                ),
                minHeight: 6,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(options.length, (i) {
              final mb = options[i];
              return _LimitChip(
                label: labels[i],
                isSelected: limitMB == mb,
                colors: colors,
                onTap: () => onLimitChanged(mb),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildDangerButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required dynamic colors,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: Colors.redAccent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.redAccent.withValues(alpha: 0.2),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.redAccent, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===== Вспомогательный виджет =====

class _LimitChip extends StatelessWidget {
  const _LimitChip({
    required this.label,
    required this.isSelected,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final dynamic colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected
          ? colors.accent.withValues(alpha: 0.15)
          : colors.background,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? colors.accent.withValues(alpha: 0.4)
                  : colors.outline,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? colors.accent : colors.textSecondary,
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
//  КРУГЛАЯ КНОПКА 60×60
// =====================================================================

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
          child: Icon(icon, color: colors.textPrimary, size: 28),
        ),
      ),
    );
  }
}


