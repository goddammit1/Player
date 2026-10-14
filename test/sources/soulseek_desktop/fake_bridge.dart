import 'dart:async';
import 'dart:convert';

import 'package:player/sources/soulseek_desktop/soulseek_native_bridge.dart';

/// Мост без .NET: записывает вызовы, ответы задаёт [handler], события
/// шлются через [emit].
class FakeBridge implements SoulseekBridgeTransport {
  FakeBridge({Future<String?> Function(String method, String payload)? handler})
      : handler = handler ?? ((_, _) async => null);

  Future<String?> Function(String method, String payload) handler;

  final List<(String, String)> calls = [];
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  bool isInstalled = true;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<String?> call(String method, String payload) {
    calls.add((method, payload));
    return handler(method, payload);
  }

  void emit(Map<String, dynamic> event) => _events.add(event);

  Iterable<String> get methods => calls.map((c) => c.$1);

  Map<String, dynamic> lastPayload(String method) => jsonDecode(
      calls.lastWhere((c) => c.$1 == method).$2) as Map<String, dynamic>;

  /// downloadId последней попытки `startDownload` для [cacheKey] — с ним
  /// мост шлёт события (`dl_<key>#<attempt>`).
  String lastBridgeId(String cacheKey) => calls
      .where((c) => c.$1 == 'startDownload')
      .map((c) => jsonDecode(c.$2) as Map<String, dynamic>)
      .lastWhere((p) => p['cacheKey'] == cacheKey)['downloadId'] as String;
}
