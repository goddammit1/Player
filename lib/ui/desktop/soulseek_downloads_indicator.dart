// lib/ui/desktop/soulseek_downloads_indicator.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../sources/soulseek_desktop/soulseek_desktop_channel.dart';
import '../../sources/soulseek_models.dart';
import '../../sources/soulseek_platform_channel.dart';
import '../widgets/snack.dart';
import '../widgets/soulseek_transfer_sheet.dart';
import 'design/dimens.dart';

/// Круглая кнопка в top bar: активные загрузки Soulseek (кольцо общего
/// прогресса и счётчик). Скрыта, пока загрузок нет; клик — список загрузок.
/// Заодно сообщает об отключении из-за входа тем же ником с другого
/// устройства — такой обрыв не переподключается автоматически.
class SoulseekDownloadsIndicator extends ConsumerStatefulWidget {
  const SoulseekDownloadsIndicator({super.key, this.channel});

  /// Канал (тесты); по умолчанию — платформенный.
  final SoulseekPlatformChannel? channel;

  @override
  ConsumerState<SoulseekDownloadsIndicator> createState() =>
      _SoulseekDownloadsIndicatorState();
}

class _SoulseekDownloadsIndicatorState
    extends ConsumerState<SoulseekDownloadsIndicator> {
  final Map<String, SoulseekTransferInfo> _active = {};
  StreamSubscription<SoulseekTransferEvent>? _sub;
  StreamSubscription<SoulseekConnectionEvent>? _connectionSub;
  String? _lastConnectionMessage;

  SoulseekPlatformChannel get _channel =>
      widget.channel ?? SoulseekPlatformChannel.instance;

  @override
  void initState() {
    super.initState();
    // Подписка не поднимает мост: события идут, только когда Soulseek
    // уже используется.
    if (_channel.isAvailable) {
      _sub = _channel.transferEvents.listen(_onEvent);
      _connectionSub = _channel.connectionEvents.listen(_onConnection);
    }
  }

  void _onConnection(SoulseekConnectionEvent e) {
    final message = e.message;
    if (message == DesktopSoulseekChannel.kickedMessage &&
        _lastConnectionMessage != message &&
        mounted) {
      showSnack(context, message!);
    }
    _lastConnectionMessage = message;
  }

  void _onEvent(SoulseekTransferEvent e) {
    final info = e.transfer;
    final wasActive = _active.containsKey(info.downloadId);
    if (info.state.isActive) {
      _active[info.downloadId] = info;
    } else {
      _active.remove(info.downloadId);
    }
    if (wasActive || info.state.isActive) setState(() {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _connectionSub?.cancel();
    super.dispose();
  }

  double? get _progress {
    var received = 0;
    var total = 0;
    for (final t in _active.values) {
      if (t.totalBytes <= 0) return null;
      received += t.bytesReceived;
      total += t.totalBytes;
    }
    return total == 0 ? null : (received / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    if (_active.isEmpty) return const SizedBox.shrink();
    final colors = ref.watch(animatedPaletteProvider);
    final count = _active.length;
    return Padding(
      padding: const EdgeInsets.only(left: Dimens.gap),
      child: Tooltip(
        message: count == 1 ? '1 Soulseek download' : '$count Soulseek downloads',
        child: Material(
          key: const Key('soulseek_downloads_indicator'),
          color: colors.elevated,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => showSoulseekTransferSheet(context),
            child: SizedBox.square(
              dimension: Dimens.topBarHeight,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.square(
                    dimension: 40,
                    child: CircularProgressIndicator(
                      value: _progress,
                      strokeWidth: 2.5,
                      color: colors.textPrimary,
                      backgroundColor: colors.outline,
                    ),
                  ),
                  Icon(Icons.download_rounded,
                      color: colors.textPrimary, size: 20),
                  if (count > 1)
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: colors.elevatedHi,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$count',
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
