import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/providers.dart';
import 'cache_page.dart';
import '../widgets/update_dialog.dart';

// ═══════════════════════════════════════════════════════════════════
//  SETTINGS PAGE
// ═══════════════════════════════════════════════════════════════════

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

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
            icon: Icon(
              Icons.chevron_left_rounded,
              size: 28,
              color: colors.textPrimary,
            ),
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
          padding: EdgeInsets.only(
            top: 8,
            bottom: 8 + MediaQuery.of(context).padding.bottom,
          ),
          children: [
            _AppearanceSection(colors: colors),
            _SearchViewSection(colors: colors),
            _HistorySection(colors: colors),
            _HapticsSection(colors: colors),
            _CacheTile(colors: colors),
            _AboutSection(colors: colors),
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
      trailing: Icon(Icons.chevron_right_rounded, color: colors.textTertiary),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const CachePage())),
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
                color: isSelected ? colors.textPrimary : colors.textTertiary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? colors.textPrimary : colors.textTertiary,
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
//  SEARCH VIEW SECTION — NEW
// =====================================================================

class _SearchViewSection extends ConsumerWidget {
  const _SearchViewSection({required this.colors});
  final dynamic colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewMode = ref.watch(searchViewModeProvider);

    return _Section(
      title: 'Search',
      colors: colors,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'View mode',
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
                      child: _ViewModeOption(
                        label: 'Grid',
                        icon: Icons.grid_view_rounded,
                        isSelected: viewMode == SearchViewMode.grid,
                        onTap: () => ref
                            .read(searchViewModeProvider.notifier)
                            .setMode(SearchViewMode.grid),
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
                      child: _ViewModeOption(
                        label: 'List',
                        icon: Icons.view_list_rounded,
                        isSelected: viewMode == SearchViewMode.list,
                        onTap: () => ref
                            .read(searchViewModeProvider.notifier)
                            .setMode(SearchViewMode.list),
                        colors: colors,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                viewMode == SearchViewMode.grid
                    ? 'Large artwork tiles with color frames.'
                    : 'Compact list with small artwork.',
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

class _ViewModeOption extends StatelessWidget {
  const _ViewModeOption({
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
                color: isSelected ? colors.textPrimary : colors.textTertiary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? colors.textPrimary : colors.textTertiary,
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
//  HAPTICS SECTION
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
          leading: Icon(Icons.vibration_rounded, color: colors.textPrimary),
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
            onChanged: (v) =>
                ref.read(vibrationEnabledProvider.notifier).setEnabled(v),
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
//  HISTORY SECTION
// =====================================================================

class _HistorySection extends ConsumerWidget {
  const _HistorySection({required this.colors});
  final dynamic colors;

  static const _presets = [50, 100, 150, 200];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final limit = ref.watch(historyLimitProvider);

    return _Section(
      title: 'History',
      colors: colors,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Max entries',
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
                    for (var i = 0; i < _presets.length; i++) ...[
                      if (i > 0)
                        VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: colors.outline,
                          indent: 8,
                          endIndent: 8,
                        ),
                      Expanded(
                        child: _LimitOption(
                          value: _presets[i],
                          isSelected: limit == _presets[i],
                          onTap: () => ref
                              .read(historyLimitProvider.notifier)
                              .setLimit(_presets[i]),
                          colors: colors,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Keep up to $limit recently played tracks.',
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

class _LimitOption extends StatelessWidget {
  const _LimitOption({
    required this.value,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  final int value;
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
          child: Text(
            '$value',
            style: TextStyle(
              color: isSelected ? colors.textPrimary : colors.textTertiary,
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
//  ABOUT SECTION
// =====================================================================

class _AboutSection extends StatelessWidget {
  const _AboutSection({required this.colors});
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
          onTap: () => showUpdateFlow(context, colors),
        ),
      ],
    );
  }
}

// =====================================================================
//  SHARED WIDGETS
// =====================================================================

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    required this.colors,
  });
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
//  SHARED ANIMATOR
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
    _slide = Tween<double>(
      begin: 10,
      end: 0,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _fade = Tween<double>(
      begin: 0.7,
      end: 1,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
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
        child: Opacity(opacity: _fade.value, child: widget.child),
      ),
    );
  }
}
