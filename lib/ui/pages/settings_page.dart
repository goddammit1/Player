import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:dio/dio.dart';

import '../../core/providers.dart';
import 'cache_page.dart';

// ═══════════════════════════════════════════════════════════════════
//  SETTINGS PAGE
// ═══════════════════════════════════════════════════════════════════

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  static const _repo = 'goddammit1/Player';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);

    return _PageAnimator(
      child: Scaffold(
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
            'Settings',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _AppearanceSection(colors: colors),
            _HapticsSection(colors: colors),
            _CacheTile(colors: colors),
            _AboutSection(repo: _repo, colors: colors),
          ],
        ),
      ),
    );
  }
}


// =====================================================================
//  CACHE TILE (переход на страницу кэша)
// =====================================================================

class _CacheTile extends ConsumerWidget {
  const _CacheTile({required this.colors});
  final dynamic colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: Icon(Icons.storage_rounded, color: colors.textPrimary),
      title: Text('Cache', style: TextStyle(color: colors.textPrimary)),
      subtitle: Text(
        'Manage audio & artwork cache',
        style: TextStyle(color: colors.textSecondary),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: colors.textTertiary,
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const CachePage()),
      ),
    );
  }
}


// =====================================================================
//  APPEARANCE SECTION
// =====================================================================

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection({required this.colors});
  final dynamic colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(appThemeModeProvider);

    return _Section(
      title: 'Appearance',
      colors: colors,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Theme',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 44,
                decoration: BoxDecoration(
                  color: colors.elevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colors.outline, width: 1),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _ThemeOption(
                        label: 'Fixed',
                        icon: Icons.palette_outlined,
                        isSelected: mode == AppThemeMode.fixed,
                        onTap: () => ref
                            .read(appThemeModeProvider.notifier)
                            .setMode(AppThemeMode.fixed),
                        colors: colors,
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: colors.outline,
                      indent: 8,
                      endIndent: 8,
                    ),
                    Expanded(
                      child: _ThemeOption(
                        label: 'Dynamic',
                        icon: Icons.auto_awesome_outlined,
                        isSelected: mode == AppThemeMode.dynamic,
                        onTap: () => ref
                            .read(appThemeModeProvider.notifier)
                            .setMode(AppThemeMode.dynamic),
                        colors: colors,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                mode == AppThemeMode.dynamic
                    ? 'Colors adapt to the current track artwork.'
                    : 'Use the default dark grey palette.',
                style: TextStyle(
                  color: colors.textTertiary,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: isSelected
                    ? colors.textPrimary
                    : colors.textTertiary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: isSelected
                      ? colors.textPrimary
                      : colors.textTertiary,
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =====================================================================
//  HAPTICS SECTION — NEW
// =====================================================================

class _HapticsSection extends ConsumerWidget {
  const _HapticsSection({required this.colors});
  final dynamic colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(vibrationEnabledProvider);

    return _Section(
      title: 'Haptics',
      colors: colors,
      children: [
        ListTile(
          leading: Icon(
            Icons.vibration_rounded,
            color: colors.textPrimary,
          ),
          title: Text(
            'Vibration feedback',
            style: TextStyle(color: colors.textPrimary),
          ),
          subtitle: Text(
            enabled
                ? 'Haptic feedback on progress bar and queue interactions.'
                : 'Haptic feedback is disabled.',
            style: TextStyle(color: colors.textSecondary),
          ),
          trailing: Switch.adaptive(
            value: enabled,
            onChanged: (v) => ref.read(vibrationEnabledProvider.notifier).setEnabled(v),
            activeThumbColor: colors.accent,
            activeTrackColor: colors.accent.withValues(alpha: 0.3),
            inactiveThumbColor: colors.textSecondary,
            inactiveTrackColor: colors.elevated,
          ),
        ),
      ],
    );
  }
}

// =====================================================================
//  ABOUT SECTION
// =====================================================================

class _AboutSection extends StatelessWidget {
  const _AboutSection({required this.repo, required this.colors});
  final String repo;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'About',
      colors: colors,
      children: [
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snap) {
            final v = snap.data?.version ?? '...';
            final build = snap.data?.buildNumber ?? '';
            return ListTile(
              leading: Icon(
                Icons.info_outline_rounded,
                color: colors.textPrimary,
              ),
              title: Text(
                'Version',
                style: TextStyle(color: colors.textPrimary),
              ),
              subtitle: Text(
                build.isEmpty ? v : '$v ($build)',
                style: TextStyle(color: colors.textSecondary),
              ),
            );
          },
        ),
        ListTile(
          leading: Icon(
            Icons.system_update_alt_rounded,
            color: colors.textPrimary,
          ),
          title: Text(
            'Check for updates',
            style: TextStyle(color: colors.textPrimary),
          ),
          subtitle: Text(
            'Latest release on GitHub',
            style: TextStyle(color: colors.textSecondary),
          ),
          onTap: () => _checkForUpdates(context, repo, colors),
        ),
      ],
    );
  }

  Future<void> _checkForUpdates(BuildContext context, String repo, dynamic colors) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CheckingDialog(colors: colors),
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
        'https://api.github.com/repos/$repo/releases/latest',
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
    Navigator.of(context).pop();

    if (error != null) {
      _showResultDialog(
        context,
        colors: colors,
        title: 'Update check failed',
        body: error,
      );
      return;
    }

    final isNewer = _isNewer(latestTag ?? '', currentVersion);
    if (isNewer) {
      _showResultDialog(
        context,
        colors: colors,
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
        colors: colors,
        title: 'You are up to date',
        body: 'Current version: $currentVersion'
            '${latestTag != null ? ' (latest: $latestTag)' : ''}.',
      );
    }
  }

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
    required dynamic colors,
    String? actionLabel,
    VoidCallback? action,
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: colors.elevated,
          title: Text(
            title,
            style: TextStyle(color: colors.textPrimary),
          ),
          content: Text(
            body,
            style: TextStyle(color: colors.textSecondary),
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

// =====================================================================
//  SHARED WIDGETS
// =====================================================================

class _CheckingDialog extends StatelessWidget {
  const _CheckingDialog({required this.colors});
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return Dialog(
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
              child: CircularProgressIndicator(strokeWidth: 2, color: colors.textPrimary),
            ),
            const SizedBox(width: 16),
            Text(
              'Checking for updates...',
              style: TextStyle(color: colors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, required this.colors});
  final String title;
  final List<Widget> children;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
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
        ),
        ...children,
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  SHARED ANIMATOR (как в HomePage)
// ═══════════════════════════════════════════════════════════════════

class _PageAnimator extends StatefulWidget {
  const _PageAnimator({required this.child});
  final Widget child;

  @override
  State<_PageAnimator> createState() => _PageAnimatorState();
}

class _PageAnimatorState extends State<_PageAnimator>
    with SingleTickerProviderStateMixin {

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _anim.forward();
    });
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
