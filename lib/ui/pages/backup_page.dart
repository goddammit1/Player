// lib/ui/pages/backup_page.dart
//
// Страница-раздел «Backup»: экспорт/импорт полного бэкапа всех данных
// приложения (плейлисты, история, настройки). Логика перенесена без
// изменений из модальной шторки settings_page.dart (FullBackup + FilePicker
// + перезагрузка репозиториев и инвалидация Riverpod-провайдеров).
// Открывается через Navigator.push из страницы настроек.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/history_repository.dart';
import '../../core/backup/playlist_backup.dart';
import '../../core/repositories/playlist_repository.dart';
import '../../core/providers.dart';
import '../desktop/desktop_layout.dart';
import '../widgets/now_playing_overlay.dart';
import '../widgets/snack.dart';

class BackupPage extends ConsumerWidget {
  const BackupPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(animatedPaletteProvider);

    return _BackupPageAnim(
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
                      'Backup',
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
                      top: 8,
                      bottom: 8 + NowPlayingOverlay.miniHeight +
                          MediaQuery.of(context).padding.bottom,
                    ),
                    children: [
                      ListTile(
                        leading: Icon(
                          Icons.file_upload_outlined,
                          color: colors.textPrimary,
                        ),
                        title: Text(
                          'Export everything',
                          style: TextStyle(color: colors.textPrimary),
                        ),
                        subtitle: Text(
                          'Save all data to a file',
                          style: TextStyle(color: colors.textSecondary),
                        ),
                        onTap: () async {
                          try {
                            await FullBackup.exportAndShare();
                            if (context.mounted) {
                              showSuccessSnack(context, 'Backup exported');
                            }
                          } catch (e) {
                            if (context.mounted) {
                              showErrorSnack(context, 'Export failed: $e');
                            }
                          }
                        },
                      ),
                      ListTile(
                        leading: Icon(
                          Icons.file_download_outlined,
                          color: colors.textPrimary,
                        ),
                        title: Text(
                          'Import everything',
                          style: TextStyle(color: colors.textPrimary),
                        ),
                        subtitle: Text(
                          'Restore all data from a file',
                          style: TextStyle(color: colors.textSecondary),
                        ),
                        onTap: () async {
                          try {
                            final result = await FilePicker.platform.pickFiles(
                              type: FileType.custom,
                              allowedExtensions: ['json'],
                            );
                            if (result == null || result.files.isEmpty) return;

                            final path = result.files.single.path;
                            if (path == null) return;

                            await FullBackup.importFromFile(path);
                            // Перечитываем все данные из БД после импорта,
                            // чтобы UI сразу отобразил актуальные значения без
                            // перезахода.
                            await PlaylistRepository.instance.reload();
                            await HistoryRepository.instance.reload();
                            await ref
                                .read(appThemeModeProvider.notifier)
                                .reload();
                            await ref
                                .read(historyLimitProvider.notifier)
                                .reload();
                            await ref
                                .read(vibrationEnabledProvider.notifier)
                                .reload();
                            await ref
                                .read(searchViewModeProvider.notifier)
                                .reload();
                            await ref
                                .read(searchHistoryProvider.notifier)
                                .reload();
                            // Инвалидируем Riverpod-провайдеры, чтобы они
                            // подхватили новые значения из репозиториев.
                            ref.invalidate(playlistsProvider);
                            ref.invalidate(listenHistoryProvider);
                            if (context.mounted) {
                              showSuccessSnack(
                                context,
                                'Data restored successfully',
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              showErrorSnack(context, 'Import failed: $e');
                            }
                          }
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
//  SHARED ANIMATOR (по образцу остальных страниц)
// =====================================================================

class _BackupPageAnim extends StatefulWidget {
  const _BackupPageAnim({required this.child});
  final Widget child;

  @override
  State<_BackupPageAnim> createState() => _BackupPageAnimState();
}

class _BackupPageAnimState extends State<_BackupPageAnim>
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