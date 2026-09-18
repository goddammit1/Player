import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/track.dart';
import 'notifications/playlist_cache_notifier.dart';
import 'playlist_cache_service.dart';

sealed class PlaylistCacheRunState {
  const PlaylistCacheRunState();
}

class PlaylistCacheIdle extends PlaylistCacheRunState {
  const PlaylistCacheIdle();
}

class PlaylistCacheRunning extends PlaylistCacheRunState {
  const PlaylistCacheRunning(this.playlistName, this.progress);
  final String playlistName;
  final PlaylistCacheProgress progress;
}

class PlaylistCacheFinished extends PlaylistCacheRunState {
  const PlaylistCacheFinished(this.playlistName, this.result);
  final String playlistName;
  final PlaylistCacheResult result;
}

class PlaylistCacheController extends StateNotifier<PlaylistCacheRunState> {
  PlaylistCacheController({
    PlaylistCacheNotifier? notifier,
    PlaylistCacheService Function()? serviceFactory,
  })  : _notifier = notifier ?? createPlaylistCacheNotifier(),
        _serviceFactory = serviceFactory ?? PlaylistCacheService.new,
        super(const PlaylistCacheIdle()) {
    _notifier.init(onCancel: cancel);
  }

  final PlaylistCacheNotifier _notifier;
  final PlaylistCacheService Function() _serviceFactory;
  CancelToken? _cancelToken;
  bool _running = false;

  Future<bool> start(String playlistName, List<Track> tracks) async {
    if (_running) return false;
    if (Platform.isAndroid) {
      // Android 13+: a denied notification permission must not block caching.
      try {
        await Permission.notification.request();
      } catch (_) {
        // Some test/device configurations do not expose this permission.
      }
    }
    _running = true;
    final token = CancelToken();
    _cancelToken = token;
    final service = _serviceFactory();
    try {
      final result = await service.cacheTracks(
        List<Track>.of(tracks),
        cancelToken: token,
        onProgress: (progress) {
          state = PlaylistCacheRunning(playlistName, progress);
          _notifier.showProgress(progress, playlistName);
        },
      );
      state = PlaylistCacheFinished(playlistName, result);
      await _notifier.showResult(result, playlistName);
      return true;
    } catch (error, stack) {
      debugPrint('Playlist cache failed: $error\n$stack');
      return false;
    } finally {
      _cancelToken = null;
      _running = false;
    }
  }

  void cancel() => _cancelToken?.cancel();
}

final playlistCacheControllerProvider = StateNotifierProvider<PlaylistCacheController, PlaylistCacheRunState>((ref) {
  final controller = PlaylistCacheController();
  ref.onDispose(controller.dispose);
  return controller;
});
