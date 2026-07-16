import 'package:flutter/material.dart';

import '../../core/update_service.dart';

Future<void> showUpdateFlow(BuildContext context, dynamic colors) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog(
      backgroundColor: colors.elevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(width: 16),
            Text(
              'Checking for updates...',
              style: TextStyle(color: colors.textPrimary),
            ),
          ],
        ),
      ),
    ),
  );

  try {
    final result = await UpdateService.check();
    if (!context.mounted) return;
    Navigator.of(context).pop();

    if (!result.updateAvailable) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: colors.elevated,
          title: Text(
            'You are up to date',
            style: TextStyle(color: colors.textPrimary),
          ),
          content: Text(
            'Current version: ${result.currentVersion}',
            style: TextStyle(color: colors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateDialog(result: result, colors: colors),
    );
  } catch (error) {
    if (!context.mounted) return;
    Navigator.of(context).pop();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.elevated,
        title: Text(
          'Update check failed',
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          error.toString(),
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.result, required this.colors});

  final UpdateCheckResult result;
  final dynamic colors;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _downloading = false;
  double _progress = 0;

  Future<void> _downloadAndInstall() async {
    setState(() {
      _downloading = true;
      _progress = 0;
    });

    try {
      await UpdateService.downloadAndInstall(
        widget.result.release,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress.clamp(0, 1));
        },
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _downloading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString()),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final release = widget.result.release;
    final colors = widget.colors;
    final notes = release.notes.isEmpty
        ? 'No release notes were provided.'
        : release.notes;

    return AlertDialog(
      backgroundColor: colors.elevated,
      title: Text(
        'Update ${release.version}',
        style: TextStyle(color: colors.textPrimary),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Installed: ${widget.result.currentVersion}',
              style: TextStyle(color: colors.textSecondary),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  notes,
                  style: TextStyle(color: colors.textSecondary, height: 1.4),
                ),
              ),
            ),
            if (_downloading) ...[
              const SizedBox(height: 20),
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                color: colors.accent,
                backgroundColor: colors.outline,
              ),
              const SizedBox(height: 8),
              Text(
                _progress > 0
                    ? 'Downloading ${(100 * _progress).round()}%'
                    : 'Starting download...',
                style: TextStyle(color: colors.textTertiary, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading ? null : () => Navigator.of(context).pop(),
          child: const Text('Later'),
        ),
        FilledButton.icon(
          onPressed: _downloading ? null : _downloadAndInstall,
          icon: const Icon(Icons.download_rounded),
          label: const Text('Download and install'),
        ),
      ],
    );
  }
}
