// lib/ui/pages/settings_page.dart
//
// Экран настроек в тёмной теме:
//  - Header: кнопка «Назад» (chevron_left_rounded в круглом тёмно-сером
//    контейнере) слева + заголовок «Settings» (28px) в той же строке —
//    чтобы заголовок не «уплывал» за нижнюю границу тулбара.
//  - Список из 4 кликабельных разделов (ListTile), каждый ведёт на
//    ОТДЕЛЬНУЮ страницу через Navigator.push: Appearance, Cache, Backup,
//    About (шторки больше не используются).
//  - Мини-плеер (NowPlayingOverlay) закреплён внизу, как на остальных
//    страницах (скрыт на десктопе — там свою панель рисует
//    DesktopPlayerBar).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../widgets/back_button.dart';
import '../widgets/desktop_layout.dart';
import '../widgets/now_playing_overlay.dart';
import 'about_page.dart';
import 'appearance_page.dart';
import 'backup_page.dart';
import 'cache_page.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);

    return _PageAnimator(
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: colors.background,
            // ── Верхняя панель ──
            appBar: AppBar(
              backgroundColor: colors.background,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              toolbarHeight: 96,
              automaticallyImplyLeading: false,
              titleSpacing: 0,
              title: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: _PageHeader(colors: colors),
              ),
            ),
            // ── Список разделов ──
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
                      top: 8,
                      bottom: 8 + NowPlayingOverlay.miniHeight +
                          MediaQuery.of(context).padding.bottom,
                    ),
                    children: [
                      _SectionTile(
                        colors: colors,
                        icon: Icons.palette_outlined,
                        title: 'Appearance',
                        subtitle: 'Change theme, search mode, haptics',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const AppearancePage(),
                          ),
                        ),
                      ),
                      _SectionTile(
                        colors: colors,
                        icon: Icons.refresh_rounded,
                        title: 'Cache',
                        subtitle: 'Manage data for music, albums',
                        onTap: () => Navigator.of(
                          context,
                        ).push(MaterialPageRoute(builder: (_) => const CachePage())),
                      ),
                      _SectionTile(
                        colors: colors,
                        icon: Icons.storage_rounded,
                        title: 'Backup',
                        subtitle: 'Save your settings, playlists, history',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const BackupPage()),
                        ),
                      ),
                      _SectionTile(
                        colors: colors,
                        icon: Icons.info_outline_rounded,
                        title: 'About',
                        subtitle: 'App version, github, updates',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const AboutPage()),
                        ),
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
//  PAGE HEADER (кнопка «Назад» + заголовок в одну строку)
// =====================================================================

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Назад показываем только когда страница реально открыта
        // через Navigator.push (мобильные экраны, десктопные push из
        // настроек). Когда страница встроена как раздел десктопного shell
        // (DesktopShell → IndexedStack), она живёт на корневом маршруте, и
        // Navigator.pop оставил бы приложение с пустым Navigator'ом (тёмный
        // экран без UI) — поэтому кнопку прячем.
        if (Navigator.of(context).canPop()) ...[
          CircleBackButton(colors: colors),
          const SizedBox(width: 10),
        ],
        // Заголовок — крупный полужирный белый шрифт, выравнивание по
        // левому краю, на той же строке, что и кнопка (не под ней).
        Text(
          'Settings',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

// =====================================================================
//  SECTION TILE (кликабельный раздел настроек)
// =====================================================================

class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.colors,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final dynamic colors;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: colors.textPrimary),
      title: Text(
        title,
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: colors.textSecondary, fontSize: 14),
      ),
      trailing: Icon(Icons.chevron_right_rounded, color: colors.textTertiary),
      onTap: onTap,
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
