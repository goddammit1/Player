// lib/ui/widgets/playlist_import.dart
//
// Импорт плейлиста из JSON-файла (выбор файла → PlaylistBackup →
// диалог с результатом) и по короткой ссылке (PlaylistShareService).
// Общий для меню «+» на мобильной главной и контекстного меню карточки
// «new playlist» на десктопе; импорт по ссылке — ещё и для deep links.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backup/playlist_backup.dart';
import '../../core/platform/haptic_helper.dart';
import '../../core/repositories/playlist_repository.dart';
import '../../core/share/playlist_share_service.dart';
import 'app_dialogs.dart';
import 'playlist_share_link.dart' show runWithProgress;
import 'snack.dart';

Future<void> importPlaylistFromFile(BuildContext context, WidgetRef ref) async {
  FilePickerResult? picked;
  try {
    picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: false,
    );
  } catch (e) {
    if (!context.mounted) return;
    HapticHelper.error(ref: ref);
    _showInfo(context, title: 'Import failed', body: e.toString());
    return;
  }

  final path = picked?.files.single.path;
  if (path == null) return; // отмена выбора

  if (!context.mounted) return;

  try {
    final result = await PlaylistBackup.importFromFile(path);
    if (!context.mounted) return;

    HapticHelper.success(ref: ref);
    _showInfo(
      context,
      title: 'Import complete',
      body: 'Added: ${result.added}',
    );
  } catch (e) {
    if (!context.mounted) return;

    HapticHelper.error(ref: ref);
    _showInfo(
      context,
      title: 'Import failed',
      body: e is FormatException ? e.message : e.toString(),
    );
  }
}

/// Импорт по короткой ссылке.
///
/// Без [link] спрашивает ссылку (подставляя её из буфера обмена, если там
/// ссылка на плейлист). С [link] — пришла по deep link: перед импортом
/// показываем, что именно добавится, чтобы чужая ссылка не создала
/// плейлист без ведома пользователя.
Future<void> importPlaylistFromLink(
  BuildContext context,
  WidgetRef? ref, {
  String? link,
}) async {
  final fromDeepLink = link != null;
  var input = link;
  if (input == null) {
    String? clip;
    try {
      clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      // Буфер недоступен — просто пустое поле.
    }
    if (!context.mounted) return;
    input = await showAppInputDialog(
      context: context,
      title: 'Import from link',
      subtitle: 'Paste a shared playlist link',
      initialValue: clip != null && PlaylistShareService.containsShareLink(clip)
          ? clip.trim()
          : null,
      hintText: 'https://…/p/…',
      confirmLabel: 'Import',
      keyboardType: TextInputType.url,
    );
  }
  if (input == null || input.trim().isEmpty || !context.mounted) return;

  try {
    final playlist = await runWithProgress(
      context,
      () => PlaylistShareService.instance.fetchFromLink(input!),
    );
    if (!context.mounted) return;

    if (fromDeepLink) {
      final count = playlist.tracks.length;
      final ok = await showAppConfirmDialog(
        context: context,
        title: 'Import playlist?',
        subtitle: '"${playlist.name}" · $count ${count == 1 ? 'track' : 'tracks'}',
        confirmLabel: 'Import',
      );
      if (ok != true || !context.mounted) return;
    }

    await PlaylistRepository.instance.importPlaylists([playlist]);
    if (!context.mounted) return;
    HapticHelper.success(ref: ref);
    showSuccessSnack(context, 'Playlist "${playlist.name}" added');
  } catch (e) {
    if (!context.mounted) return;
    HapticHelper.error(ref: ref);
    _showInfo(
      context,
      title: 'Import failed',
      body: e is PlaylistShareException ? e.message : e.toString(),
    );
  }
}

void _showInfo(
  BuildContext context, {
  required String title,
  required String body,
}) {
  showAppInfoDialog(
    context: context,
    title: title,
    subtitle: body,
    okLabel: 'OK',
  );
}
