// lib/ui/widgets/share_link_listener.dart
//
// Deep links на плейлисты (`playerapp://p/<id>`, позже https-ссылки на
// домен share-server): подписка на app_links и импорт через тот же диалог,
// что и «Import from link».

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/share/playlist_share_service.dart';
import 'playlist_import.dart';

/// Оборачивает домашний экран: его context лежит под корневым Navigator,
/// так что диалоги импорта открываются поверх любого текущего маршрута.
class ShareLinkListener extends ConsumerStatefulWidget {
  const ShareLinkListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ShareLinkListener> createState() => _ShareLinkListenerState();
}

class _ShareLinkListenerState extends ConsumerState<ShareLinkListener> {
  StreamSubscription<Uri>? _sub;

  /// Ссылки, пришедшие, пока открыт диалог предыдущей, обрабатываются по очереди.
  Future<void> _queue = Future.value();

  @override
  void initState() {
    super.initState();
    if (!PlaylistShareService.instance.isEnabled) return;
    // uriLinkStream отдаёт и ссылку холодного старта, и последующие.
    _sub = AppLinks().uriLinkStream.listen(
      _onLink,
      onError: (Object e) {
        if (kDebugMode) debugPrint('[ShareLinkListener] $e');
      },
    );
  }

  void _onLink(Uri uri) {
    final link = uri.toString();
    if (PlaylistShareService.parseId(link) == null) return;
    _queue = _queue
        .then((_) async {
          // При холодном старте ссылка приходит до первого кадра домашнего экрана.
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted) return;
          await importPlaylistFromLink(context, ref, link: link);
        })
        // Упавший Future в цепочке пропустил бы все следующие ссылки.
        .catchError((Object e) {
          if (kDebugMode) debugPrint('[ShareLinkListener] $e');
        });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
