import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../main.dart' show AppColors;

/// Экран настроек.
///
/// Пока тут только «Check for updates» — он лезет в GitHub Releases
/// репозитория проекта и сравнивает `tag_name` с текущей версией из
/// `package_info_plus`. Если у нас не самая свежая — показывает
/// диалог со ссылкой на релиз.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static const _repo = 'goddammit1/Player';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.chevron_left_rounded, size: 28),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Settings',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _Section(
            title: 'About',
            children: [
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snap) {
                  final v = snap.data?.version ?? '...';
                  final build = snap.data?.buildNumber ?? '';
                  return ListTile(
                    leading: const Icon(
                      Icons.info_outline_rounded,
                      color: AppColors.textPrimary,
                    ),
                    title: const Text(
                      'Version',
                      style: TextStyle(color: AppColors.textPrimary),
                    ),
                    subtitle: Text(
                      build.isEmpty ? v : '$v ($build)',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.system_update_alt_rounded,
                  color: AppColors.textPrimary,
                ),
                title: const Text(
                  'Check for updates',
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                subtitle: const Text(
                  'Latest release on GitHub',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                onTap: () => _checkForUpdates(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _checkForUpdates(BuildContext context) async {
    // Показываем модал «checking...» сразу, чтобы дать визуальный фидбек.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CheckingDialog(),
    );

    String currentVersion = '0.0.0';
    String? latestTag;
    String? releaseUrl;
    String? releaseName;
    String? error;

    try {
      final info = await PackageInfo.fromPlatform();
      currentVersion = info.version;

      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        validateStatus: (_) => true,
      ));
      final resp = await dio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$_repo/releases/latest',
        options: Options(
          headers: {'Accept': 'application/vnd.github+json'},
          responseType: ResponseType.json,
        ),
      );
      if (resp.statusCode == 200 && resp.data != null) {
        latestTag = (resp.data!['tag_name'] as String?)?.trim();
        releaseUrl = resp.data!['html_url'] as String?;
        releaseName = resp.data!['name'] as String?;
      } else {
        error = 'GitHub returned ${resp.statusCode}';
      }
    } catch (e) {
      error = e.toString();
    }

    if (!context.mounted) return;
    Navigator.of(context).pop(); // закрываем «checking...»

    if (error != null) {
      _showResultDialog(
        context,
        title: 'Update check failed',
        body: error,
      );
      return;
    }

    final isNewer = _isNewer(latestTag ?? '', currentVersion);
    if (isNewer) {
      _showResultDialog(
        context,
        title: 'Update available',
        body:
            'You are on $currentVersion. Latest is ${latestTag ?? '?'}'
            '${releaseName != null && releaseName.isNotEmpty ? ' — $releaseName' : ''}.',
        actionLabel: 'Open',
        action: () => _copyToClipboard(context, releaseUrl ?? ''),
      );
    } else {
      _showResultDialog(
        context,
        title: 'You are up to date',
        body: 'Current version: $currentVersion'
            '${latestTag != null ? ' (latest: $latestTag)' : ''}.',
      );
    }
  }

  /// Сравниваем «семвероподобные» теги: `v1.2.3` vs `1.2`. Очищаем от
  /// `v`-префикса, режем на части, добиваем нулями до длины 3.
  bool _isNewer(String tag, String current) {
    List<int> parse(String s) {
      final clean = s.replaceFirst(RegExp('^v', caseSensitive: false), '');
      final parts = clean.split(RegExp(r'[\.\-+]')).take(3).toList();
      final n = <int>[];
      for (final p in parts) {
        n.add(int.tryParse(p) ?? 0);
      }
      while (n.length < 3) {
        n.add(0);
      }
      return n;
    }

    final t = parse(tag);
    final c = parse(current);
    for (var i = 0; i < 3; i++) {
      if (t[i] > c[i]) return true;
      if (t[i] < c[i]) return false;
    }
    return false;
  }

  void _showResultDialog(
    BuildContext context, {
    required String title,
    required String body,
    String? actionLabel,
    VoidCallback? action,
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(
            title,
            style: const TextStyle(color: AppColors.textPrimary),
          ),
          content: Text(
            body,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          actions: [
            if (actionLabel != null && action != null)
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  action();
                },
                child: Text(actionLabel),
              ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Release URL copied to clipboard'),
        duration: Duration(milliseconds: 1500),
      ),
    );
  }
}

class _CheckingDialog extends StatelessWidget {
  const _CheckingDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Text(
              'Checking for updates...',
              style: TextStyle(color: AppColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}
