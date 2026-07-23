import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';

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
            DateTime.fromMillisecondsSinceEpoch(m['played_at'] as int),
      );

  /// Идентичность записи для удаления из UI.
  bool sameAs(HistoryEntry other) =>
      other.track.globalId == track.globalId &&
      other.playedAt.millisecondsSinceEpoch ==
          playedAt.millisecondsSinceEpoch;
}

/// Persistence + state-store для истории прослушивания.
///
/// Хранилище — `SharedPreferences`, ключ `listen_history_v1` с
/// JSON-массивом записей (новые сверху). Паттерн полностью повторяет
/// [PlaylistRepository]: broadcast-стрим для UI + снапшот, запись на
/// диск дебаунсится 300 мс.
///
/// Лимит записей выбирается пользователем (ключ `history_limit_v1`),
/// абсолютный максимум — [maxLimit].
class HistoryRepository {
  HistoryRepository._();
  static final HistoryRepository instance = HistoryRepository._();

  static const String _key = 'listen_history_v1';
  static const String _limitKey = 'history_limit_v1';
  static const Duration _persistDebounce = Duration(milliseconds: 300);

  /// Абсолютный максимум записей.
  static const int maxLimit = 200;

  /// Дефолтный лимит, пока пользователь не выбрал свой.
  static const int defaultLimit = 100;

  final StreamController<List<HistoryEntry>> _controller =
      StreamController<List<HistoryEntry>>.broadcast();
  List<HistoryEntry> _list = [];
  int _limit = defaultLimit;
  SharedPreferences? _prefs;
  Future<void>? _initFuture;
  Timer? _persistTimer;

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

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    _limit = (_prefs!.getInt(_limitKey) ?? defaultLimit).clamp(1, maxLimit);
    final raw = _prefs!.getString(_key);
    if (raw == null || raw.isEmpty) {
      _list = [];
      _controller.add(_list);
      return;
    }
    try {
      final arr = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      _list = arr.map(HistoryEntry.fromJson).toList();
      _list.sort((a, b) => b.playedAt.compareTo(a.playedAt));
      // Миграция: чистим дубли одного трека из старых версий,
      // оставляем самую свежую запись.
      final seen = <Object>{};
      _list = _list.where((e) => seen.add(e.track.globalId)).toList();
      if (_list.length > _limit) {
        _list = _list.sublist(0, _limit);
      }
    } catch (_) {
      // Битый JSON лучше игнорировать, чем падать.
      _list = [];
    }
    _controller.add(List.unmodifiable(_list));
  }

  void _notifyAndSchedulePersist() {
    _controller.add(List.unmodifiable(_list));
    _persistTimer?.cancel();
    _persistTimer = Timer(_persistDebounce, _persistNow);
  }

  Future<void> _persistNow() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final raw = jsonEncode(_list.map((e) => e.toJson()).toList());
    await prefs.setString(_key, raw);
  }

  // ===== Mutations =====

  /// Добавляет трек в начало истории.
  ///
  /// Трек хранится в истории только один раз: при повторном прослушивании
  /// старая запись удаляется, а трек поднимается наверх со свежим `playedAt`.
  Future<void> add(Track track) async {
    await ensureLoaded();
    final now = DateTime.now();
    _list = [
      HistoryEntry(track: track, playedAt: now),
      ..._list.where((e) => e.track.globalId != track.globalId),
    ];
    if (_list.length > _limit) {
      _list = _list.sublist(0, _limit);
    }
    _notifyAndSchedulePersist();
  }

  /// Удаляет одну запись.
  Future<void> remove(HistoryEntry entry) async {
    await ensureLoaded();
    final n = _list.length;
    _list = _list.where((e) => !e.sameAs(entry)).toList();
    if (_list.length != n) _notifyAndSchedulePersist();
  }

  /// Полностью очищает историю.
  Future<void> clear() async {
    await ensureLoaded();
    if (_list.isEmpty) return;
    _list = [];
    _notifyAndSchedulePersist();
  }

  /// Меняет лимит записей. При уменьшении история сразу подрезается.
  Future<void> setLimit(int value) async {
    await ensureLoaded();
    final clamped = value.clamp(1, maxLimit);
    if (clamped == _limit) return;
    _limit = clamped;
    await _prefs?.setInt(_limitKey, clamped);
    if (_list.length > _limit) {
      _list = _list.sublist(0, _limit);
      _notifyAndSchedulePersist();
    } else {
      _controller.add(List.unmodifiable(_list));
    }
  }

  /// Принудительный flush на диск.
  Future<void> flush() async {
    _persistTimer?.cancel();
    await _persistNow();
  }
}
