import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/playlist.dart';
import 'database/app_database.dart';
import 'repositories/history_repository.dart';
import 'player_service_interface.dart';
import 'repositories/playlist_repository.dart';
export '../search/search.dart';
export '../search/search_settings.dart';
export 'providers/appearance_provider.dart';
export 'providers/playlist_sort_mode.dart';
export 'providers/dynamic_colors.dart';
export 'providers/global_theme_provider.dart';

/// PlayerService инициализируется в main.dart и пробрасывается сюда через
/// override. См. main.dart -> ProviderScope(overrides: [...]).
final playerServiceProvider = Provider<PlayerServiceInterface>((ref) {
  throw UnimplementedError('Override in ProviderScope');
});

/// Глобальный ключ Navigator'а приложения. Нужен виджетам, живущим ВЫШЕ
/// Navigator'а (DesktopPlayerBar в MaterialApp.builder), чтобы открывать
/// модальные шторки по корневому navigator'у.
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Поток всех пользовательских плейлистов. UI слушает через
/// `ref.watch(playlistsProvider)` и получает `AsyncValue<List<Playlist>>`.
final playlistsProvider = StreamProvider<List<Playlist>>((ref) async* {
  // Гарантируем, что данные подняты с диска до первого emit.
  try {
    await PlaylistRepository.instance.ensureLoaded();
  } catch (e) {
    // Перевыбрасываем ошибку, чтобы Riverpod перевёл AsyncValue в AsyncError.
    // UI должен обрабатывать это состояние (см. HomePage).
    throw PlaylistLoadException('Failed to load playlists: $e');
  }
  yield PlaylistRepository.instance.current;
  yield* PlaylistRepository.instance.stream;
});

/// Ошибка загрузки плейлистов.
class PlaylistLoadException implements Exception {
  const PlaylistLoadException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Ошибка загрузки истории.
class HistoryLoadException implements Exception {
  const HistoryLoadException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Удобный доступ к репозиторию из UI: для мутаций.
final playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  return PlaylistRepository.instance;
});

/// Поток истории прослушивания (новые сверху). UI слушает через
/// `ref.watch(listenHistoryProvider)` и получает `AsyncValue<List<HistoryEntry>>`.
final listenHistoryProvider = StreamProvider<List<HistoryEntry>>((ref) async* {
  try {
    await HistoryRepository.instance.ensureLoaded();
  } catch (e) {
    throw HistoryLoadException('Failed to load history: $e');
  }
  yield HistoryRepository.instance.current;
  yield* HistoryRepository.instance.stream;
});

/// Удобный доступ к репозиторию истории: для мутаций.
final historyRepositoryProvider = Provider<HistoryRepository>((ref) {
  return HistoryRepository.instance;
});

/// Лимит записей истории прослушивания. Persist живёт внутри
/// [HistoryRepository] (ключ `history_limit_v1`), максимум —
/// [HistoryRepository.maxLimit].
final historyLimitProvider = StateNotifierProvider<HistoryLimitNotifier, int>(
  (ref) => HistoryLimitNotifier(),
);

class HistoryLimitNotifier extends StateNotifier<int> {
  HistoryLimitNotifier() : super(HistoryRepository.defaultLimit) {
    _ready = _load();
  }

  /// Завершается после окончания инициализации (нужно в тестах для
  /// детерминизма вместо `Future.delayed(Duration.zero)`).
  @visibleForTesting
  Future<void> get ready => _ready;
  late final Future<void> _ready;

  Future<void> _load() async {
    await HistoryRepository.instance.ensureLoaded();
    state = HistoryRepository.instance.limit;
  }

  Future<void> setLimit(int value) async {
    await HistoryRepository.instance.setLimit(value);
    state = HistoryRepository.instance.limit;
  }

  /// Перечитывает значение из БД (нужно после импорта полного бэкапа).
  Future<void> reload() => _load();
}


final vibrationEnabledProvider = StateNotifierProvider<VibrationNotifier, bool>(
  (ref) => VibrationNotifier(),
);

class VibrationNotifier extends StateNotifier<bool> {
  static const _key = 'vibration_enabled';

  VibrationNotifier() : super(true) {
    _ready = _load();
  }

  /// Тестовый конструктор: инициализирует состояние [initial] БЕЗ чтения БД.
  /// Иначе в widget-тестах (FakeAsync-зона) lazy-read настройки
  /// 'vibration_enabled' через sqflite вешает тест PendingTimerException
  /// (HapticHelper.*(ref:) читает vibrationEnabledProvider при тапах).
  @visibleForTesting
  VibrationNotifier.seeded(super.initial) {
    _ready = Future<void>.value();
  }

  @visibleForTesting
  Future<void> get ready => _ready;
  late final Future<void> _ready;

  Future<void> _load() async {
    final raw = await AppDatabase.instance.getSetting(_key);
    state = raw != null
        ? (raw == 'true' || raw == '1')
        : true;
  }

  Future<void> setEnabled(bool enabled) async {
    await AppDatabase.instance.setSetting(_key, enabled.toString());
    state = enabled;
  }

  Future<void> toggle() => setEnabled(!state);

  /// Перечитывает значение из БД (нужно после импорта полного бэкапа).
  Future<void> reload() => _load();
}

