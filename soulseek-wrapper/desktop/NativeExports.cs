// <copyright file="NativeExports.cs">
//   Нативный ABI моста Soulseek для Windows. Dart поднимает CoreCLR через
//   hostfxr (hdt_get_function_pointer) и получает указатели на эти методы.
//
//   Контракт:
//   - Init(callback): callback(requestId, utf8Json) — единственный канал наружу.
//     requestId == 0 — событие (SoulseekEventDto), иначе — ответ на Call.
//     Строку выделяет мост (NativeMemory), получатель копирует её и вызывает Free.
//   - Call(requestId, method, json): возвращает сразу, работа идёт в Task;
//     ответ — ResultDto через callback с тем же requestId.
//   - Free(ptr), Shutdown().
//   Исключения не пересекают границу ABI: каждая точка входа и продолжение
//   Task — в try/catch, ошибка уходит в ResultDto или в лог.
// </copyright>

namespace Soulseek.Wrapper
{
    using System;
    using System.Runtime.InteropServices;
    using System.Text;
    using System.Text.Json;
    using System.Threading.Tasks;

    public static class NativeExports
    {
        /// <summary>
        ///   Client minor version Windows-клиента. Лицензия Soulseek.NET требует
        ///   уникальный номер для приложения: 760–7699999 занят slskd, 128 — Seeker.
        /// </summary>
        public const int ClientMinorVersion = 9100330;

        private static readonly object Gate = new();

        private static unsafe delegate* unmanaged<long, byte*, void> _callback;

        private static SoulseekBridgeCore _core;

        /// <summary>Не вызывается: точка входа нужна только для self-contained сборки.</summary>
        public static void Main()
        {
        }

        [UnmanagedCallersOnly]
        public static unsafe int Init(delegate* unmanaged<long, byte*, void> callback)
        {
            try
            {
                lock (Gate)
                {
                    if (_core == null)
                    {
                        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
                            Log("unhandled: " + e.ExceptionObject);
                        TaskScheduler.UnobservedTaskException += (_, e) =>
                        {
                            e.SetObserved();
                            Log("unobserved task exception: " + e.Exception);
                        };

                        _core = new SoulseekBridgeCore(
                            json => Send(0, json),
                            Log,
                            new BridgeHostOptions
                            {
                                ClientMinorVersion = ClientMinorVersion,
                                PublishOnComplete = false,
                                ShareOutputForReading = true,
                            });
                    }

                    // Только после успешного создания ядра: при неудаче Dart закроет
                    // колбэк, и мост не должен его вызывать.
                    _callback = callback;
                }

                return 0;
            }
            catch
            {
                return -1;
            }
        }

        [UnmanagedCallersOnly]
        public static unsafe void Call(long requestId, byte* method, byte* json)
        {
            string m;
            string payload;
            try
            {
                m = Marshal.PtrToStringUTF8((IntPtr)method) ?? string.Empty;
                payload = Marshal.PtrToStringUTF8((IntPtr)json) ?? string.Empty;
            }
            catch (Exception ex)
            {
                Send(requestId, SoulseekBridgeCore.ErrorJson(ex, retryable: false));
                return;
            }

            _ = Task.Run(() => RunCallAsync(requestId, m, payload));
        }

        private static async Task RunCallAsync(long requestId, string method, string json)
        {
            string result;
            try
            {
                result = await Dispatch(method, json).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                result = SoulseekBridgeCore.ErrorJson(ex, retryable: false);
            }

            Send(requestId, result);
        }

        [UnmanagedCallersOnly]
        public static unsafe void Free(byte* ptr)
        {
            NativeMemory.Free(ptr);
        }

        [UnmanagedCallersOnly]
        public static void Shutdown()
        {
            try
            {
                _core?.Shutdown();
            }
            catch (Exception ex)
            {
                Log("shutdown failed: " + ex.Message);
            }
        }

        private static Task<string> Dispatch(string method, string json)
        {
            var core = _core ?? throw new InvalidOperationException("Bridge is not initialized");
            switch (method)
            {
                case "connect":
                    return core.ConnectAsync(json);
                case "disconnect":
                    core.Shutdown();
                    return Task.FromResult(Ok("true"));
                case "search":
                    return core.SearchAsync(json);
                case "cancelSearch":
                    return Task.FromResult(Ok(core.CancelSearch(json) ? "true" : "false"));
                case "getDirectoryContents":
                    return core.GetDirectoryContentsAsync(json);
                case "startDownload":
                    return Task.FromResult(core.StartDownload(json));
                case "cancelTransfer":
                    return Task.FromResult(core.CancelTransfer(json));
                case "configureSharing":
                    return core.ConfigureSharingAsync(json);
                case "ping":
                    return Task.FromResult(Ok(JsonSerializer.Serialize(new
                    {
                        runtime = Environment.Version.ToString(),
                        runtimeDirectory = RuntimeEnvironment.GetRuntimeDirectory(),
                        clientMinorVersion = ClientMinorVersion,
                    })));
                default:
                    throw new ArgumentException("Unknown method: " + method);
            }
        }

        private static string Ok(string data) =>
            JsonSerializer.Serialize(new ResultDto { Success = true, Data = data });

        private static void Log(string message)
        {
            Send(0, JsonSerializer.Serialize(new SoulseekEventDto { EventType = "log", Message = message }));
        }

        private static unsafe void Send(long requestId, string json)
        {
            var callback = _callback;
            if (callback == null)
            {
                return;
            }

            byte* ptr = null;
            try
            {
                var bytes = Encoding.UTF8.GetBytes(json);
                ptr = (byte*)NativeMemory.Alloc((nuint)bytes.Length + 1);
                bytes.AsSpan().CopyTo(new Span<byte>(ptr, bytes.Length));
                ptr[bytes.Length] = 0;
                callback(requestId, ptr);
            }
            catch
            {
                // Получатель недоступен — строку некому освободить.
                if (ptr != null)
                {
                    NativeMemory.Free(ptr);
                }
            }
        }
    }
}
