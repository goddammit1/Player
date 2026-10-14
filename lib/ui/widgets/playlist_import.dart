// lib/ui/widgets/playlist_import.dart
//
// Импорт плейлиста из JSON-файла (выбор файла → PlaylistBackup →
// диалог с результатом). Общий для меню «+» на мобильной главной и
// контекстного меню карточки «new playlist» на десктопе.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backup/playlist_backup.dart';
import '../../core/platform/haptic_helper.dart';
import 'app_dialogs.dart';

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
