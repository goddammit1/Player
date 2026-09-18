import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../playlist_cache_service.dart';

abstract interface class PlaylistCacheNotifier {
  Future<void> init({VoidCallback? onCancel});
  Future<void> showProgress(PlaylistCacheProgress progress, String playlistName);
  Future<void> showResult(PlaylistCacheResult result, String playlistName);
  void attachCancelAction(VoidCallback onCancel);
}

class NoopPlaylistCacheNotifier implements PlaylistCacheNotifier {
  const NoopPlaylistCacheNotifier();

  @override
  Future<void> init({VoidCallback? onCancel}) async {}

  @override
  Future<void> showProgress(PlaylistCacheProgress progress, String playlistName) async {}

  @override
  Future<void> showResult(PlaylistCacheResult result, String playlistName) async {}

  @override
  void attachCancelAction(VoidCallback onCancel) {}
}

class AndroidPlaylistCacheNotifier implements PlaylistCacheNotifier {
  AndroidPlaylistCacheNotifier({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const int notificationId = 4201;
  static const String cancelActionId = 'cancel_cache';
  final FlutterLocalNotificationsPlugin _plugin;
  DateTime? _lastUpdate;
  VoidCallback? _onCancel;

  @override
  Future<void> init({VoidCallback? onCancel}) async {
    _onCancel = onCancel;
    if (!Platform.isAndroid) return;
    const settings = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: settings),
      onDidReceiveNotificationResponse: (response) {
        if (response.actionId == cancelActionId) _onCancel?.call();
      },
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      'playlist_cache', 'Playlist caching',
      description: 'Progress of playlist caching',
      importance: Importance.low,
      playSound: false,
    ));
  }

  @override
  void attachCancelAction(VoidCallback onCancel) => _onCancel = onCancel;

  @override
  Future<void> showProgress(PlaylistCacheProgress progress, String playlistName) async {
    if (!Platform.isAndroid) return;
    final now = DateTime.now();
    if (_lastUpdate != null && now.difference(_lastUpdate!) < const Duration(milliseconds: 500)) return;
    _lastUpdate = now;
    final details = AndroidNotificationDetails(
      'playlist_cache', 'Playlist caching',
      channelDescription: 'Progress of playlist caching',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      showProgress: true,
      maxProgress: progress.total,
      progress: progress.completed,
      actions: const [AndroidNotificationAction(cancelActionId, 'Cancel')],
    );
    await _plugin.show(notificationId, 'Caching "$playlistName"', '${progress.completed} / ${progress.total} · ${progress.currentTitle}', NotificationDetails(android: details));
  }

  @override
  Future<void> showResult(PlaylistCacheResult result, String playlistName) async {
    if (!Platform.isAndroid) return;
    final status = result.cancelled ? 'Caching cancelled' : result.failed == 0 ? 'Playlist cached' : 'Caching finished with errors';
    final body = '${result.downloaded} downloaded, ${result.skippedCached} already cached${result.failed > 0 ? ', ${result.failed} failed' : ''}';
    await _plugin.show(notificationId, status, body, const NotificationDetails(android: AndroidNotificationDetails('playlist_cache', 'Playlist caching', importance: Importance.low, priority: Priority.low, onlyAlertOnce: true)));
  }
}

PlaylistCacheNotifier createPlaylistCacheNotifier() => Platform.isAndroid ? AndroidPlaylistCacheNotifier() : const NoopPlaylistCacheNotifier();
