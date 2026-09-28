// <copyright file="SoulseekBridge.cs">
//   Фаза 1 — .NET wrapper для Soulseek (Android AAR).
//   Главный компонент: Java-вызываемый адаптер протокола Soulseek через JNI.
//   Использует [Register] + наследование от Java.Lang.Object для AAR-генерации.
//   Аудиобайты никогда не проходят через Flutter — только метаданные и команды.
// </copyright>

namespace Soulseek.Wrapper
{
    using System;
    using System.Collections.Concurrent;
    using System.Collections.Generic;
    using System.IO;
    using System.Linq;
    using System.Net;
    using System.Net.Sockets;
    using System.Text.Json;
    using System.Threading;
    using System.Threading.Tasks;
    using Android.Runtime;
    using Java.Interop;
    using Soulseek;

    // Aliases чтобы избежать конфликта между Soulseek.File/Soulseek.Directory и System.IO.
    using IOFile = System.IO.File;
    using IODirectory = System.IO.Directory;
    using SlskFile = Soulseek.File;

    /// <summary>
    ///   Адаптер протокола Soulseek, вызываемый из Kotlin/Java через JNI.
    ///   Каждый метод принимает JSON-строку и возвращает JSON-строку ResultDto.
    ///   Долгие операции (download) запускаются в фоне; прогресс и завершение
    ///   приходят через ISoulseekEventSink.
    /// </summary>
    [Register("soulseek/wrapper/SoulseekBridge", DoNotGenerateAcw = false)]
    public class SoulseekBridge : Java.Lang.Object
    {
        // minorVersion > 100 требуется конструктором SoulseekClient.
        // SeekerAndroid использует 128; сохраняем для совместимости протокола.
        private const int ClientMinorVersion = 128;

        // Fallback IP сервера Soulseek при неудачном DNS-резолвинге (как в SeekerAndroid).
        private const string FallbackServerIp = "208.76.170.59";

        // 250ms throttle для прогресс-событий (≈4 раза/сек) в тиках.
        private const long ProgressThrottleTicks = 2_500_000;

        private static readonly JsonSerializerOptions JsonOpts = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
        };

        private static readonly string[] LosslessExtensions = { "flac", "alac", "wav", "ape", "wv", "dsd", "dsf", "dff" };

        private SoulseekClient _client;
        private ISoulseekEventSink _eventSink;

        // downloadId → CancellationTokenSource для отмены.
        private readonly ConcurrentDictionary<string, CancellationTokenSource> _downloadCts = new();

        // downloadId → throttle-метка последнего прогресс-события (DateTime.UtcNow.Ticks).
        private readonly ConcurrentDictionary<string, long> _lastProgressTick = new();

        // (username, filename) → downloadId для маппинга глобальных transfer-событий.
        private readonly ConcurrentDictionary<string, string> _transferKeyToDownloadId = new();

        // Защита _eventSink при чтении/записи из разных потоков.
        private readonly object _sinkLock = new();

        // ─────────────────────────────────────────────────────────────────────
        //  Конструкторы для JNI
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>Конструктор без параметров — вызывается из Kotlin через JNI.</summary>
        public SoulseekBridge()
        {
        }

        /// <summary>Конструктор для JNI-маршалинга существующего Java-объекта.</summary>
        public SoulseekBridge(IntPtr handle, JniHandleOwnership transfer)
            : base(handle, transfer)
        {
        }

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

        // ─────────────────────────────────────────────────────────────────────
        //  Connect
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Подключается к серверу Soulseek и логинится.
        ///   jsonAccount: AccountOptions JSON {username, password, listenPort, ...}.
        ///   Возвращает ResultDto JSON (success/error). Блокирует до завершения login.
        /// </summary>
        [Export("connectAsync")]
        public string ConnectSync(string jsonAccount)
        {
            try
            {
                // Task.Run + GetAwaiter().GetResult() чтобы избежать SynchronizationContext deadlock.
                return Task.Run(() => ConnectCoreAsync(jsonAccount)).GetAwaiter().GetResult();
            }
            catch (Exception ex)
            {
                return ErrorJson(ex, retryable: IsRetryableConnection(ex));
            }
        }

