// lib/ui/pages/about_page.dart
//
// Страница-раздел «About»: версия приложения (PackageInfo) и проверка
// обновлений на GitHub (только на мобильных — на десктопе пункт не
// показывается, т.к. GitHub-релизы содержат APK). Логика перенесена без
// изменений из модальной шторки settings_page.dart.
// Открывается через Navigator.push из страницы настроек.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/providers.dart';
import '../widgets/back_button.dart';
import '../widgets/desktop_layout.dart';
import '../widgets/now_playing_overlay.dart';
import '../widgets/update_dialog.dart';

class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);

    return _AboutPageAnim(
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: colors.background,
            appBar: AppBar(
              backgroundColor: colors.background,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              toolbarHeight: 88,
              automaticallyImplyLeading: false,
              titleSpacing: 0,
              title: _PageHeader(title: 'About', colors: colors),
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
                      top: 8,
                      bottom: 8 + NowPlayingOverlay.miniHeight +
                          MediaQuery.of(context).padding.bottom,
                    ),
                    children: [
                      FutureBuilder<PackageInfo>(
                        future: PackageInfo.fromPlatform(),
                        builder: (context, snap) {
                          final v = snap.data?.version ?? '...';
                          final build = snap.data?.buildNumber ?? '';
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
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
                                  style: TextStyle(
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ),
                              // Проверка обновлений работает только на
                              // мобильных: GitHub-релизы содержат APK, а
                              // in-app установка доступна лишь на Android.
                              // На десктопе пункт бесполезен (и бросил бы
                              // UnsupportedError).
                              if (Platform.isAndroid || Platform.isIOS)
                                ListTile(
                                  leading: Icon(
                                    Icons.system_update_alt_rounded,
                                    color: colors.textPrimary,
                                  ),
                                  title: Text(
                                    'Check for updates',
                                    style: TextStyle(
                                      color: colors.textPrimary,
                                    ),
                                  ),
                                  subtitle: Text(
                                    'Latest release on GitHub',
                                    style: TextStyle(
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                  onTap: () =>
                                      showUpdateFlow(context, colors),
                                ),
                            ],
                          );
                        },
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
  const _PageHeader({required this.title, required this.colors});

  final String title;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (Navigator.of(context).canPop()) ...[
            CircleBackButton(colors: colors),
            const SizedBox(width: 10),
          ],
          Text(
            title,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
//  SHARED ANIMATOR (по образцу остальных страниц)
// =====================================================================

class _AboutPageAnim extends StatefulWidget {
  const _AboutPageAnim({required this.child});
  final Widget child;

  @override
  State<_AboutPageAnim> createState() => _AboutPageAnimState();
}

class _AboutPageAnimState extends State<_AboutPageAnim>
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