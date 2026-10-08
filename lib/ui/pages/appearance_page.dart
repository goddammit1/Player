// lib/ui/pages/appearance_page.dart
//
// Страница-раздел «Appearance»: настройки внешнего вида (тема — одна из пяти
// AppThemeMode, режим поиска Grid/List, тактильная отдача). Открывается через
// Navigator.push из страницы настроек; внизу закреплён NowPlayingOverlay
// (скрыт на десктопе — там свою панель рисует DesktopPlayerBar).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../desktop/desktop_layout.dart';
import '../widgets/now_playing_overlay.dart';

class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);

    return _AppearingPageAnimator(
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: colors.background,
              appBar: AppBar(
                backgroundColor: colors.background,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                toolbarHeight: 132,                       // ← было 134
                automaticallyImplyLeading: false,
                titleSpacing: 0,
                title: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 64, 16, 8), // ← было 16,16,16,8
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (Navigator.of(context).canPop())
                        _CircleButton(
                          icon: Icons.chevron_left_rounded,
                          onTap: () => Navigator.of(context).maybePop(),
                          colors: colors,
                        ),
                      const SizedBox(height: 16),
                      Text(
                        'Appearance',
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 32,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 48), // ← добавить
                    ],
                  ),
                ),
              ),
            body: LayoutBuilder(
              builder: (context, c) => Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isDesktop ? 760 : double.infinity,
                    maxHeight: c.maxHeight,
                  ),
                  child: ListView(
                    padding: EdgeInsets.only(
                      top: 0,
                      bottom: 8 + NowPlayingOverlay.miniHeight +
                          MediaQuery.of(context).padding.bottom,
                    ),
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _AppearanceSection(colors: colors),
                          const SizedBox(height: 8),
                          _SearchViewSection(colors: colors),
                          const SizedBox(height: 8),
                          _HapticsSection(colors: colors),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (!isDesktop) const NowPlayingOverlay(),
        ],
      ),
    );
  }
}

// =====================================================================
//  APPEARANCE CONTENT (тема: Fixed / Classic / Perceptual / Mesh / Blur)
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
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: colors.elevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colors.outline, width: 1),
                ),
                child: Column(
                  children: [
                    for (final (i, option) in _themeOptions.indexed) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: colors.outline,
                          indent: 52,
                        ),
                      _ThemeOption(
                        option: option,
                        isSelected: mode == option.mode,
                        onTap: () => ref
                            .read(appThemeModeProvider.notifier)
                            .setMode(option.mode),
                        colors: colors,
                      ),
                    ],
                  ],
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

typedef _ThemeOptionData = ({
  AppThemeMode mode,
  String label,
  String description,
  IconData icon,
});

const List<_ThemeOptionData> _themeOptions = [
  (
    mode: AppThemeMode.fixed,
    label: 'Fixed',
    description: 'Default dark grey palette.',
    icon: Icons.palette_outlined,
  ),
  (
    mode: AppThemeMode.dynamic,
    label: 'Classic',
    description: 'Artwork colors, original algorithm.',
    icon: Icons.auto_awesome_outlined,
  ),
  (
    mode: AppThemeMode.perceptual,
    label: 'Perceptual',
    description: 'Artwork colors with even brightness and contrast.',
    icon: Icons.contrast_rounded,
  ),
  (
    mode: AppThemeMode.mesh,
    label: 'Mesh',
    description: 'Animated artwork color mesh behind the player.',
    icon: Icons.gradient_rounded,
  ),
  (
    mode: AppThemeMode.blur,
    label: 'Blur',
    description: 'Blurred artwork behind the player.',
    icon: Icons.blur_on_rounded,
  ),
];

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.option,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  final _ThemeOptionData option;
  final bool isSelected;
  final VoidCallback onTap;
  final dynamic colors;

  @override
  Widget build(BuildContext context) {
    final Color foreground =
        isSelected ? colors.textPrimary : colors.textSecondary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Icon(option.icon, size: 20, color: foreground),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 14,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      option.description,
                      style: TextStyle(
                        color: colors.textTertiary,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                Icons.check_rounded,
                size: 20,
                color: isSelected ? colors.textPrimary : Colors.transparent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =====================================================================
//  SEARCH VIEW SECTION (Grid / List)
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
                ? 'Haptic feedback on playback controls, progress bar and queue interactions.'
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

// =====================================================================
//  КРУГЛАЯ КНОПКА 60×60
// =====================================================================

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    required this.colors,
  });

  final IconData icon;
  final VoidCallback onTap;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.elevated,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 60,
          height: 60,
          child: Icon(icon, color: colors.textPrimary, size: 28),
        ),
      ),
    );
  }
}

// =====================================================================
//  SHARED ANIMATOR (по образцу остальных страниц)
// =====================================================================

class _AppearingPageAnimator extends StatefulWidget {
  const _AppearingPageAnimator({required this.child});
  final Widget child;

  @override
  State<_AppearingPageAnimator> createState() => _AppearingPageAnimatorState();
}

class _AppearingPageAnimatorState extends State<_AppearingPageAnimator>
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