// lib/sources/soulseek_stream_audio_source.dart
//
// Стриминг Soulseek на мобилке: воспроизведение во время загрузки.
//
// C# bridge пишет файл последовательно в `<cacheKey>.part` и по завершении
// делает atomic rename в `<cacheKey>.<ext>`. Этот AudioSource отдаёт плееру
// (через локальный прокси just_audio) уже записанные байты `.part` и ждёт
// прироста файла, пока загрузка не завершится или не упадёт
// (см. [GrowingFileReader]).
//
// Открытый дескриптор переживает rename (Linux/Android), поэтому уже идущее
// чтение не прерывается; новые range-запросы после завершения читают
// финальный файл.

import 'package:just_audio/just_audio.dart';

import 'growing_file_reader.dart';
import 'playback_source.dart';
import 'soulseek_models.dart';

class SoulseekStreamAudioSource extends StreamAudioSource {
  /// Путь `.part`, который пишет нативная загрузка.
  final String partPath;

  /// Заявленный пиром размер файла: длина источника для плеера.
  final int totalBytes;

  final String contentType;

  /// Как часто проверять прирост файла, когда записанные байты кончились.
  final Duration pollInterval;

  /// Сколько ждать прироста файла, прежде чем считать загрузку зависшей.
  /// ExoPlayer рвёт соединение после 8 с без байтов и переподключается,
  /// сдаваясь примерно через 40 с без прогресса — дольше ждать бессмысленно,
  /// а брошенные читатели закрываются по этому таймауту.
  final Duration stallTimeout;

  final GrowingFileReader _reader;

  SoulseekStreamAudioSource({
    required this.partPath,
    required this.totalBytes,
    required this.contentType,
    required Future<String> completion,
    this.pollInterval = const Duration(milliseconds: 200),
    this.stallTimeout = const Duration(seconds: 45),
    super.tag,
  }) : _reader = GrowingFileReader(
          partPath: partPath,
          totalBytes: totalBytes,
          completion: completion,
          pollInterval: pollInterval,
          stallTimeout: stallTimeout,
          errorFactory: _soulseekError,
        );

  static Object _soulseekError(
    String code,
    String message, {
    bool retryable = false,
  }) =>
      SoulseekException(code, message, retryable: retryable);

  /// MIME-тип по расширению файла Soulseek.
  static String contentTypeFor(String extension) =>
      audioContentTypeFor(extension);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = start ?? 0;
    final to = end == null || end > totalBytes ? totalBytes : end;
    if (from < 0 || from > to) {
      throw RangeError.range(from, 0, to, 'start');
    }
    return StreamAudioResponse(
      sourceLength: totalBytes,
      contentLength: to - from,
      offset: from,
      contentType: contentType,
      stream: _reader.read(from, to),
    );
  }
}
