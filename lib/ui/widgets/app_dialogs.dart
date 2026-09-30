import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/platform/haptic_helper.dart';
import '../../core/providers.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  BASE DIALOG RUNNER
// ═══════════════════════════════════════════════════════════════════════════

Future<T?> _showConceptDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (ctx, _, _) => builder(ctx),
    transitionBuilder: (ctx, animation, _, child) {
      final curve = Curves.easeInOutQuart;
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

// ═══════════════════════════════════════════════════════════════════════════
//  1. INPUT DIALOG (Rename, create, etc.)
// ═══════════════════════════════════════════════════════════════════════════

Future<String?> showAppInputDialog({
  required BuildContext context,
  required String title,
  String? subtitle,
  String? initialValue,
  String hintText = 'Write here...',
  String confirmLabel = 'Save',
  String cancelLabel = 'Cancel',
}) {
  return _showConceptDialog<String>(
    context: context,
    builder: (_) => _AppInputDialog(
      title: title,
      subtitle: subtitle,
      initialValue: initialValue,
      hintText: hintText,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
    ),
  );
}

Future<String?> showAddPlaylistDialog(
  BuildContext context, [
  WidgetRef? ref,
]) {
  return showAppInputDialog(
    context: context,
    title: 'Create Playlist',
    subtitle: 'Evoke new feelings',
    hintText: 'Write your mood...',
    confirmLabel: 'Create',
  );
}

class _AppInputDialog extends ConsumerStatefulWidget {
  const _AppInputDialog({
    required this.title,
    this.subtitle,
    this.initialValue,
    required this.hintText,
    required this.confirmLabel,
    required this.cancelLabel,
  });

  final String title;
  final String? subtitle;
  final String? initialValue;
  final String hintText;
  final String confirmLabel;
  final String cancelLabel;

  @override
  ConsumerState<_AppInputDialog> createState() => _AppInputDialogState();
}

class _AppInputDialogState extends ConsumerState<_AppInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      HapticHelper.success(ref: ref);
      Navigator.of(context).pop(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);

    return _DialogFrame(
      title: widget.title,
      subtitle: widget.subtitle,
      colors: colors,
      body: SizedBox(
        height: 48,
        child: TextField(
          controller: _controller,
          autofocus: true,
          style: TextStyle(color: colors.textPrimary, fontSize: 16),
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            hintText: widget.hintText,
            hintStyle: TextStyle(color: colors.textSecondary, fontSize: 16),
            filled: true,
            fillColor: colors.elevated,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide(color: colors.elevatedHi, width: 1),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide(color: colors.elevatedHi, width: 1),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide(color: colors.elevatedHi, width: 1),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        Expanded(
          child: _DialogButton(
            label: widget.cancelLabel,
            backgroundColor: colors.elevated,
            foregroundColor: colors.textPrimary,
            onTap: () {
              HapticHelper.light(ref: ref);
              Navigator.of(context).pop();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _DialogButton(
            label: widget.confirmLabel,
            backgroundColor: colors.elevatedHi,
            foregroundColor: Colors.white,
            onTap: _submit,
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  2. CONFIRM DIALOG (Clear history, Delete, etc.)
// ═══════════════════════════════════════════════════════════════════════════

Future<bool?> showAppConfirmDialog({
  required BuildContext context,
  required String title,
  required String subtitle,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool isDestructive = false,
}) {
  return _showConceptDialog<bool>(
    context: context,
    builder: (_) => _AppConfirmDialog(
      title: title,
      subtitle: subtitle,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      isDestructive: isDestructive,
    ),
  );
}

class _AppConfirmDialog extends ConsumerWidget {
  const _AppConfirmDialog({
    required this.title,
    required this.subtitle,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.isDestructive,
  });

  final String title;
  final String subtitle;
  final String confirmLabel;
  final String cancelLabel;
  final bool isDestructive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);

    return _DialogFrame(
      title: title,
      subtitle: subtitle,
      colors: colors,
      glowColor: isDestructive ? Colors.redAccent.withValues(alpha: 0.3) : null,
      actions: [
        Expanded(
          child: _DialogButton(
            label: cancelLabel,
            backgroundColor: colors.elevated,
            foregroundColor: colors.textPrimary,
            onTap: () {
              HapticHelper.light(ref: ref);
              Navigator.of(context).pop(false);
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _DialogButton(
            label: confirmLabel,
            backgroundColor: isDestructive ? Colors.redAccent : colors.elevatedHi,
            foregroundColor: Colors.white,
            onTap: () {
              if (isDestructive) {
                HapticHelper.confirmDelete(ref: ref);
              } else {
                HapticHelper.success(ref: ref);
              }
              Navigator.of(context).pop(true);
            },
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  3. INFO DIALOG (Errors, Warnings, Notices)
// ═══════════════════════════════════════════════════════════════════════════

Future<void> showAppInfoDialog({
  required BuildContext context,
  required String title,
  required String subtitle,
  String okLabel = 'OK',
}) {
  return _showConceptDialog<void>(
    context: context,
    builder: (_) => Consumer(
      builder: (ctx, ref, _) {
        final colors = ref.watch(animatedPaletteProvider);
        return _DialogFrame(
          title: title,
          subtitle: subtitle,
          colors: colors,
          actions: [
            Expanded(
              child: _DialogButton(
                label: okLabel,
                backgroundColor: colors.elevatedHi,
                foregroundColor: Colors.white,
                onTap: () {
                  HapticHelper.light(ref: ref);
                  Navigator.of(ctx).pop();
                },
              ),
            ),
          ],
        );
      },
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  4. REPORT DIALOG (Diagnostics: loading → text with Copy / Share)
// ═══════════════════════════════════════════════════════════════════════════

Future<void> showAppReportDialog({
  required BuildContext context,
  required String title,
  String? subtitle,
  required Future<String> report,
  String? shareSubject,
}) {
  return _showConceptDialog<void>(
    context: context,
    builder: (_) => _AppReportDialog(
      title: title,
      subtitle: subtitle,
      report: report,
      shareSubject: shareSubject,
    ),
  );
}

class _AppReportDialog extends ConsumerStatefulWidget {
  const _AppReportDialog({
    required this.title,
    this.subtitle,
    required this.report,
    this.shareSubject,
  });

  final String title;
  final String? subtitle;
  final Future<String> report;
  final String? shareSubject;

  @override
  ConsumerState<_AppReportDialog> createState() => _AppReportDialogState();
}

class _AppReportDialogState extends ConsumerState<_AppReportDialog> {
  String? _text;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    widget.report.then(
      (text) {
        if (mounted) setState(() => _text = text);
      },
      onError: (Object e) {
        if (mounted) setState(() => _text = 'Failed to build report: $e');
      },
    );
  }

  Future<void> _copy() async {
    final text = _text;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    HapticHelper.success(ref: ref);
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _share() async {
    final text = _text;
    if (text == null) return;
    HapticHelper.light(ref: ref);
    await Share.share(text, subject: widget.shareSubject);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(animatedPaletteProvider);
    final text = _text;
    final ready = text != null;

    return _DialogFrame(
      title: widget.title,
      subtitle: widget.subtitle,
      colors: colors,
      body: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.45,
        ),
        decoration: BoxDecoration(
          color: colors.elevated,
          borderRadius: BorderRadius.circular(20),
        ),
        child: ready
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: SelectableText(
                  text,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 11,
                    height: 1.35,
                    fontFamily: 'monospace',
                  ),
                ),
              )
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: CircularProgressIndicator(
                    color: colors.accent,
                    strokeWidth: 2.5,
                  ),
                ),
              ),
      ),
      actions: [
        Expanded(
          child: _DialogButton(
            label: 'Close',
            backgroundColor: colors.elevated,
            foregroundColor: colors.textPrimary,
            onTap: () {
              HapticHelper.light(ref: ref);
              Navigator.of(context).pop();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _DialogButton(
            label: _copied ? 'Copied' : 'Copy',
            backgroundColor: colors.elevated,
            foregroundColor: ready ? colors.textPrimary : colors.textTertiary,
            onTap: _copy,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _DialogButton(
            label: 'Share',
            backgroundColor: colors.elevatedHi,
            foregroundColor: ready ? Colors.white : colors.textTertiary,
            onTap: _share,
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  UI BUILDING BLOCKS
// ═══════════════════════════════════════════════════════════════════════════

class _DialogFrame extends StatelessWidget {
  const _DialogFrame({
    required this.title,
    this.subtitle,
    required this.colors,
    required this.actions,
    this.body,
    this.glowColor,
  });

  final String title;
  final String? subtitle;
  final AppColors colors;
  final List<Widget> actions;
  final Widget? body;
  final Color? glowColor;

  @override
  Widget build(BuildContext context) {
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
                // Шапка с овальным радиальным градиентом
                Container(
                  margin: const EdgeInsets.all(8),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: Transform.scale(
                          scaleX: 4,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: Alignment.center,
                                radius: 0.4,
                                stops: const [0.0, 0.7],
                                colors: [
                                  glowColor ?? colors.elevatedHi.withValues(alpha: 0.5),
                                  colors.background.withValues(alpha: 0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 28,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 26,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (subtitle != null && subtitle!.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                subtitle!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (body != null) ...[
                  const SizedBox(height: 12),
                  body!,
                ],
                const SizedBox(height: 8),
                Row(children: actions),
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
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}