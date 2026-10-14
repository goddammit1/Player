// lib/sources/soulseek_desktop/soulseek_native_bridge.dart
//
// Мост Soulseek на Windows: .NET-библиотека (soulseek-wrapper/desktop) внутри
// процесса player.exe.
//
// CoreCLR поднимается лениво, при первом обращении к Soulseek: из фонового
// изолята загружается `soulseek/hostfxr.dll`, runtime инициализируется как
// self-contained приложение (`hostfxr_initialize_for_dotnet_command_line`), и
// через `hdt_get_function_pointer` берутся указатели на
// `[UnmanagedCallersOnly]`-экспорты `NativeExports`. Блокирующих FFI-вызовов на
// UI-изоляте нет: Init/Call/Free возвращают сразу.
//
// Ответы и события приходят одним колбэком `(requestId, utf8Json)` из потоков
// .NET — это `NativeCallable.listener`, безопасный для вызова из любого потока.
// Строку выделяет мост, Dart копирует её и освобождает через `Free`.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../soulseek_models.dart';

/// Транспорт до моста: вызов метода (ответ — ResultDto JSON) и события.
///
/// Выделен для тестов: [DesktopSoulseekChannel] и менеджер трансферов
/// работают с фейковой реализацией без .NET.
abstract class SoulseekBridgeTransport {
  /// Мост установлен рядом с приложением (Soulseek доступен на этой машине).
  bool get isInstalled;

  /// Вызывает [method] моста; возвращает разобранный ResultDto `data`
  /// (JSON-строка или null). Ошибка моста → [SoulseekException].
  Future<String?> call(String method, String payload);

  /// События моста (SoulseekEventDto как Map).
  Stream<Map<String, dynamic>> get events;
}

/// Реальный мост: CoreCLR внутри процесса.
class SoulseekNativeBridge implements SoulseekBridgeTransport {
  SoulseekNativeBridge({String? directory})
      : directory = directory ?? defaultDirectory;

  /// Каталог моста по умолчанию: `soulseek/` рядом с player.exe.
  static String get defaultDirectory =>
      p.join(p.dirname(Platform.resolvedExecutable), 'soulseek');

  static const String _assembly = 'soulseek-desktop';

  final String directory;

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  final Map<int, Completer<String>> _pending = {};
  int _nextRequestId = 1;

  Future<_BridgeFunctions>? _starting;
  _BridgeFunctions? _fns;

  @override
  bool get isInstalled =>
      Platform.isWindows &&
      File(p.join(directory, '$_assembly.dll')).existsSync() &&
      File(p.join(directory, 'hostfxr.dll')).existsSync();

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<String?> call(String method, String payload) async {
    final fns = await _ensureStarted();
    final id = _nextRequestId++;
    final completer = Completer<String>();
    _pending[id] = completer;
    final methodPtr = method.toNativeUtf8();
    final payloadPtr = payload.toNativeUtf8();
    try {
      fns.call(id, methodPtr, payloadPtr);
    } finally {
      // Мост копирует строки до возврата из Call.
      calloc.free(methodPtr);
      calloc.free(payloadPtr);
    }
    return _parseResult(await completer.future);
  }

  /// Освобождает клиент Soulseek (сокеты, загрузки). Runtime остаётся в
  /// процессе — CoreCLR нельзя выгрузить.
  void shutdown() => _fns?.shutdown();

  Future<_BridgeFunctions> _ensureStarted() {
    return _starting ??= _start().catchError((Object e) {
      _starting = null;
      throw e;
    });
  }

  Future<_BridgeFunctions> _start() async {
    if (!isInstalled) {
      throw const SoulseekException(
        'BRIDGE_NOT_INSTALLED',
        'Soulseek bridge is not installed next to the application',
      );
    }
    final sw = Stopwatch()..start();
    final addresses = await _hostInIsolate(directory);
    final fns = _BridgeFunctions.fromAddresses(addresses);
    // Колбэк может прийти до возврата из Init: строки освобождаются через _fns.
    _fns = fns;

    // Живёт до конца процесса: мост вызывает его из своих потоков.
    final callback = NativeCallable<_CallbackNative>.listener(_onNative);
    final rc = fns.init(callback.nativeFunction);
    if (rc != 0) {
      callback.close();
      _fns = null;
      throw SoulseekException('BRIDGE_INIT_FAILED', 'Bridge Init returned $rc');
    }
    if (kDebugMode) {
      debugPrint('[Soulseek] .NET bridge started in ${sw.elapsedMilliseconds} ms');
    }
    return fns;
  }

