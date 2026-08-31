// lib/ui/widgets/playlist_cache_progress_sheet.dart
//
// Модальная шторка прогресса пакетного кэширования плейлиста.
//
// Открывается из пункта меню «Cache all tracks» на странице плейлиста
// (см. ui/pages/playlist_page.dart → _cacheAllTracks). Запуск [run]
// выполняется один раз при создании стейта; по завершении шторка
// сама закрывается с итоговым [PlaylistCacheResult]. Кнопка Cancel не
// закрывает шторку мгновенно — она лишь просит сервис остановиться
// (через [onCancel]), а шторка закроется, когда сервис вернёт
// cancelled-результат.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/playlist_cache_service.dart';
import '../desktop/desktop_layout.dart';

/// Открывает модальную шторку с прогрессом пакетного кэширования.
///
/// [run] получает колбэк прогресса и должен вернуть итоговый
/// [PlaylistCacheResult]. Возвращает этот результат, либо `null`, если
/// запуск завершился фатальной ошибкой (вызывающий код показывает
/// error-снэк).
Future<PlaylistCacheResult?> showPlaylistCacheProgressSheet(
  BuildContext context, {
  required String playlistName,
  required Future<PlaylistCacheResult> Function(
    void Function(PlaylistCacheProgress) onProgress,
  ) run,
  required VoidCallback onCancel,
}) {
  return showModalBottomSheet<PlaylistCacheResult>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetCtx) {
      final sheet = _PlaylistCacheProgressSheet(
        playlistName: playlistName,
        run: run,
        onCancel: onCancel,
      );
      if (!isDesktop) return sheet;
      return Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: sheet,
        ),
      );
    },
  );
}

class _PlaylistCacheProgressSheet extends StatefulWidget {
  const _PlaylistCacheProgressSheet({
    required this.playlistName,
    required this.run,
    required this.onCancel,
  });

  final String playlistName;
  final Future<PlaylistCacheResult> Function(
    void Function(PlaylistCacheProgress) onProgress,
  ) run;
  final VoidCallback onCancel;

  @override
  State<_PlaylistCacheProgressSheet> createState() =>
      _PlaylistCacheProgressSheetState();
}

class _PlaylistCacheProgressSheetState
    extends State<_PlaylistCacheProgressSheet> {
  PlaylistCacheProgress _progress = const PlaylistCacheProgress(
    completed: 0,
    total: 0,
    currentTitle: '',
    currentProgress: null,
  );

  /// Кнопка Cancel одноразовая: после нажатия ждём cancelled-результат.
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    // Стартуем после первого кадра: run опирается на живое дерево
    // (onProgress дёргает setState), а Navigator.pop из initState запрещён.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (!mounted) return;
    try {
      final result = await widget.run((progress) {
        if (!mounted) return;
        setState(() => _progress = progress);
      });
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (_) {
      // Фатальная ошибка запуска — вызывающий код покажет error-снэк.
      if (!mounted) return;
      Navigator.of(context).pop(null);
    }
  }

  void _onCancelPressed() {
    if (_cancelling) return;
    setState(() => _cancelling = true);
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _progress.total;
    final completed = _progress.completed;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Caching "${widget.playlistName}"',
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: total > 0 ? completed / total : null,
            ),
            const SizedBox(height: 8),
            Text(
              '$completed / $total',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text(
              _progress.currentTitle,
              style: theme.textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progress.currentProgress),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _cancelling ? null : _onCancelPressed,
                child: Text(_cancelling ? 'Cancelling…' : 'Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
