// lib/sources/soulseek_queue_watch.dart
//
// Когда ручной загрузке Soulseek пора уйти к другому пиру.
//
// Пир, у которого файл стоит в очереди («Queued at peer»), ничего не
// обещает: очередь может двигаться, стоять (слоты заняты чужими долгими
// загрузками, раздача только для привилегированных), а сам пир — уйти из
// сети. Мост раз в минуту спрашивает место в очереди
// ([SoulseekTransferInfo.placeInQueue] / [SoulseekTransferInfo.queueStatus]);
// по этим ответам и времени ожидания [SoulseekQueueWatch] решает, ждать ли
// дальше. Сам переход (есть ли другой пир, отмена старой загрузки) — в
// SoulseekSource.

import 'soulseek_models.dart';

/// Почему загрузка уходит к другому пиру.
enum SoulseekSwitchReason {
  /// Сервер дважды подряд ответил, что пир не в сети.
  peerOffline,

  /// С пиром не удаётся соединиться несколько опросов подряд.
  peerUnreachable,

  /// Пир ни разу не ответил на запрос места, а ждём уже долго.
  noReply,

  /// Место в очереди не меняется долго.
  queueStalled,

  /// Впереди слишком много файлов.
  queueTooLong,

  /// Ждём в очереди дольше общего предела.
  waitTooLong,

  /// Пир отказал или загрузка у него упала.
  failed,
}

/// Пороги [SoulseekQueueWatch]. Опрос очереди идёт раз в минуту, поэтому
/// «N опросов» ≈ N минут.
class SoulseekQueueLimits {
  const SoulseekQueueLimits({
    this.offlineChecks = 2,
    this.unreachableChecks = 3,
    this.noReplyAfter = const Duration(minutes: 5),
    this.stalledAfter = const Duration(minutes: 10),
    this.longQueuePlace = 20,
    this.maxWait = const Duration(minutes: 20),
  });

  /// Подряд «offline» — пир ушёл, файл не отдаст.
  final int offlineChecks;

  /// Подряд «unreachable» — пир в сети, но соединения с ним нет.
  final int unreachableChecks;

  /// Сколько ждать без единого ответа о месте в очереди (часть клиентов
  /// не отвечает никогда — поэтому не сразу).
  final Duration noReplyAfter;

  /// Сколько место может не меняться.
  final Duration stalledAfter;

  /// С какого места очередь считается слишком длинной.
  final int longQueuePlace;

  /// Общий предел ожидания в очереди пира.
  final Duration maxWait;
}

/// Наблюдение за одной загрузкой у одного пира: копит ответы об очереди и
/// выносит вердикт [verdict].
class SoulseekQueueWatch {
  SoulseekQueueWatch({
    this.limits = const SoulseekQueueLimits(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SoulseekQueueLimits limits;
  final DateTime Function() _clock;

  /// Первое попадание в очередь пира (за всё наблюдение — retry в той же
  /// очереди ожидание не обнуляет).
  DateTime? _queuedSince;

  /// Начало текущего захода в очередь (после паузы / retry — заново).
  DateTime? _stintStart;

  int? _place;
  DateTime? _placeSince;
  bool _replied = false;
  int _offlineInRow = 0;
  int _unreachableInRow = 0;
  bool _failed = false;

  /// Данные пошли — пир отдаёт файл, наблюдать больше нечего.
  bool _started = false;

  /// Байт на момент первого события (остаток `.part` прошлых попыток).
  int? _initialBytes;

  /// Пир отдаёт файл (или уже отдал): переключаться поздно.
  bool get started => _started;

  /// Последнее известное место в очереди (для логов).
  int? get place => _place;

  /// Учитывает событие загрузки.
  void observe(SoulseekTransferInfo info) {
    final now = _clock();
    final initial = _initialBytes ??= info.bytesReceived;
    // Состояние downloading само по себе не значит, что данные идут:
    // Android ставит его, как только загрузка заняла локальный слот, ещё
    // до запроса к пиру.
    if (info.bytesReceived > initial || info.bytesPerSecond > 0) {
      _started = true;
    }
    switch (info.state) {
      case SoulseekTransferState.queuedRemotely:
        _queuedSince ??= now;
        _stintStart ??= now;
        _observeQueue(info, now);
      case SoulseekTransferState.completed:
        _started = true;
      case SoulseekTransferState.failed:
        _failed = true;
      case SoulseekTransferState.paused:
      case SoulseekTransferState.cancelled:
        // Решение пользователя: ожидание не считаем.
        _queuedSince = null;
        _resetStint();
      case SoulseekTransferState.downloading:
      case SoulseekTransferState.prebuffered:
      case SoulseekTransferState.queued:
      case SoulseekTransferState.connecting:
      case SoulseekTransferState.searching:
      case SoulseekTransferState.idle:
        // Вышли из очереди пира (retry, переподключение) — заход в неё
        // начнётся заново; общее ожидание [_queuedSince] сохраняется.
        _resetStint();
    }
  }

  void _resetStint() {
    _stintStart = null;
    _place = null;
    _placeSince = null;
    _replied = false;
    _offlineInRow = 0;
    _unreachableInRow = 0;
  }

  void _observeQueue(SoulseekTransferInfo info, DateTime now) {
    switch (info.queueStatus) {
      case null:
        // Смена состояния без опроса.
        return;
      case SoulseekQueueStatus.ok:
        _replied = true;
        _offlineInRow = 0;
        _unreachableInRow = 0;
        final place = info.placeInQueue;
        if (place != _place) {
          _place = place;
          _placeSince = now;
        }
      case SoulseekQueueStatus.offline:
        _offlineInRow++;
        _unreachableInRow = 0;
      case SoulseekQueueStatus.unreachable:
        _unreachableInRow++;
        _offlineInRow = 0;
      case SoulseekQueueStatus.noResponse:
        _offlineInRow = 0;
        _unreachableInRow = 0;
    }
  }

  /// Пора ли уходить к другому пиру (null — ждём дальше).
  SoulseekSwitchReason? verdict() {
    // Упавшая загрузка уходит к другому пиру, даже если часть файла
    // пришла: его копия — другой файл кэша, качать её с нуля лучше, чем
    // остаться ни с чем.
    if (_failed) return SoulseekSwitchReason.failed;
    if (_started) return null;
    final stint = _stintStart;
    if (stint == null) return null;
    final now = _clock();

    if (_offlineInRow >= limits.offlineChecks) {
      return SoulseekSwitchReason.peerOffline;
    }
    if (_unreachableInRow >= limits.unreachableChecks) {
      return SoulseekSwitchReason.peerUnreachable;
    }
    final place = _place;
    if (place != null && place >= limits.longQueuePlace) {
      return SoulseekSwitchReason.queueTooLong;
    }
    final placeSince = _placeSince;
    if (place != null &&
        placeSince != null &&
        now.difference(placeSince) >= limits.stalledAfter) {
      return SoulseekSwitchReason.queueStalled;
    }
    if (!_replied && now.difference(stint) >= limits.noReplyAfter) {
      return SoulseekSwitchReason.noReply;
    }
    final since = _queuedSince;
    if (since != null && now.difference(since) >= limits.maxWait) {
      return SoulseekSwitchReason.waitTooLong;
    }
    return null;
  }
}