        private async Task<string> ConnectCoreAsync(string jsonAccount)
        {
            var opts = JsonSerializer.Deserialize<AccountOptions>(jsonAccount, JsonOpts)
                ?? throw new ArgumentException("Invalid account JSON");

            if (string.IsNullOrWhiteSpace(opts.Username) || string.IsNullOrWhiteSpace(opts.Password))
            {
                throw new ArgumentException("username and password are required");
            }

            // Валидация listenPort: SoulseekClientOptions требует 1024–65535.
            int listenPort = opts.ListenPort == 0 ? 50000 : opts.ListenPort;
            if (listenPort < 1024 || listenPort > 65535)
            {
                throw new ArgumentOutOfRangeException(nameof(opts.ListenPort), "listenPort must be 1024–65535");
            }

            // Освобождаем предыдущий клиент если был.
            _client?.Dispose();

            var clientOptions = new SoulseekClientOptions(
                enableListener: opts.EnableListener,
                listenPort: listenPort,
                messageTimeout: opts.MessageTimeoutMs,
                maximumConcurrentSearches: 5,
                maximumConcurrentDownloads: int.MaxValue,
                // Upload slots управляются Kotlin-стороной; отдаём max.
                maximumConcurrentUploads: int.MaxValue,
                addressResolver: ResolveAddressAsync);

            _client = new SoulseekClient(ClientMinorVersion, clientOptions);

            // Подписка на глобальные события клиента.
            WireClientEvents();

            // ConnectAsync(username, password) → подключается к серверу по умолчанию
            // (server.slsknet.org:2242) и выполняет login. Возвращает Task (без результата).
            await _client.ConnectAsync(opts.Username, opts.Password).ConfigureAwait(false);

            var data = JsonSerializer.Serialize(new
            {
                username = opts.Username,
                state = _client.State.ToString(),
            }, JsonOpts);
            return SuccessJson(data);
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Search
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Выполняет поиск по сети Soulseek.
        ///   jsonRequest: SearchRequestDto JSON {requestId, query, timeoutMs, filters}.
        ///   Возвращает ResultDto JSON с data = SearchResultDto[] JSON.
        /// </summary>
        [Export("searchAsync")]
        public string SearchSync(string jsonRequest)
        {
            try
            {
                return Task.Run(() => SearchCoreAsync(jsonRequest)).GetAwaiter().GetResult();
            }
            catch (Exception ex)
            {
                return ErrorJson(ex, retryable: false);
            }
        }

        private async Task<string> SearchCoreAsync(string jsonRequest)
        {
            var req = JsonSerializer.Deserialize<SearchRequestDto>(jsonRequest, JsonOpts)
                ?? throw new ArgumentException("Invalid search request JSON");

            if (string.IsNullOrWhiteSpace(req.Query))
            {
                throw new ArgumentException("query is required");
            }

            EnsureConnected();

            // SearchQuery.FromText разбирает строку на Terms + Exclusions (поддерживает "-term").
            var query = SearchQuery.FromText(req.Query);

            var filters = req.Filters ?? new SearchFiltersDto();

            // SearchOptions: searchTimeout (от последнего ответа), responseLimit, fileFilter, responseFilter.
            var searchOptions = new SearchOptions(
                searchTimeout: req.TimeoutMs > 0 ? req.TimeoutMs : 15000,
                responseLimit: req.ResponseLimit > 0 ? req.ResponseLimit : 250,
                removeSingleCharacterSearchTerms: true,
                fileFilter: f => PassesFileFilter(f, filters),
                responseFilter: r => PassesResponseFilter(r, filters));

            // SearchAsync возвращает (Search Search, IReadOnlyCollection<SearchResponse> Responses).
            var (search, responses) = await _client.SearchAsync(
                query,
                options: searchOptions).ConfigureAwait(false);

            // Маппим responses → плоский список SearchResultDto (по одному DTO на файл).
            var results = new List<SearchResultDto>();
            int responseIndex = 0;
            foreach (var response in responses)
            {
                foreach (var file in response.Files)
                {
                    if (!PassesFileFilter(file, filters))
                    {
                        continue;
                    }

                    results.Add(MapSearchResult(req.RequestId, responseIndex, response, file));
                }

                // Locked files — тоже включаем (требуют привилегий, но доступны для отображения).
                foreach (var file in response.LockedFiles)
                {
                    if (!PassesFileFilter(file, filters))
                    {
                        continue;
                    }

                    var dto = MapSearchResult(req.RequestId, responseIndex, response, file);
                    dto.ResultId = req.RequestId + "_l_" + responseIndex + "_" + results.Count;
                    results.Add(dto);
                }

                responseIndex++;
            }

            var data = JsonSerializer.Serialize(results, JsonOpts);
            return SuccessJson(data);
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Download
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Запускает загрузку файла в фоновую задачу.
        ///   jsonRequest: DownloadRequestDto JSON.
        ///   Возвращает немедленно ResultDto с data = downloadId (download started).
        ///   Прогресс и завершение приходят через ISoulseekEventSink.
        ///   Использует .part файл + atomic rename для безопасного resume.
        /// </summary>
        [Export("downloadToFileAsync")]
        public string DownloadToFileSync(string jsonRequest)
        {
            try
            {
                var dto = JsonSerializer.Deserialize<DownloadRequestDto>(jsonRequest, JsonOpts)
                    ?? throw new ArgumentException("Invalid download request JSON");

                ValidateDownloadRequest(dto);
                EnsureConnected();

                var cts = new CancellationTokenSource();
                _downloadCts[dto.DownloadId] = cts;
                _transferKeyToDownloadId[TransferKey(dto.PeerUsername, dto.RemoteFilename)] = dto.DownloadId;

                // Fire-and-forget: вся долгая работа в фоне.
                _ = Task.Run(() => DownloadToFileCoreAsync(dto, cts.Token));

                return SuccessJson(JsonSerializer.Serialize(dto.DownloadId));
            }
            catch (Exception ex)
            {
                return ErrorJson(ex, retryable: false);
            }
        }

        private async Task DownloadToFileCoreAsync(DownloadRequestDto dto, CancellationToken ct)
        {
            string partPath = null;
            string finalPath = null;
            try
            {
                // Санитизация и подготовка путей.
                var safeDir = SanitizeDirectory(dto.LocalDirectory);
                IODirectory.CreateDirectory(safeDir);

                var safeCacheKey = SanitizeFilename(dto.CacheKey);
                var safeExtension = SanitizeFilename(dto.FileExtension ?? "dat");

                partPath = Path.Combine(safeDir, safeCacheKey + ".part");
                finalPath = Path.Combine(safeDir, safeCacheKey + "." + safeExtension);

                // Resume: если .part файл уже есть, продолжаем с текущего размера.
                long startOffset = 0;
                if (IOFile.Exists(partPath))
                {
                    startOffset = new FileInfo(partPath).Length;
                    // Если .part уже полностью скачан (size совпадает), сразу rename.
                    if (dto.SizeBytes > 0 && startOffset >= dto.SizeBytes)
                    {
                        AtomicRename(partPath, finalPath);
                        EmitEvent(new SoulseekEventDto
                        {
                            EventType = "downloadComplete",
                            DownloadId = dto.DownloadId,
                            State = nameof(TransferStates.Succeeded),
                            BytesReceived = startOffset,
                            TotalBytes = dto.SizeBytes,
                            LocalPath = finalPath,
                        });
                        return;
                    }
                }

                // TransferOptions: stateChanged + progressUpdated с throttle 250ms.
                var transferOptions = new TransferOptions(
                    stateChanged: args => OnTransferStateChanged(dto.DownloadId, args.Transfer, args.PreviousState),
                    progressUpdated: args => OnTransferProgress(dto.DownloadId, args.Transfer),
                    disposeOutputStreamOnCompletion: true,
                    seekOutputStreamAutomatically: true);

                // DownloadAsync(username, remoteFilename, localFilename, size, startOffset, options, ct).
                // Soulseek.NET сам управляет FileStream: append при startOffset > 0, create при 0.
                var transfer = await _client.DownloadAsync(
                    dto.PeerUsername,
                    dto.RemoteFilename,
                    partPath,
                    size: dto.SizeBytes > 0 ? dto.SizeBytes : (long?)null,
                    startOffset: startOffset,
                    options: transferOptions,
                    cancellationToken: ct).ConfigureAwait(false);

                // Atomic rename .part → финальное расширение.
                AtomicRename(partPath, finalPath);

                EmitEvent(new SoulseekEventDto
                {
                    EventType = "downloadComplete",
                    DownloadId = dto.DownloadId,
                    State = nameof(TransferStates.Succeeded),
                    BytesReceived = transfer.BytesTransferred,
                    TotalBytes = transfer.Size,
                    LocalPath = finalPath,
                });
            }
            catch (OperationCanceledException)
            {
                EmitEvent(new SoulseekEventDto
                {
                    EventType = "downloadFailed",
                    DownloadId = dto.DownloadId,
                    State = nameof(TransferStates.Cancelled),
                    ErrorCode = "CANCELLED",
                    Message = "Download cancelled",
                    Retryable = false,
                });
            }
            catch (Exception ex)
            {
                EmitEvent(new SoulseekEventDto
                {
                    EventType = "downloadFailed",
                    DownloadId = dto.DownloadId,
                    State = nameof(TransferStates.Errored),
                    ErrorCode = ex.GetType().Name,
                    Message = ex.Message,
                    Retryable = IsRetryableTransfer(ex),
                });
            }
            finally
            {
                CleanupDownload(dto.DownloadId, dto.PeerUsername, dto.RemoteFilename);
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Cancel Transfer
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Отменяет активную загрузку по downloadId.
        ///   transferId: JSON-строка с downloadId.
        /// </summary>
        [Export("cancelTransferAsync")]
        public string CancelTransferSync(string transferId)
        {
            try
            {
                var downloadId = JsonSerializer.Deserialize<string>(transferId, JsonOpts)
                    ?? transferId?.Trim('"');

                if (string.IsNullOrEmpty(downloadId))
                {
                    throw new ArgumentException("downloadId is required");
                }

                if (_downloadCts.TryRemove(downloadId, out var cts))
                {
                    cts.Cancel();
                    cts.Dispose();
                }

                return SuccessJson(null);
            }
            catch (Exception ex)
            {
                return ErrorJson(ex, retryable: false);
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Configure Sharing
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Переконфигурирует параметры клиента (listener, speed limits) через ReconfigureOptionsAsync.
        ///   jsonConfig: SharingConfigDto JSON.
        /// </summary>
        [Export("configureSharingAsync")]
        public string ConfigureSharingSync(string jsonConfig)
        {
            try
            {
                return Task.Run(() => ConfigureSharingCoreAsync(jsonConfig)).GetAwaiter().GetResult();
            }
            catch (Exception ex)
            {
                return ErrorJson(ex, retryable: false);
            }
        }

        private async Task<string> ConfigureSharingCoreAsync(string jsonConfig)
        {
            var cfg = JsonSerializer.Deserialize<SharingConfigDto>(jsonConfig, JsonOpts)
                ?? throw new ArgumentException("Invalid sharing config JSON");

            if (_client == null)
            {
                throw new InvalidOperationException("Client not initialized; call connectAsync first");
            }

            // SoulseekClientOptionsPatch позволяет частичное переопределение опций.
            // Реальные параметры патча: enableListener, listenPort, maximumUploadSpeed, maximumDownloadSpeed.
            var patch = new SoulseekClientOptionsPatch(
                enableListener: cfg.EnableListener,
                listenPort: cfg.ListenPort,
                maximumUploadSpeed: cfg.MaximumUploadSpeed,
                maximumDownloadSpeed: cfg.MaximumDownloadSpeed);

            await _client.ReconfigureOptionsAsync(patch).ConfigureAwait(false);

            return SuccessJson(null);
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Dispose
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Освобождает клиент и все ресурсы. Вызывается из Kotlin при завершении.
        /// </summary>
        [Export("dispose")]
        public void Shutdown()
        {
            try
            {
                // Отменяем все активные загрузки.
                foreach (var pair in _downloadCts)
                {
                    try { pair.Value.Cancel(); } catch { }
                    pair.Value.Dispose();
                }

                _downloadCts.Clear();
                _transferKeyToDownloadId.Clear();
                _lastProgressTick.Clear();

                _client?.Dispose();
                _client = null;
            }
            catch
            {
                // best-effort
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Внутренние хелперы — события клиента
        // ─────────────────────────────────────────────────────────────────────

        private void WireClientEvents()
        {
            // StateChanged: переходы между SoulseekClientStates (Disconnected → Connected → LoggedIn).
            _client.StateChanged += (_, e) =>
            {
                EmitEvent(new SoulseekEventDto
                {
                    EventType = "clientStateChanged",
                    State = e.State.ToString(),
                    Message = e.Message,
                    ErrorCode = e.Exception?.GetType().Name,
                    ExceptionMessage = e.Exception?.Message,
                });
            };

            // Disconnected: сервер разорвал соединение.
            _client.Disconnected += (_, e) =>
            {
                EmitEvent(new SoulseekEventDto
                {
                    EventType = "disconnected",
                    State = nameof(SoulseekClientStates.Disconnected),
                    Message = e.Message,
                    ErrorCode = e.Exception?.GetType().Name,
                    ExceptionMessage = e.Exception?.Message,
                    Retryable = true, // дисконнект обычно retryable
                });
            };

            // SearchResponseReceived: каждый ответ поиска (для streaming-обновлений UI).
            // Здесь не пересылаем — SearchAsync собирает всё в финальный результат.
            // Можно включить streaming если Kotlin-сторона захочет incremental updates.
        }

        private void OnTransferStateChanged(string downloadId, Transfer transfer, TransferStates previousState)
        {
            var state = transfer.State;
            string eventType;

            // Completed всегда сопровождается Succeeded/Cancelled/TimedOut/Errored/Rejected/Aborted.
            if (state.HasFlag(TransferStates.Completed))
            {
                if (state.HasFlag(TransferStates.Succeeded))
                {
                    // Успех обрабатывается в DownloadToFileCoreAsync (atomic rename) — не дублируем.
                    return;
                }

                eventType = "downloadFailed";
            }
            else
            {
                eventType = "transferStateChanged";
            }

            EmitEvent(new SoulseekEventDto
            {
                EventType = eventType,
                DownloadId = downloadId,
                State = state.ToString(),
                BytesReceived = transfer.BytesTransferred,
                TotalBytes = transfer.Size,
                ErrorCode = transfer.Exception?.GetType().Name,
                ExceptionMessage = transfer.Exception?.Message,
                Retryable = state.HasFlag(TransferStates.Errored) && IsRetryableTransfer(transfer.Exception),
            });
        }

        private void OnTransferProgress(string downloadId, Transfer transfer)
        {
            // Throttle: не чаще 250ms (≈4 раза/сек) на download.
            long now = DateTime.UtcNow.Ticks;
            _lastProgressTick.TryGetValue(downloadId, out long last);

            if (now - last < ProgressThrottleTicks)
            {
                return;
            }

            _lastProgressTick[downloadId] = now;

            EmitEvent(new SoulseekEventDto
            {
                EventType = "transferProgress",
                DownloadId = downloadId,
                State = transfer.State.ToString(),
                BytesReceived = transfer.BytesTransferred,
                TotalBytes = transfer.Size,
                BytesPerSecond = (long)transfer.AverageSpeed,
            });
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Внутренние хелперы — маппинг и фильтрация
        // ─────────────────────────────────────────────────────────────────────

        private static SearchResultDto MapSearchResult(string requestId, int responseIndex, SearchResponse response, SlskFile file)
        {
            return new SearchResultDto
            {
                ResultId = requestId + "_" + responseIndex + "_" + file.Code,
                Username = response.Username,
                Filename = file.Filename,
                SizeBytes = file.Size,
                Extension = file.Extension,
                // File.BitRate, File.SampleRate, File.BitDepth, File.Length — уже извлечены из Attributes.
                Bitrate = file.BitRate,
                SampleRate = file.SampleRate,
                BitDepth = file.BitDepth,
                DurationSeconds = file.Length,
                QueueLength = response.QueueLength,
                FreeUploadSlots = response.HasFreeUploadSlot ? 1 : 0,
                UploadSpeed = response.UploadSpeed,
            };
        }

        private static bool PassesFileFilter(SlskFile file, SearchFiltersDto filters)
        {
            if (filters == null)
            {
                return true;
            }

            // Расширения
            if (filters.Extensions != null && filters.Extensions.Count > 0)
            {
                var ext = (file.Extension ?? string.Empty).ToLowerInvariant().TrimStart('.');
                if (!filters.Extensions.Contains(ext))
                {
                    return false;
                }
            }

            // Размер
            if (filters.MinSizeBytes.HasValue && file.Size < filters.MinSizeBytes.Value)
            {
                return false;
            }

            if (filters.MaxSizeBytes.HasValue && file.Size > filters.MaxSizeBytes.Value)
            {
                return false;
            }

            // Минимальный битрейт
            if (filters.MinBitrate.HasValue)
            {
                if (!file.BitRate.HasValue || file.BitRate.Value < filters.MinBitrate.Value)
                {
                    return false;
                }
            }

            // Lossless only
            if (filters.LosslessOnly)
            {
                var ext = (file.Extension ?? string.Empty).ToLowerInvariant().TrimStart('.');
                if (!LosslessExtensions.Contains(ext))
                {
                    return false;
                }
            }

            return true;
        }

        private static bool PassesResponseFilter(SearchResponse response, SearchFiltersDto filters)
        {
            if (filters == null)
            {
                return true;
            }

            if (filters.MinPeerUploadSpeed.HasValue && response.UploadSpeed < filters.MinPeerUploadSpeed.Value)
            {
                return false;
            }

            if (filters.MaxPeerQueueLength.HasValue && response.QueueLength > filters.MaxPeerQueueLength.Value)
            {
                return false;
            }

            return true;
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Внутренние хелперы — валидация и санитизация путей
        // ─────────────────────────────────────────────────────────────────────

        private static void ValidateDownloadRequest(DownloadRequestDto dto)
        {
            if (dto == null)
            {
                throw new ArgumentException("download request is null");
            }

            if (string.IsNullOrWhiteSpace(dto.DownloadId))
            {
                throw new ArgumentException("downloadId is required");
            }

            if (string.IsNullOrWhiteSpace(dto.PeerUsername))
            {
                throw new ArgumentException("peerUsername is required");
            }

            if (string.IsNullOrWhiteSpace(dto.RemoteFilename))
            {
                throw new ArgumentException("remoteFilename is required");
            }

            if (string.IsNullOrWhiteSpace(dto.CacheKey))
            {
                throw new ArgumentException("cacheKey is required");
            }

            if (string.IsNullOrWhiteSpace(dto.LocalDirectory))
            {
                throw new ArgumentException("localDirectory is required");
            }

            // Запрет path traversal и абсолютных путей в cacheKey/fileExtension.
            if (dto.CacheKey.Contains("..") || dto.CacheKey.Contains("/") || dto.CacheKey.Contains("\\")
                || Path.IsPathRooted(dto.CacheKey))
            {
                throw new ArgumentException("cacheKey must be a simple filename, no path separators or traversal");
            }

            if (!string.IsNullOrEmpty(dto.FileExtension)
                && (dto.FileExtension.Contains("..") || dto.FileExtension.Contains("/") || dto.FileExtension.Contains("\\")
                    || Path.IsPathRooted(dto.FileExtension)))
            {
                throw new ArgumentException("fileExtension must be a simple extension, no path separators or traversal");
            }
        }

        private static string SanitizeDirectory(string dir)
        {
            // Запрет traversal в директории.
            var full = Path.GetFullPath(dir);
            if (full.Contains(".."))
            {
                throw new ArgumentException("localDirectory must not contain path traversal");
            }

            return full;
        }

        private static string SanitizeFilename(string name)
        {
            // Убираем любые path-сепараторы и traversal из имени файла.
            foreach (var c in Path.GetInvalidFileNameChars())
            {
                name = name.Replace(c, '_');
            }

            name = name.Replace("..", "_").Replace('/', '_').Replace('\\', '_');
            return name;
        }

        private static void AtomicRename(string partPath, string finalPath)
        {
            // Удаляем финальный файл если существует (старая версия).
            if (IOFile.Exists(finalPath))
            {
                IOFile.Delete(finalPath);
            }

            // File.Move атомарен на одной файловой системе (Android external storage).
            IOFile.Move(partPath, finalPath);
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Внутренние хелперы — DNS, соединение, классификация ошибок
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Резолвит адрес сервера Soulseek в IP. Принудительно IPv4 (server.slsknet.org
        ///   имеет только A-запись; AAAA-запрос таймаутится у ~20% пользователей).
        ///   Fallback на хардкод IP как в SeekerAndroid.
        /// </summary>
        private static async Task<IPAddress> ResolveAddressAsync(string address)
        {
            try
            {
                var dnsTask = Dns.GetHostAddressesAsync(address, AddressFamily.InterNetwork);
                var completed = await Task.WhenAny(dnsTask, Task.Delay(3000)).ConfigureAwait(false);

                if (completed == dnsTask && dnsTask.Status == TaskStatus.RanToCompletion && dnsTask.Result.Length > 0)
                {
                    return dnsTask.Result[0];
                }
            }
            catch
            {
                // fall through to hardcoded IP
            }

            return IPAddress.Parse(FallbackServerIp);
        }

        private void EnsureConnected()
        {
            if (_client == null)
            {
                throw new InvalidOperationException("Client not initialized; call connectAsync first");
            }

            if (!_client.State.HasFlag(SoulseekClientStates.Connected) || !_client.State.HasFlag(SoulseekClientStates.LoggedIn))
            {
                throw new InvalidOperationException($"Client must be connected and logged in (currently: {_client.State})");
            }
        }

        private static bool IsRetryableConnection(Exception ex)
        {
            // Сетевые/DNS ошибки — retryable. Логин-отказ — нет.
            return ex is TimeoutException
                || ex is SocketException
                || ex is AddressException;
        }

        private static bool IsRetryableTransfer(Exception ex)
        {
            if (ex == null)
            {
                return false;
            }

            // UserOffline, CannotConnect, Timeout — retryable (позже).
            // TransferRejected, SizeMismatch — нет.
            var typeName = ex.GetType().Name;
            return typeName.Contains("UserOffline")
                || typeName.Contains("CannotConnect")
                || typeName.Contains("Timeout")
                || ex is TimeoutException
                || ex is SocketException;
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Внутренние хелперы — JSON и события
        // ─────────────────────────────────────────────────────────────────────

        private void EmitEvent(SoulseekEventDto evt)
        {
            ISoulseekEventSink sink;
            lock (_sinkLock)
            {
                sink = _eventSink;
            }

            if (sink == null)
            {
                return;
            }

            try
            {
                var json = JsonSerializer.Serialize(evt, JsonOpts);
                sink.OnEvent(json);
            }
            catch
            {
                // event sink может быть disposed; игнорируем
            }
        }

        private static string SuccessJson(string data)
        {
            return JsonSerializer.Serialize(new ResultDto { Success = true, Data = data }, JsonOpts);
        }

        private static string ErrorJson(Exception ex, bool retryable)
        {
            return JsonSerializer.Serialize(new ResultDto
            {
                Success = false,
                ErrorCode = ex.GetType().Name,
                ErrorMessage = ex.Message,
                Retryable = retryable,
            }, JsonOpts);
        }

        private void CleanupDownload(string downloadId, string username, string remoteFilename)
        {
            _downloadCts.TryRemove(downloadId, out _);
            _transferKeyToDownloadId.TryRemove(TransferKey(username, remoteFilename), out _);
            _lastProgressTick.TryRemove(downloadId, out _);
        }

        private static string TransferKey(string username, string filename)
        {
            return username + "\0" + filename;
        }
    }
}
