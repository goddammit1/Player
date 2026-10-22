// lib/ui/widgets/song_recognition_listener.dart
//
// Распознавание песен живёт в нативной части (плитка в шторке →
// SongRecognitionService.kt), а «Find in Player» в уведомлении о результате
// открывает приложение с запросом. Здесь он превращается в обычный поиск.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../pages/search_page.dart';

/// Оборачивает домашний экран: его context лежит под корневым Navigator,
/// так что поиск открывается поверх любого текущего маршрута.
class SongRecognitionListener extends ConsumerStatefulWidget {
  const SongRecognitionListener({
    super.key,
    required this.child,
    @visibleForTesting this.enabled,
    @visibleForTesting this.onSearch,
  });

  final Widget child;

  /// Слушать ли канал; по умолчанию — только на Android.
  final bool? enabled;

  /// Подмена открытия поиска в тестах (по умолчанию — SearchPage).
  final void Function(String query)? onSearch;

  @override
  ConsumerState<SongRecognitionListener> createState() =>
      _SongRecognitionListenerState();
}

class _SongRecognitionListenerState
    extends ConsumerState<SongRecognitionListener> {
  static const _channel = MethodChannel('player/song_recognition');

  bool get _enabled => widget.enabled ?? Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    if (!_enabled) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'search') _openSearch(call.arguments as String);
    });
    // Холодный старт из уведомления: запрос ждёт в MainActivity.
    _channel
        .invokeMethod<String>('takePendingSearch')
        .then((query) {
          if (query != null) _openSearch(query);
        })
        .catchError((Object e) {
          if (kDebugMode) debugPrint('[SongRecognition] $e');
        });
  }

  Future<void> _openSearch(String query) async {
    // При холодном старте запрос приходит до первого кадра домашнего экрана.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (widget.onSearch case final onSearch?) {
      onSearch(query);
      return;
    }
    final navigator = Navigator.of(context);
    navigator.popUntil((route) => route.isFirst);
    ref.read(searchHistoryProvider.notifier).add(query);
    unawaited(ref.read(searchProvider.notifier).search(query));
    navigator.push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const SearchPage(),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  @override
  void dispose() {
    if (_enabled) _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
