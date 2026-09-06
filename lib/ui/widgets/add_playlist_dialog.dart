import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Кастомный диалог создания плейлиста.
///
/// Возвращает введённое имя или `null`, если пользователь отменил.
///
/// Использование:
/// ```dart
/// final name = await showAddPlaylistDialog(context, ref);
/// if (name != null) {
///   final p = ref.read(playlistRepositoryProvider).create(name);
///   Navigator.of(context).push(
///     MaterialPageRoute(builder: (_) => PlaylistPage(playlistId: p.id)),
///   );
/// }
/// ```
Future<String?> showAddPlaylistDialog(
  BuildContext context,
  WidgetRef ref,
) {
  final colors = ref.read(currentPaletteProvider);

  return showGeneralDialog<String?>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (ctx, _, _) => _AddPlaylistDialog(colors: colors),
    transitionBuilder: (ctx, animation, _, child) {
      final curve = Curves.easeInOutQuart;
      // Появление: scale 0.7 → 1.0, fade 0.0 → 1.0
      // Закрытие: scale 1.0 → 0.7, fade 1.0 → 0.0 (автоматически)
      final scale = Tween<double>(begin: 0.7, end: 1.0)
          .chain(CurveTween(curve: curve))
          .animate(animation);
      final fade = Tween<double>(begin: 0.0, end: 1.0)
          .chain(CurveTween(curve: curve))
          .animate(animation);
      return FadeTransition(
        opacity: fade,
        child: ScaleTransition(scale: scale, child: child),
      );
    },
  );
}

class _AddPlaylistDialog extends StatefulWidget {
  const _AddPlaylistDialog({required this.colors});
  final AppColors colors;

  @override
  State<_AddPlaylistDialog> createState() => _AddPlaylistDialogState();
}

class _AddPlaylistDialogState extends State<_AddPlaylistDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      Navigator.of(context).pop(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;

    return Center(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Dialog(
          backgroundColor: colors.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(32),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Подложка с радиальным градиентом: elevatedHi → background@0%
                Container(
                  margin: const EdgeInsets.all(8),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Овальный радиальный градиент
                      Positioned.fill(
                        child: Transform.scale(
                          scaleX: 4,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: const Alignment(0, 0),
                                radius: 0.4,
                                stops: const [0.0, 0.7],
                                colors: [
                                  colors.elevatedHi.withValues(alpha: 0.5),
                                  colors.background.withValues(alpha: 0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Текст — без масштабирования
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 32,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Create Playlist',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 32,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 0),
                            Text(
                              'Evoke new feelings',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: colors.textSecondary,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Input field — 48px, pill, fill elevated, stroke elevatedHi 1px
                SizedBox(
                  height: 48,
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 16,
                    ),
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      hintText: 'Write your mood...',
                      hintStyle: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 16,
                      ),
                      filled: true,
                      fillColor: colors.elevated,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(
                          color: colors.elevatedHi,
                          width: 1,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(
                          color: colors.elevatedHi,
                          width: 1,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(
                          color: colors.elevatedHi,
                          width: 1,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                      ),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(height: 8),
                // Кнопки — 48px, pill, gap 8px
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: _DialogButton(
                          label: 'Cancel',
                          backgroundColor: colors.elevated,
                          foregroundColor: colors.textPrimary,
                          onTap: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: _DialogButton(
                          label: 'Create',
                          backgroundColor: colors.elevatedHi,
                          foregroundColor: Colors.white,
                          onTap: _submit,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogButton extends StatelessWidget {
  const _DialogButton({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onTap,
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Container(
          height: 48,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: foregroundColor,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}