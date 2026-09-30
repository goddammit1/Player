import 'package:flutter/material.dart';

import '../../core/update_service.dart';

/// Запускает полный флоу проверки обновлений. [checkOverride] подменяет
/// обращение к GitHub API — используется в тестах для доставки
/// детерминированного результата проверки.
Future<void> showUpdateFlow(
  BuildContext context,
  dynamic colors, {
  Future<UpdateCheckResult> Function()? checkOverride,
}) async {
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
    final result = await (checkOverride?.call() ?? UpdateService.check());
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

enum _Phase { idle, downloading, readyToInstall, installing }

class _UpdateDialogState extends State<_UpdateDialog> {
  _Phase _phase = _Phase.idle;
  double _progress = 0;
  String? _apkPath;

  bool get _busy =>
      _phase == _Phase.downloading || _phase == _Phase.installing;

  void _showError(Object error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error.toString()),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Future<void> _download() async {
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
    });

    try {
      final path = await UpdateService.download(
        widget.result.release,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress.clamp(0, 1));
        },
      );
      if (!mounted) return;
      setState(() {
        _apkPath = path;
        _phase = _Phase.readyToInstall;
      });
      // Скачали один раз — сразу пробуем поставить.
      await _install();
    } catch (error) {
      if (!mounted) return;
      setState(() => _phase = _Phase.idle);
      _showError(error);
    }
  }

  Future<void> _install() async {
    final path = _apkPath;
    if (path == null) {
      // Файла нет (кэш очищен) — качаем заново.
      await _download();
      return;
    }

    setState(() => _phase = _Phase.installing);
    try {
      final outcome = await UpdateService.install(path);
      if (!mounted) return;
      // В обоих случаях возвращаемся в readyToInstall: либо система
      // открыла установщик, либо увела в настройки за разрешением.
      // APK уже скачан, повторное скачивание не нужно.
      setState(() => _phase = _Phase.readyToInstall);
      if (outcome == InstallOutcome.permissionRequired) {
        _showError(
          'Разрешите установку из этого источника, затем нажмите «Установить».',
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _phase = _Phase.readyToInstall);
      _showError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final release = widget.result.release;
    final colors = widget.colors;
    final notes = release.notes.isEmpty
        ? 'No release notes were provided.'
        : release.notes;

    final isBeta = release.isBeta;
    final readyToInstall = _phase == _Phase.readyToInstall;
    final actionLabel = readyToInstall
        ? (isBeta ? 'Установить (бета)' : 'Установить')
        : (isBeta ? 'Скачать и установить (бета)' : 'Скачать и установить');
    final actionIcon = readyToInstall
        ? Icons.install_mobile_rounded
        : Icons.download_rounded;

    return AlertDialog(
      backgroundColor: colors.elevated,
      title: Row(
        children: [
          Flexible(
            child: Text(
              'Update ${release.version}',
              style: TextStyle(color: colors.textPrimary),
            ),
          ),
          if (isBeta) ...[
            const SizedBox(width: 8),
            const _BetaBadge(),
          ],
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isBeta) ...[
              _BetaBanner(colors: colors),
              const SizedBox(height: 14),
            ],
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
            if (_phase == _Phase.downloading) ...[
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
            ] else if (readyToInstall) ...[
              const SizedBox(height: 16),
              Text(
                'Загружено. Если установщик не открылся — разрешите установку '
                'из этого источника и нажмите «Установить».',
                style: TextStyle(color: colors.textTertiary, fontSize: 12),
              ),
            ] else if (_phase == _Phase.installing) ...[
              const SizedBox(height: 16),
              Text(
                'Открываю установщик…',
                style: TextStyle(color: colors.textTertiary, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Later'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : (readyToInstall ? _install : _download),
          icon: Icon(actionIcon),
          label: Text(actionLabel),
        ),
      ],
    );
  }
}

/// Компактный бейдж «BETA» рядом с версией релиза в заголовке диалога.
class _BetaBadge extends StatelessWidget {
  const _BetaBadge();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.orangeAccent, width: 1),
      ),
      child: const Text(
        'BETA',
        style: TextStyle(
          color: Colors.orangeAccent,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// Баннер-предупреждение о бета-статусе релиза над списком изменений.
class _BetaBanner extends StatelessWidget {
  const _BetaBanner({required this.colors});

  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orangeAccent, width: 1),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.orangeAccent,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Это бета-версия: возможны ошибки и нестабильная работа',
              style: TextStyle(
                color: colors.textSecondary as Color,
                fontSize: 13,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
