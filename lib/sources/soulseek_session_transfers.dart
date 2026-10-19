// lib/sources/soulseek_session_transfers.dart
//
// Загрузки Soulseek, которые шли в текущей сессии приложения.
//
// Натив помнит трансферы дольше сессии: незавершённые загрузки прошлых
// запусков поднимаются из БД (PAUSED / FAILED), а Android-сервис может
// пережить закрытие UI. Страница Downloads показывает упавшие загрузки
// только из этой сессии — ошибки прошлых запусков исчезают сами (паузы
// остаются: их можно продолжить).
// Признак «из этой сессии» — по трансферу пришло событие после старта
// приложения (события шлются только при реальной активности).

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'soulseek_models.dart';
import 'soulseek_platform_channel.dart';

class SoulseekSessionTransfers {
  SoulseekSessionTransfers._();

  static final SoulseekSessionTransfers instance =
      SoulseekSessionTransfers._();

  final Set<String> _ids = {};
  StreamSubscription<SoulseekTransferEvent>? _sub;

  /// Подписка на transfer-события; вызывается один раз на старте
  /// приложения. Подписка не поднимает мост.
  void start([SoulseekPlatformChannel? channel]) {
    final c = channel ?? SoulseekPlatformChannel.instance;
    if (_sub != null || !c.isAvailable) return;
    _sub = c.transferEvents.listen(
      (e) => _ids.add(e.transfer.downloadId),
      onError: (_) {},
    );
  }

  /// Отметить трансфер: страница Downloads делает это сама по событиям,
  /// пока открыта (на случай, если трекер подписался позже).
  void add(String downloadId) => _ids.add(downloadId);

  bool contains(String downloadId) => _ids.contains(downloadId);

  @visibleForTesting
  void resetForTesting() {
    _sub?.cancel();
    _sub = null;
    _ids.clear();
  }
}
