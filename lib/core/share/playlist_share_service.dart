import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../models/playlist.dart';
import 'playlist_share_codec.dart';

/// Ошибка шаринга с текстом, который можно показать пользователю.
class PlaylistShareException implements Exception {
  const PlaylistShareException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Короткие ссылки на плейлисты через собственный сервер `share-server/`.
///
/// Адрес сервера — `SHARE_BASE_URL` из `env.json` (`--dart-define-from-file`).
/// Пустой адрес — функция выключена, пункты меню скрыты ([isEnabled]).
class PlaylistShareService {
  PlaylistShareService({Dio? dio, String? baseUrl})
    : baseUrl = _trimSlash(baseUrl ?? _configuredBaseUrl),
      _dio = dio ?? _defaultDio();

  static const String _configuredBaseUrl = String.fromEnvironment(
    'SHARE_BASE_URL',
  );

  static PlaylistShareService _instance = PlaylistShareService();
  static PlaylistShareService get instance => _instance;

  @visibleForTesting
  static set instance(PlaylistShareService value) => _instance = value;

  /// Схема deep link (AndroidManifest.xml, страница `/p/:id` на сервере).
  static const String appScheme = 'playerapp';

  /// Лимит сервера на сжатое тело (`share-server/src/limits.ts`).
  static const int maxCompressedBytes = 2 * 1024 * 1024;

  static final RegExp _idPattern = RegExp(r'^[0-9A-Za-z]{10}$');
  static final RegExp _idInText = RegExp(
    '(?:$appScheme://p/|/p/)([0-9A-Za-z]{10})(?![0-9A-Za-z])',
  );

  final String baseUrl;
  final Dio _dio;

  bool get isEnabled => baseUrl.isNotEmpty;

  static Dio _defaultDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60),
      headers: const {'User-Agent': 'Player-Share'},
    ),
  );

  /// Загружает снимок плейлиста и возвращает ссылку на него.
  Future<Uri> upload(Playlist playlist) async {
    _ensureEnabled();
    if (playlist.tracks.isEmpty) {
      throw const PlaylistShareException(
        'Playlist is empty — nothing to share',
      );
    }
    // JSON + gzip большого плейлиста (до 20 000 треков) — сотни мс:
    // не в UI-изоляте, иначе замирает даже спиннер.
    final body = await _encodeOffThread(playlist);
    if (body.length > maxCompressedBytes) {
      throw const PlaylistShareException('Playlist is too large to share');
    }

    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '$baseUrl/api/p',
        data: body,
        options: Options(
          contentType: 'application/gzip',
          headers: {Headers.contentLengthHeader: body.length},
        ),
      );
      final url = res.data?['url'];
      final parsed = url is String ? Uri.tryParse(url) : null;
      if (parsed == null) {
        throw const PlaylistShareException(
          'Share server returned an invalid response',
        );
      }
      return parsed;
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  /// Скачивает снимок по id.
  Future<Playlist> fetch(String id) async {
    _ensureEnabled();
    try {
      final res = await _dio.get<List<int>>(
        '$baseUrl/api/p/$id',
        options: Options(responseType: ResponseType.bytes),
      );
      final data = res.data;
      if (data == null) {
        throw const PlaylistShareException(
          'Share server returned an empty response',
        );
      }
      return await _decodeOffThread(data);
    } on DioException catch (e) {
      throw _mapError(e);
    } on FormatException catch (e) {
      throw PlaylistShareException(e.message);
    }
  }

  /// [fetch] по ссылке: для подтверждения импорта («Import "X"?») до записи.
  Future<Playlist> fetchFromLink(String input) async {
    final id = parseId(input);
    if (id == null) {
      throw const PlaylistShareException('This is not a playlist link');
    }
    return fetch(id);
  }

  /// Есть ли в тексте ссылка на плейлист (не голый id): для подстановки из
  /// буфера обмена, где 10 букв подряд — скорее обычное слово.
  static bool containsShareLink(String text) => _idInText.hasMatch(text);

  /// id снимка из ссылки `https://<host>/p/<id>`, `playerapp://p/<id>`,
  /// голого id или текста, в котором есть такая ссылка. `null` — не найден.
  static String? parseId(String input) {
    final text = input.trim();
    if (_idPattern.hasMatch(text)) return text;
    return _idInText.firstMatch(text)?.group(1);
  }

  void _ensureEnabled() {
    if (!isEnabled) {
      throw const PlaylistShareException('Sharing by link is not configured');
    }
  }

  PlaylistShareException _mapError(DioException e) {
    final status = e.response?.statusCode;
    switch (status) {
      case 404:
        return const PlaylistShareException(
          'Playlist not found — the link may be broken',
        );
      case 413:
        return const PlaylistShareException('Playlist is too large to share');
      case 429:
        return const PlaylistShareException(
          'Too many shares — try again in a minute',
        );
    }
    if (status != null) {
      final body = e.response?.data;
      final message = body is Map ? body['error'] : null;
      return PlaylistShareException(
        message is String
            ? 'Share server error: $message'
            : 'Share server error ($status)',
      );
    }
    if (kDebugMode) debugPrint('[PlaylistShare] ${e.type}: ${e.message}');
    return const PlaylistShareException('Could not reach the share server');
  }

  // Статические: замыкание в методе экземпляра может захватить `this`
  // вместе с Dio, который нельзя передать в другой изолят.
  static Future<Uint8List> _encodeOffThread(Playlist playlist) =>
      Isolate.run(() => PlaylistShareCodec.encode(playlist));

  static Future<Playlist> _decodeOffThread(List<int> bytes) =>
      Isolate.run(() => PlaylistShareCodec.decode(bytes));

  static String _trimSlash(String url) =>
      url.trim().replaceAll(RegExp(r'/+$'), '');
}
