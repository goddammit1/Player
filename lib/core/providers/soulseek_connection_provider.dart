import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sources/soulseek_models.dart';
import '../../sources/soulseek_platform_channel.dart';

/// Единый источник статуса соединения Soulseek для UI (фильтр поиска,
/// страница настроек).
///
/// Значения:
///  - `AsyncData(null)` — Soulseek недоступен на платформе;
///  - `AsyncLoading` — статус ещё не известен (натив вернул UNKNOWN);
///  - `AsyncData(event)` — последний снимок или push-событие;
///  - `AsyncError` — ошибка потока событий.
///
/// Снимок — [SoulseekPlatformChannel.getConnectionState]: connection-события
/// приходят только при изменениях. Push-событие свежее снимка, поэтому
/// опоздавший ответ снимка его не перезаписывает. Подписка и запрос статуса
/// не поднимают мост.
final soulseekConnectionProvider =
    StreamProvider<SoulseekConnectionEvent?>((ref) {
  final channel = SoulseekPlatformChannel.instance;
  if (!channel.isAvailable) return Stream.value(null);

  final controller = StreamController<SoulseekConnectionEvent?>();
  var gotEvent = false;
  final sub = channel.connectionEvents.listen(
    (e) {
      gotEvent = true;
      controller.add(e);
    },
    onError: (Object e, StackTrace st) {
      if (!controller.isClosed) controller.addError(e, st);
    },
  );
  channel.getConnectionState().then(
    (state) {
      // null — натив не знает состояния: ждём push-события, не выдумывая
      // ложный DISCONNECTED (дефект №3).
      if (gotEvent || controller.isClosed || state == null) return;
      controller.add(SoulseekConnectionEvent(state: state));
    },
    onError: (Object _) {},
  );
  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });
  return controller.stream;
});

/// Soulseek доступен на платформе, но не подключён (включая «ещё не
/// известно» и промежуточные connecting / reconnecting) — поиск через него
/// сейчас не готов.
bool soulseekNotConnected(AsyncValue<SoulseekConnectionEvent?> connection) {
  if (!SoulseekPlatformChannel.instance.isAvailable) return false;
  if (!connection.hasValue) return true;
  final event = connection.value;
  return event != null && event.state != SoulseekConnectionState.connected;
}
