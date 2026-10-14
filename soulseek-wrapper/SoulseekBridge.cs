// <copyright file="SoulseekBridge.cs">
//   .NET wrapper для Soulseek (Android AAR).
//   Java-вызываемый адаптер над SoulseekBridgeCore через JNI.
//   Использует [Register] + наследование от Java.Lang.Object для AAR-генерации.
//   Аудиобайты никогда не проходят через Flutter — только метаданные и команды.
// </copyright>

namespace Soulseek.Wrapper
{
    using System;
    using System.Threading.Tasks;
    using Android.Runtime;
    using Java.Interop;

    /// <summary>
    ///   Адаптер протокола Soulseek, вызываемый из Kotlin/Java через JNI.
    ///   Каждый метод принимает JSON-строку и возвращает JSON-строку ResultDto.
    ///   Долгие операции (download) запускаются в фоне; прогресс и завершение
    ///   приходят через ISoulseekEventSink. Вся логика — в SoulseekBridgeCore.
    /// </summary>
    [Register("soulseek/wrapper/SoulseekBridge", DoNotGenerateAcw = false)]
    public class SoulseekBridge : Java.Lang.Object
    {
        // minorVersion > 100 требуется конструктором SoulseekClient.
        // SeekerAndroid использует 128; сохраняем для совместимости протокола.
        private const int ClientMinorVersion = 128;

        private readonly SoulseekBridgeCore _core;

        private ISoulseekEventSink _eventSink;

        // Защита _eventSink при чтении/записи из разных потоков.
        private readonly object _sinkLock = new();

        // ─────────────────────────────────────────────────────────────────────
        //  Конструкторы для JNI
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>Конструктор без параметров — вызывается из Kotlin через JNI.</summary>
        public SoulseekBridge()
        {
            _core = CreateCore();
        }

        /// <summary>Конструктор для JNI-маршалинга существующего Java-объекта.</summary>
        public SoulseekBridge(IntPtr handle, JniHandleOwnership transfer)
            : base(handle, transfer)
        {
            _core = CreateCore();
        }

        private SoulseekBridgeCore CreateCore() => new SoulseekBridgeCore(
            EmitEvent,
            message => Android.Util.Log.Info("SoulseekBridge", message),
            new BridgeHostOptions { ClientMinorVersion = ClientMinorVersion });

        // ─────────────────────────────────────────────────────────────────────
        //  Event Sink
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Устанавливает callback для маршалинга событий в Kotlin.
        ///   Kotlin: soulseekBridge.setEventSink(object : ISoulseekEventSink { ... })
        /// </summary>
        [Export("setEventSink")]
        public void SetEventSink(ISoulseekEventSink sink)
        {
            lock (_sinkLock)
            {
                _eventSink = sink;
            }
        }

        private void EmitEvent(string json)
        {
            ISoulseekEventSink sink;
            lock (_sinkLock)
            {
                sink = _eventSink;
            }

            try
            {
                sink?.OnEvent(json);
            }
            catch
            {
                // event sink может быть disposed; игнорируем
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Команды (блокирующие: Kotlin вызывает их на IO-потоках)
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Подключается к серверу Soulseek и логинится.
        ///   jsonAccount: AccountOptions JSON {username, password, listenPort, ...}.
        ///   Возвращает ResultDto JSON (success/error). Блокирует до завершения login.
        /// </summary>
        [Export("connectAsync")]
        public string ConnectSync(string jsonAccount) => Block(() => _core.ConnectAsync(jsonAccount));

        /// <summary>
        ///   Выполняет поиск по сети Soulseek.
        ///   jsonRequest: SearchRequestDto JSON {requestId, query, timeoutMs, filters}.
        ///   Возвращает ResultDto JSON с data = SearchResultDto[] JSON.
        /// </summary>
        [Export("searchAsync")]
        public string SearchSync(string jsonRequest) => Block(() => _core.SearchAsync(jsonRequest));

        /// <summary>
        ///   Отменяет идущий поиск по requestId. Накопленное к этому моменту вернёт
        ///   исходный вызов searchAsync. false — поиск уже завершён или неизвестен.
        /// </summary>
        [Export("cancelSearch")]
        public bool CancelSearch(string requestId) => _core.CancelSearch(requestId);

        /// <summary>
        ///   Полное содержимое папки пира.
        ///   jsonRequest: DirectoryRequestDto JSON {username, directory, timeoutMs}.
        /// </summary>
        [Export("getDirectoryContentsAsync")]
        public string GetDirectoryContentsSync(string jsonRequest) =>
            Block(() => _core.GetDirectoryContentsAsync(jsonRequest));

        /// <summary>
        ///   Запускает загрузку файла в фоновую задачу; возвращает немедленно
        ///   ResultDto с data = downloadId.
        /// </summary>
        [Export("downloadToFileAsync")]
        public string DownloadToFileSync(string jsonRequest) => _core.StartDownload(jsonRequest);

        /// <summary>
        ///   Отменяет активную загрузку по downloadId.
        ///   transferId: JSON-строка с downloadId.
        /// </summary>
        [Export("cancelTransferAsync")]
        public string CancelTransferSync(string transferId) => _core.CancelTransfer(transferId);

        /// <summary>
        ///   Переконфигурирует параметры клиента (listener, speed limits).
        ///   jsonConfig: SharingConfigDto JSON.
        /// </summary>
        [Export("configureSharingAsync")]
        public string ConfigureSharingSync(string jsonConfig) => Block(() => _core.ConfigureSharingAsync(jsonConfig));

        /// <summary>
        ///   Освобождает клиент и все ресурсы. Вызывается из Kotlin при завершении.
        /// </summary>
        [Export("dispose")]
        public void Shutdown() => _core.Shutdown();

        private static string Block(Func<Task<string>> call)
        {
            try
            {
                // Task.Run + GetAwaiter().GetResult() чтобы избежать SynchronizationContext deadlock.
                return Task.Run(call).GetAwaiter().GetResult();
            }
            catch (Exception ex)
            {
                return SoulseekBridgeCore.ErrorJson(ex, retryable: false);
            }
        }
    }
}
