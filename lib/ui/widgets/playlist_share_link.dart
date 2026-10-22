// lib/ui/widgets/playlist_share_link.dart
//
// «Share link»: загрузка снимка плейлиста на share-server и выдача короткой
// ссылки — share-sheet на мобильных, буфер обмена на десктопе.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/platform/haptic_helper.dart';
import '../../core/share/playlist_share_service.dart';
import '../../models/playlist.dart';
import '../desktop/desktop_layout.dart' show isDesktop;
import 'app_dialogs.dart';
import 'snack.dart';

Future<void> sharePlaylistLink(
  BuildContext context,
  WidgetRef ref,
  Playlist playlist,
) async {
  final Uri url;
  try {
    url = await runWithProgress(
      context,
      () => PlaylistShareService.instance.upload(playlist),
    );
  } catch (e) {
    if (!context.mounted) return;
    HapticHelper.error(ref: ref);
    showAppInfoDialog(
      context: context,
      title: 'Share failed',
      subtitle: e is PlaylistShareException ? e.message : e.toString(),
      okLabel: 'OK',
    );
    return;
  }

  HapticHelper.success(ref: ref);
  if (isDesktop) {
    // На Windows системное окно «Поделиться» неудобно — ссылку проще вставить.
    await Clipboard.setData(ClipboardData(text: url.toString()));
    if (context.mounted) showSuccessSnack(context, 'Link copied to clipboard');
    return;
  }
  await Share.share(url.toString(), subject: playlist.name);
}

/// Модальный спиннер на время [action]: сетевые операции шаринга занимают
/// секунду-другую, а повторный тап не должен запустить их второй раз.
Future<T> runWithProgress<T>(
  BuildContext context,
  Future<T> Function() action,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator()),
    ),
  );
  navigator.push(route);
  try {
    return await action();
  } finally {
    // Именно этот маршрут, а не верхний: поверх мог открыться другой.
    if (route.isActive) navigator.removeRoute(route);
  }
}
