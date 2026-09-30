// lib/ui/widgets/soulseek_cache_sheet.dart
//
// Фаза 4 — нижний лист управления кэшем Soulseek.
//
// Показывает список кэшированных файлов с:
//  - именем файла (из localPath)
//  - размером файла
//  - статусом complete / incomplete
//  - индикатором pinned (закреплён)
//  - кнопками Pin/Unpin и Delete
//
// P1-каскад: список строится из нативной БД (getCacheEntries),
// известной Kotlin-стороне с момента завершения загрузки. Прежний
// Dart-индекс knownCacheKeys (SharedPreferences) пополнялся только из
// transfer-событий и терял записи, завершённые без подписки.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/track.dart';
import '../../sources/soulseek_models.dart';
import '../../sources/soulseek_platform_channel.dart';
import '../../sources/soulseek_source.dart';
import '../../sources/source_registry.dart';
import '../desktop/desktop_layout.dart';
import 'snack.dart';
import 'track_settings_sheet.dart';

/// Показывает нижний лист управления кэшем Soulseek.
Future<void> showSoulseekCacheSheet(BuildContext context) {
  if (isDesktop) {
    return showDesktopModalSheet(
      context: context,
      builder: (_) => const _CacheSheet(),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (_) => const _CacheSheet(),
  );
}

class _CacheSheet extends ConsumerStatefulWidget {
  const _CacheSheet();

  @override
  ConsumerState<_CacheSheet> createState() => _CacheSheetState();
}

class _CacheSheetState extends ConsumerState<_CacheSheet> {
  final _platform = SoulseekPlatformChannel.instance;

  List<_CacheItem> _items = const [];
  bool _loading = true;
  int _totalBytes = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final source = SourceRegistry.instance.get('soulseek');
    if (source is! SoulseekSource) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final items = <_CacheItem>[];
    var totalBytes = 0;

    // P1-каскад: источник истины — нативная БД (getCacheEntries).
    // Попутно синхронизируем Dart-индекс knownCacheKeys.
    List<SoulseekCacheEntry> entries;
    try {
      await source.refreshCacheIndex();
      entries = await _platform.getCacheEntries();
    } catch (_) {
      // Нативный список недоступен (не Android / сервис не привязан) —
      // фолбэк на локальный индекс.
      entries = const [];
      for (final key in source.knownCacheKeys) {
        try {
          final entry = await _platform.getCacheEntry(key);
          if (entry != null) entries = [...entries, entry];
        } catch (_) {
          // Игнорируем отдельные ошибки.
        }
      }
    }

    for (final entry in entries) {
      items.add(_CacheItem(
        cacheKey: entry.cacheKey,
        entry: entry,
        // CACHE-UI-01: Track из записи кэша — extra.cacheKey даёт
        // мгновенный cache hit в resolveStreamUrl (без повторной загрузки).
        track: source.trackFromCacheEntry(entry),
      ));
      if (entry.complete) totalBytes += entry.sizeBytes;
    }

    // Сортировка: pinned первыми, затем по размеру (убывание).
    items.sort((a, b) {
      if (a.entry.pinned != b.entry.pinned) {
        return a.entry.pinned ? -1 : 1;
      }
      return b.entry.sizeBytes.compareTo(a.entry.sizeBytes);
    });

    if (mounted) {
      setState(() {
        _items = items;
        _totalBytes = totalBytes;
        _loading = false;
      });
    }
  }

  // ── Действия ──

  /// CACHE-UI-01: тап по complete-плитке → воспроизведение из кэша.
  ///
  /// Очередь = все complete-треки кэш-листа (в текущем порядке отображения),
  /// старт с выбранного — консистентно со страницей поиска. Track несёт
  /// `extra.cacheKey`, поэтому resolveStreamUrl возвращает localPath из
  /// native-кэша мгновенно, без сети.
  void _playFromCache(_CacheItem item, int index) {
    if (!item.entry.complete) return;

    final queue = _items
        .where((i) => i.entry.complete)
        .map((i) => i.track)
        .toList(growable: false);

    // Индекс внутри complete-подмножества.
    final playIndex = _items
        .sublist(0, index + 1)
        .where((i) => i.entry.complete)
        .length - 1;

    final player = ref.read(playerServiceProvider);
    player.setQueue(queue, startIndex: playIndex);
  }

  /// CACHE-UI-01: long-press → контекстное меню (add to playlist, play next,
  /// details, download-status) — тот же sheet, что и у плиток поиска.
  void _showTrackSettings(_CacheItem item) {
    if (!item.entry.complete) return;
    showTrackSettingsSheet(context, track: item.track);
  }

  Future<void> _togglePin(_CacheItem item) async {
    try {
      final newPinned = !item.entry.pinned;
      await _platform.pinCache(item.cacheKey, pinned: newPinned);
      if (mounted) {
        showSnack(
          context,
          newPinned ? 'Pinned' : 'Unpinned',
        );
      }
      _refresh();
    } catch (_) {
      if (mounted) showSnack(context, 'Failed to update pin status');
    }
  }

  Future<void> _delete(_CacheItem item) async {
    try {
      await _platform.removeCache(item.cacheKey);
      final source = SourceRegistry.instance.get('soulseek');
      if (source is SoulseekSource) {
        source.forgetCacheKey(item.cacheKey);
      }
      if (mounted) showSnack(context, 'Cache file removed');
      _refresh();
    } catch (_) {
      if (mounted) showSnack(context, 'Failed to remove cache file');
    }
  }

  Future<void> _cleanup() async {
    try {
      final removed = await _platform.cleanupCache();
      if (mounted) {
        showSnack(context, 'Cleaned up $removed file(s)');
      }
      _refresh();
    } catch (_) {
      if (mounted) showSnack(context, 'Cleanup failed');
    }
  }

  Future<void> _deleteAll() async {
    final confirmed = await _showConfirmDialog(
      'Clear all Soulseek cache?',
      'This will permanently remove all cached Soulseek files '
      'from this device. Pinned files will also be removed.',
    );
    if (confirmed != true) return;

    int removed = 0;
    for (final item in _items.toList()) {
      try {
        final ok = await _platform.removeCache(item.cacheKey);
        if (ok) removed++;
      } catch (_) {}
    }

    final source = SourceRegistry.instance.get('soulseek');
    if (source is SoulseekSource) {
      source.clearCacheIndex();
    }

    if (mounted) showSnack(context, 'Removed $removed file(s)');
    _refresh();
  }

  Future<bool?> _showConfirmDialog(String title, String subtitle) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(subtitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.85;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHandle(colors),
          _buildHeader(colors),
          const Divider(height: 1),
          Flexible(
            child: _loading
                ? _buildLoading(colors)
                : _items.isEmpty
                    ? _buildEmpty(colors)
                    : _buildList(colors, media.padding.bottom),
          ),
          if (!_loading && _items.isNotEmpty)
            _buildFooterActions(colors, media.padding.bottom),
        ],
      ),
    );
  }

  Widget _buildHandle(dynamic colors) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: colors.textTertiary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader(dynamic colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
      child: Row(
        children: [
          Icon(Icons.storage_rounded, color: colors.textPrimary, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Soulseek cache',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_items.isNotEmpty)
                  Text(
                    '${_items.length} files · ${_humanBytes(_totalBytes)}',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(Icons.close_rounded, color: colors.textSecondary),
            iconSize: 22,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildLoading(dynamic colors) {
    return SizedBox(
      height: 120,
      child: Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: colors.accent,
        ),
      ),
    );
  }

  Widget _buildEmpty(dynamic colors) {
    return SizedBox(
      height: 200,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_off_outlined,
              size: 40,
              color: colors.textTertiary,
            ),
            const SizedBox(height: 12),
            Text(
              'No cached files',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Downloaded Soulseek files will appear here',
              style: TextStyle(
                color: colors.textTertiary,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(dynamic colors, double bottomInset) {
    return ListView.separated(
      shrinkWrap: true,
      padding: EdgeInsets.only(top: 4, bottom: 8),
      itemCount: _items.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        indent: 16,
        endIndent: 16,
        color: colors.outline.withValues(alpha: 0.3),
      ),
      itemBuilder: (context, index) {
        final item = _items[index];
        return _CacheTile(
          item: item,
          colors: colors,
          onTap: () => _playFromCache(item, index),
          onLongPress: () => _showTrackSettings(item),
          onTogglePin: () => _togglePin(item),
          onDelete: () => _delete(item),
        );
      },
    );
  }

  Widget _buildFooterActions(dynamic colors, double bottomInset) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + bottomInset),
      child: Row(
        children: [
          Expanded(
            child: _FooterButton(
              label: 'Cleanup (LRU)',
              icon: Icons.auto_delete_outlined,
              colors: colors,
              onTap: _cleanup,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _FooterButton(
              label: 'Clear all',
              icon: Icons.delete_sweep_outlined,
              colors: colors,
              onTap: _deleteAll,
              destructive: true,
            ),
          ),
        ],
      ),
    );
  }

  String _humanBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    if (unit == 0) return '$bytes B';
    return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[unit]}';
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Data
// ═══════════════════════════════════════════════════════════════════════

class _CacheItem {
  final String cacheKey;
  final SoulseekCacheEntry entry;

  /// CACHE-UI-01: Track для воспроизведения/контекстных действий
  /// (построен через SoulseekSource.trackFromCacheEntry).
  final Track track;

  const _CacheItem({
    required this.cacheKey,
    required this.entry,
    required this.track,
  });
}

// ═══════════════════════════════════════════════════════════════════════
//  _CacheTile — отдельный кэш-файл
// ═══════════════════════════════════════════════════════════════════════

class _CacheTile extends StatelessWidget {
  const _CacheTile({
    required this.item,
    required this.colors,
    this.onTap,
    this.onLongPress,
    required this.onTogglePin,
    required this.onDelete,
  });

  final _CacheItem item;
  final dynamic colors;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onTogglePin;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final entry = item.entry;
    // NEW-3: человекочитаемые метаданные из БД v2; для старых записей
    // (завершённых до миграции) — фолбэк на basename файла.
    final title =
        (entry.title != null && entry.title!.isNotEmpty)
            ? entry.title!
            : _basename(entry.localPath);
    final artist = entry.artist;
    final durationText = _durationText(entry.durationSeconds);

    // CACHE-UI-01: complete-плитки кликабельны (тап → play, long-press →
    // контекстные действия); incomplete — пассивны, как и раньше.
    final tappable = entry.complete && (onTap != null || onLongPress != null);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: tappable ? onTap : null,
        onLongPress: tappable ? onLongPress : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              // Иконка статуса
              Icon(
                entry.complete
                    ? (entry.pinned
                        ? Icons.push_pin_rounded
                        : Icons.check_circle_outline_rounded)
                    : Icons.downloading_rounded,
                color: entry.pinned
                    ? colors.accent as Color
                    : entry.complete
                        ? Colors.greenAccent
                        : colors.textTertiary as Color,
                size: 22,
              ),
              const SizedBox(width: 12),
              // Заголовок/артист + размер/длительность
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            artist != null && artist.isNotEmpty
                                ? artist
                                : _basename(entry.localPath),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (durationText != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            '· $durationText',
                            style: TextStyle(
                              color: colors.textTertiary,
                              fontSize: 12,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        Text(
                          _humanBytes(entry.sizeBytes),
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 12,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (!entry.complete) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orangeAccent.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'incomplete',
                              style: TextStyle(
                                color: Colors.orangeAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // Pin toggle
              _IconButton(
                icon: entry.pinned
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
                colors: colors,
                onTap: onTogglePin,
                active: entry.pinned,
              ),
              // Delete
              _IconButton(
                icon: Icons.delete_outline_rounded,
                colors: colors,
                onTap: onDelete,
                destructive: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _basename(String path) {
    final i = path.lastIndexOf('/');
    final j = path.lastIndexOf('\\');
    final idx = i > j ? i : j;
    if (idx >= 0 && idx < path.length - 1) return path.substring(idx + 1);
    return path;
  }

  /// «3:45» из durationSeconds; null, если длительность неизвестна.
  String? _durationText(int? seconds) {
    if (seconds == null || seconds <= 0) return null;
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _humanBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    if (unit == 0) return '$bytes B';
    return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[unit]}';
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Small widgets
// ═══════════════════════════════════════════════════════════════════════

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.colors,
    required this.onTap,
    this.destructive = false,
    this.active = false,
  });

  final IconData icon;
  final dynamic colors;
  final VoidCallback onTap;
  final bool destructive;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = destructive
        ? Colors.redAccent
        : active
            ? colors.accent as Color
            : colors.textSecondary as Color;

    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 20, color: color),
        ),
      ),
    );
  }
}

class _FooterButton extends StatelessWidget {
  const _FooterButton({
    required this.label,
    required this.icon,
    required this.colors,
    required this.onTap,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final dynamic colors;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final fgColor = destructive
        ? Colors.redAccent
        : colors.textPrimary as Color;
    final bgColor = destructive
        ? Colors.redAccent.withValues(alpha: 0.08)
        : colors.elevated;

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fgColor, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fgColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
