import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import 'app_database.dart';

/// Одна запись истории прослушивания: трек + момент воспроизведения.
class HistoryEntry {
  final Track track;
  final DateTime playedAt;

  const HistoryEntry({required this.track, required this.playedAt});

  Map<String, dynamic> toJson() => {
        'track': track.toMap(),
        'played_at': playedAt.millisecondsSinceEpoch,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> m) => HistoryEntry(
        track: Track.fromMap((m['track'] as Map).cast<String, dynamic>()),
        playedAt:
            DateTime.fromMillisecondsSinceEpoch((m['played_at'] as num).toInt()),
      );

  /// Идентичность записи для удаления из UI.
  bool sameAs(HistoryEntry other) =>
      other.track.globalId == track.globalId &&
      other.playedAt.millisecondsSinceEpoch ==
          playedAt.millisecondsSinceEpoch;
}

/// Persistence + state-store для истории прослушивания.
///
/// Хранилище — SQLite через [AppDatabase]. Паттерн полностью повторяет
/// [PlaylistRepository]: broadcast-стрим для UI + снапшот, запись на
/// диск дебаунсится 300 мс.
///
/// Лимит записей выбирается пользователем (хранится в таблице `settings`
/// под ключом `history_limit_v1`), абсолютный максимум — [maxLimit].
class HistoryRepository {
  HistoryRepository._();
  static final HistoryRepository instance = HistoryRepository._();

  /// Абсолютный максимум записей.
  static const int maxLimit = 200;

  /// Дефолтный лимит, пока пользователь не выбрал свой.
  static const int defaultLimit = 100;

  final StreamController<List<HistoryEntry>> _controller =
      StreamController<List<HistoryEntry>>.broadcast();
  List<HistoryEntry> _list = [];
  int _limit = defaultLimit;
  Future<void>? _initFuture;

  /// Поток записей истории, новые сверху.
  Stream<List<HistoryEntry>> get stream => _controller.stream;

  /// Текущий снимок. Безопасно читать после `ensureLoaded()`.
  List<HistoryEntry> get current => List.unmodifiable(_list);

  /// Текущий лимит записей (1..[maxLimit]).
  int get limit => _limit;

  Future<void> ensureLoaded() {
    _initFuture ??= _load();
    return _initFuture!;
  }

  /// Сбрасывает кэш и перезагружает историю из БД.
  /// Вызывается после импорта полного бэкапа, чтобы UI отразил новые данные.
  Future<void> reload() async {
    _initFuture = null;
    await _load();
  }

  Future<void> _load() async {
    // Читаем лимит из SQLite settings.
    final rawLimit = await AppDatabase.instance.getSetting('history_limit_v1');
    _limit = int.tryParse(rawLimit ?? '') ?? defaultLimit;
    _limit = _limit.clamp(1, maxLimit);

    // Загружаем историю из БД.
    try {
      _list = await AppDatabase.instance.loadListenHistory(_limit);
    } catch (_) {
      _list = [];
    }
    _controller.add(List.unmodifiable(_list));
  }

  // _notifyAndSchedulePersist и _persistNow удалены — история пишется
  // атомарно через AppDatabase на каждую мутацию, debounce не нужен.

  // ===== Mutations =====

  /// Добавляет трек в начало истории.
  ///
  /// Трек хранится в истории только один раз: при повторном прослушивании
  /// старая запись удаляется, а трек поднимается наверх со свежим `playedAt`.
  ///
  /// Операция идемпотентна и транзакционна на уровне БД: сначала пишем в БД,
  /// потом обновляем in-memory список. Если БД упадёт — память останется
  /// консистентной (изменения не применятся).
  Future<void> add(Track track) async {
    await ensureLoaded();
    final now = DateTime.now();
    final entry = HistoryEntry(track: track, playedAt: now);

    // Сначала атомарная запись в БД (DELETE + INSERT в одной транзакции).
    try {
      await AppDatabase.instance.addListenHistoryEntry(entry);
      await AppDatabase.instance.trimListenHistory(_limit);
    } catch (e, st) {
      debugPrint(
          '[HistoryRepository] Failed to persist history entry: $e\n$st');
      return; // Не обновляем память, если БД не приняла запись.
    }

    // Только после успешной записи обновляем in-memory список.
    _list = [
      entry,
      ..._list.where((e) => e.track.globalId != track.globalId),
    ];
    if (_list.length > _limit) {
      _list = _list.sublist(0, _limit);
    }

    _controller.add(List.unmodifiable(_list));
  }

  /// Удаляет одну запись.
  Future<void> remove(HistoryEntry entry) async {
    await ensureLoaded();
    final n = _list.length;
    _list = _list.where((e) => !e.sameAs(entry)).toList();
    if (_list.length != n) {
      await AppDatabase.instance.removeListenHistoryEntry(entry);
      _controller.add(List.unmodifiable(_list));
    }
  }

  /// Полностью очищает историю.
  Future<void> clear() async {
    await ensureLoaded();
    if (_list.isEmpty) return;
    _list = [];
    await AppDatabase.instance.clearListenHistory();
    _controller.add(List.unmodifiable(_list));
  }

  /// Меняет лимит записей. При уменьшении история сразу подрезается.
  Future<void> setLimit(int value) async {
    await ensureLoaded();
    final clamped = value.clamp(1, maxLimit);
    if (clamped == _limit) return;
    _limit = clamped;
    await AppDatabase.instance.setSetting('history_limit_v1', clamped.toString());
    if (_list.length > _limit) {
      _list = _list.sublist(0, _limit);
      await AppDatabase.instance.trimListenHistory(_limit);
      _controller.add(List.unmodifiable(_list));
    } else {
      _controller.add(List.unmodifiable(_list));
    }
  }

  /// Принудительный flush на диск (не нужен — все мутации атомарны).
  Future<void> flush() async {
    // no-op: все мутации атомарны.
  }
}