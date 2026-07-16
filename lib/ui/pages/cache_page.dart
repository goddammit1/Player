import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/youtube_cache.dart';

/// Страница управления кэшем.
///
/// Два независимых лимита:
/// - Audio cache: mp3/m4a/webm треки
/// - Artwork cache: обложки (CachedNetworkImage хранит сам, мы лишь
///   ограничиваем его размер через ImageCache + свой дисковый кэш)
class CachePage extends ConsumerStatefulWidget {
  const CachePage({super.key});

  @override
  ConsumerState<CachePage> createState() => _CachePageState();
}

class _CachePageState extends ConsumerState<CachePage> {
  // ===== Состояние =====
  int? _audioSize;
  int? _audioCount;
  int? _artworkSize;
  int? _artworkCount;

  late int _audioLimitMB;
  late int _artworkLimitMB;

  // Опции лимита: 0 = unlimited
  static const List<int> _limitOptions = [100, 500, 1024, 5120, 0];
  static const List<String> _limitLabels = ['100 MB', '500 MB', '1 GB', '5 GB', 'Unlimited'];

  @override
  void initState() {
    super.initState();
    _audioLimitMB = YoutubeCache.maxAudioCacheMB;
    _artworkLimitMB = YoutubeCache.maxArtworkCacheMB;
    _refreshStats();
  }

  // ===== Статистика =====

  Future<void> _refreshStats() async {
    final audioDir = YoutubeCache.instance.audioDir;
    
    // Инициализирует пути кэша, если их ещё никто не трогал.
    final artworkDir = await YoutubeCache.instance.ensureArtworkDir();

    final audioStats = await _calcDirStats(audioDir);
    final artworkStats = await _calcDirStats(artworkDir);

    if (mounted) {
      setState(() {
        _audioSize = audioStats.$1;
        _audioCount = audioStats.$2;
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  double? _usagePercent(int? usedBytes, int limitMB) {
    if (usedBytes == null || limitMB == 0) return null;
    final limitBytes = limitMB * 1024 * 1024;
    return (usedBytes / limitBytes).clamp(0.0, 1.0);
  }

  // ===== Действия =====

  Future<void> _clearAudioCache() async {
    final confirmed = await _showConfirmDialog(
      title: 'Clear audio cache?',
      body: 'All cached tracks will be deleted. They will be re-downloaded on next play.',
    );
    if (confirmed != true) return;

    await YoutubeCache.instance.clearAudioCache();
    await _refreshStats();

    if (mounted) _showSnack('Audio cache cleared');
  }

  Future<void> _clearArtworkCache() async {
    final confirmed = await _showConfirmDialog(
      title: 'Clear artwork cache?',
      body: 'All cached artwork will be deleted. They will be re-downloaded on next view.',
    );
    if (confirmed != true) return;

    // Чистим Flutter ImageCache (RAM)
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    // Дисковый кэш CachedNetworkImage чистит YoutubeCache.
    await YoutubeCache.instance.clearArtworkCache();

    await _refreshStats();
    if (mounted) _showSnack('Artwork cache cleared');
  }

  Future<void> _clearAllCache() async {
    final confirmed = await _showConfirmDialog(
      title: 'Clear all cache?',
      body: 'All cached tracks and artwork will be deleted. This cannot be undone.',
    );
    if (confirmed != true) return;

    await YoutubeCache.instance.clearAllCache();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await _refreshStats();

    if (mounted) _showSnack('All cache cleared');
  }

  Future<bool?> _showConfirmDialog({required String title, required String body}) {
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
            child: Text('Cancel', style: TextStyle(color: colors.textSecondary)),
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
        leading: IconButton(
          icon: Icon(Icons.chevron_left_rounded, size: 28, color: colors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Cache',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: colors.textSecondary),
            onPressed: _refreshStats,
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.only(
          top: 8,
          bottom: 8 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          // === AUDIO CACHE ===
          _buildSectionHeader('Audio Cache', colors),
          _buildCacheCard(
            icon: Icons.music_note_rounded,
            title: 'Cached tracks',
            usedBytes: _audioSize,
            fileCount: _audioCount,
            limitMB: _audioLimitMB,
            colors: colors,
            onLimitChanged: (mb) async {
              setState(() => _audioLimitMB = mb);
              await YoutubeCache.setAudioLimitMB(mb);
              await _refreshStats();
            },
            onClear: _clearAudioCache,
          ),

          const SizedBox(height: 16),

          // === ARTWORK CACHE ===
          _buildSectionHeader('Artwork Cache', colors),
          _buildCacheCard(
            icon: Icons.image_rounded,
            title: 'Cached artwork',
            usedBytes: _artworkSize,
            fileCount: _artworkCount,
            limitMB: _artworkLimitMB,
            colors: colors,
            onLimitChanged: (mb) async {
              setState(() => _artworkLimitMB = mb);
              await YoutubeCache.setArtworkLimitMB(mb);
              await _refreshStats();
            },
            onClear: _clearArtworkCache,
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

  Widget _buildCacheCard({
    required IconData icon,
    required String title,
    required int? usedBytes,
    required int? fileCount,
    required int limitMB,
    required dynamic colors,
    required ValueChanged<int> onLimitChanged,
    required VoidCallback onClear,
  }) {
    final sizeStr = usedBytes != null ? _formatBytes(usedBytes) : '...';
    final countStr = fileCount != null ? '$fileCount files' : '';
    final percent = _usagePercent(usedBytes, limitMB);

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
          children: [
            // Заголовок + иконка
            Padding(
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
                        Text(
                          title,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$sizeStr • $countStr',
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
            ),

            // Прогресс-бар (если лимит задан)
            if (percent != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
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
              ),

            // Лимит
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Size limit',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: List.generate(_limitOptions.length, (i) {
                      final mb = _limitOptions[i];
                      final label = _limitLabels[i];
                      final isSelected = limitMB == mb;
                      return _LimitChip(
                        label: label,
                        isSelected: isSelected,
                        colors: colors,
                        onTap: () => onLimitChanged(mb),
                      );
                    }),
                  ),
                ],
              ),
            ),
          ],
        ),
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
      color: isSelected ? colors.accent.withValues(alpha: 0.15) : colors.background,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? colors.accent.withValues(alpha: 0.4) : colors.outline,
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