  /// Статический и не async: замыкание [Isolate.run] захватывает только
  /// [dir]. Замыкание внутри метода экземпляра захватило бы `this`, а с ним
  /// контроллер событий и подписчиков — их нельзя отправить в изолят.
  static Future<List<int>> _hostInIsolate(String dir) =>
      Isolate.run(() => _host(dir));

  void _onNative(int requestId, Pointer<Uint8> ptr) {
    String json;
    try {
      json = ptr.cast<Utf8>().toDartString();
    } finally {
      _fns?.free(ptr);
    }
    if (requestId != 0) {
      _pending.remove(requestId)?.complete(json);
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    if (decoded['eventType'] == 'log') {
      if (kDebugMode) debugPrint('[SoulseekBridge] ${decoded['message']}');
      return;
    }
    _events.add(decoded);
  }

  static String? _parseResult(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map) {
      throw const SoulseekException('MALFORMED_RESPONSE', 'Bridge returned malformed JSON');
    }
    if (decoded['success'] == true) return decoded['data'] as String?;
    throw SoulseekException(
      (decoded['errorCode'] as String?) ?? 'BRIDGE_ERROR',
      (decoded['errorMessage'] as String?) ?? 'Unknown bridge error',
      retryable: decoded['retryable'] == true,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Хостинг CoreCLR (выполняется в фоновом изоляте)
// ═══════════════════════════════════════════════════════════════════════

typedef _CallbackNative = Void Function(Int64, Pointer<Uint8>);
typedef _InitNative = Int32 Function(Pointer<NativeFunction<_CallbackNative>>);
typedef _InitDart = int Function(Pointer<NativeFunction<_CallbackNative>>);
typedef _CallNative = Void Function(Int64, Pointer<Utf8>, Pointer<Utf8>);
typedef _CallDart = void Function(int, Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);
typedef _ShutdownNative = Void Function();
typedef _ShutdownDart = void Function();

class _BridgeFunctions {
  _BridgeFunctions._(this.init, this.call, this.free, this.shutdown);

  factory _BridgeFunctions.fromAddresses(List<int> a) => _BridgeFunctions._(
        Pointer<NativeFunction<_InitNative>>.fromAddress(a[0]).asFunction<_InitDart>(),
        Pointer<NativeFunction<_CallNative>>.fromAddress(a[1]).asFunction<_CallDart>(),
        Pointer<NativeFunction<_FreeNative>>.fromAddress(a[2]).asFunction<_FreeDart>(),
        Pointer<NativeFunction<_ShutdownNative>>.fromAddress(a[3]).asFunction<_ShutdownDart>(),
      );

  final _InitDart init;
  final _CallDart call;
  final _FreeDart free;
  final _ShutdownDart shutdown;
}

final class _HostfxrInitParams extends Struct {
  @Size()
  external int size;
  external Pointer<Utf16> hostPath;
  external Pointer<Utf16> dotnetRoot;
}

typedef _InitCmdNative = Int32 Function(
    Int32, Pointer<Pointer<Utf16>>, Pointer<_HostfxrInitParams>, Pointer<Pointer<Void>>);
typedef _InitCmdDart = int Function(
    int, Pointer<Pointer<Utf16>>, Pointer<_HostfxrInitParams>, Pointer<Pointer<Void>>);
typedef _GetDelegateNative = Int32 Function(Pointer<Void>, Int32, Pointer<Pointer<Void>>);
typedef _GetDelegateDart = int Function(Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _GetFunctionPointerNative = Int32 Function(Pointer<Utf16>, Pointer<Utf16>,
    Pointer<Utf16>, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _GetFunctionPointerDart = int Function(Pointer<Utf16>, Pointer<Utf16>,
    Pointer<Utf16>, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);

/// hostfxr_delegate_type.hdt_get_function_pointer.
const int _hdtGetFunctionPointer = 6;

/// Имя переменной окружения процесса с адресами экспортов. CoreCLR нельзя
/// инициализировать в процессе повторно, а после hot restart (debug) Dart
/// начинает с чистого состояния — адреса берутся отсюда.
const String _addressesEnv = 'PLAYER_SOULSEEK_BRIDGE';

typedef _GetEnvNative = Uint32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _GetEnvDart = int Function(Pointer<Utf16>, Pointer<Utf16>, int);
typedef _SetEnvNative = Int32 Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _SetEnvDart = int Function(Pointer<Utf16>, Pointer<Utf16>);

/// Поднимает runtime и возвращает адреса Init/Call/Free/Shutdown.
List<int> _host(String dir) {
  return using((arena) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getEnv = kernel32
        .lookupFunction<_GetEnvNative, _GetEnvDart>('GetEnvironmentVariableW');
    final setEnv = kernel32
        .lookupFunction<_SetEnvNative, _SetEnvDart>('SetEnvironmentVariableW');
    final envName = _addressesEnv.toNativeUtf16(allocator: arena);
    final buffer = arena<Uint16>(256).cast<Utf16>();
    final length = getEnv(envName, buffer, 256);
    if (length > 0 && length < 256) {
      final cached = buffer.toDartString().split(',').map(int.parse).toList();
      if (cached.length == 4) return cached;
    }

    final fxr = DynamicLibrary.open(p.join(dir, 'hostfxr.dll'));
    final initialize = fxr.lookupFunction<_InitCmdNative, _InitCmdDart>(
        'hostfxr_initialize_for_dotnet_command_line');
    final getDelegate = fxr.lookupFunction<_GetDelegateNative, _GetDelegateDart>(
        'hostfxr_get_runtime_delegate');
    final close = fxr.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('hostfxr_close');

    final argv = arena<Pointer<Utf16>>(1);
    argv[0] = p.join(dir, '${SoulseekNativeBridge._assembly}.dll').toNativeUtf16(allocator: arena);
    final params = arena<_HostfxrInitParams>()
      ..ref.size = sizeOf<_HostfxrInitParams>()
      ..ref.hostPath = p
          .join(dir, '${SoulseekNativeBridge._assembly}.exe')
          .toNativeUtf16(allocator: arena)
      ..ref.dotnetRoot = dir.toNativeUtf16(allocator: arena);
    final handle = arena<Pointer<Void>>();

    final rc = initialize(1, argv, params, handle);
    if (rc != 0 || handle.value == nullptr) {
      throw StateError('hostfxr initialize failed: 0x${rc.toUnsigned(32).toRadixString(16)}');
    }
    try {
      final delegate = arena<Pointer<Void>>();
      final drc = getDelegate(handle.value, _hdtGetFunctionPointer, delegate);
      if (drc != 0) {
        throw StateError('hostfxr get delegate failed: 0x${drc.toUnsigned(32).toRadixString(16)}');
      }
      final getFunctionPointer = delegate.value
          .cast<NativeFunction<_GetFunctionPointerNative>>()
          .asFunction<_GetFunctionPointerDart>();
      final type = 'Soulseek.Wrapper.NativeExports, ${SoulseekNativeBridge._assembly}'
          .toNativeUtf16(allocator: arena);
      // UNMANAGEDCALLERSONLY_METHOD: (const char_t*)-1.
      final unmanagedCallersOnly = Pointer<Utf16>.fromAddress(-1);
      final addresses = <int>[];
      for (final method in const ['Init', 'Call', 'Free', 'Shutdown']) {
        final out = arena<Pointer<Void>>();
        final frc = getFunctionPointer(type, method.toNativeUtf16(allocator: arena),
            unmanagedCallersOnly, nullptr, nullptr, out);
        if (frc != 0 || out.value == nullptr) {
          throw StateError('bridge export $method not found: 0x${frc.toUnsigned(32).toRadixString(16)}');
        }
        addresses.add(out.value.address);
      }
      setEnv(envName, addresses.join(',').toNativeUtf16(allocator: arena));
      return addresses;
    } finally {
      close(handle.value);
    }
  });
}
