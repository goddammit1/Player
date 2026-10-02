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

        // Аудио-расширения по умолчанию: если фильтр расширений пуст, картинки/cue/log/nfo
        // из папок альбомов отсекаются, чтобы не занимать fileLimit и не гонять их через JNI.
        private static readonly HashSet<string> AudioExtensions = new HashSet<string>
        {
            "mp3", "flac", "ogg", "oga", "opus", "m4a", "aac", "alac", "wav", "aif", "aiff",
            "ape", "wv", "wma", "mpc", "dsf", "dff",
        };

        // Период проверки дедлайна / окна тишины в SearchCoreAsync.
        private const int SearchWatchdogTickMs = 200;

        private SoulseekClient _client;
        private ISoulseekEventSink _eventSink;

        // downloadId → CancellationTokenSource для отмены.
        private readonly ConcurrentDictionary<string, CancellationTokenSource> _downloadCts = new();

        // requestId → CancellationTokenSource идущего поиска (cancelSearch).
        private readonly ConcurrentDictionary<string, CancellationTokenSource> _searchCts = new();

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

            int budgetMs = req.TimeoutMs > 0 ? req.TimeoutMs : 10000;
            int idleMs = req.IdleTimeoutMs > 0 ? req.IdleTimeoutMs : 2500;
            int fileLimit = req.FileLimit > 0 ? req.FileLimit : 200;

            // Таймаут SearchInternal — «окно тишины», которое сбрасывается на КАЖДЫЙ ответ
            // пира. На популярных запросах ответы идут непрерывно, и поиск тянулся до
            // responseLimit (25–30 c). Поэтому завершение контролируем сами (см. watchdog
            // ниже), а библиотечный таймаут оставляем страховкой = общий бюджет.
            var searchOptions = new SearchOptions(
                searchTimeout: budgetMs,
                responseLimit: req.ResponseLimit > 0 ? req.ResponseLimit : 100,
                fileLimit: fileLimit,
                removeSingleCharacterSearchTerms: true,
                fileFilter: f => PassesFileFilter(f, filters),
                responseFilter: r => PassesResponseFilter(r, filters));

            // DTO собираем прямо в колбэке, в порядке прихода ответов — первыми идут
            // самые отзывчивые пиры. Лимит проверяется на каждом файле, так что
            // лишние DTO сверх fileLimit не создаются. LockedFiles не берём: без
            // привилегий пир их не отдаст, и такой трек падал бы при воспроизведении.
            var results = new List<SearchResultDto>();
            var resultsLock = new object();
            int responseCount = 0;
            long lastResponseTicks = 0;
            long firstResponseTicks = 0;
            var startedAt = DateTime.UtcNow;

            void OnResponse(SearchResponse response)
            {
                lock (resultsLock)
                {
                    int responseIndex = responseCount++;
                    foreach (var file in response.Files)
                    {
                        if (results.Count >= fileLimit)
                        {
                            break;
                        }

                        if (PassesFileFilter(file, filters))
                        {
                            results.Add(MapSearchResult(req.RequestId, responseIndex, response, file));
                        }
                    }
                }

                long now = DateTime.UtcNow.Ticks;
                Interlocked.CompareExchange(ref firstResponseTicks, now, 0);
                Interlocked.Exchange(ref lastResponseTicks, now);
            }

            // Потоковая выдача: на каждом тике watchdog'а новые DTO уходят событием
            // searchProgress, чтобы UI показывал первые треки, не дожидаясь конца.
            int emittedCount = 0;

            void EmitProgress()
            {
                List<SearchResultDto> fresh;
                lock (resultsLock)
                {
                    if (results.Count <= emittedCount)
                    {
                        return;
                    }

                    fresh = results.GetRange(emittedCount, results.Count - emittedCount);
                    emittedCount = results.Count;
                }

                EmitEvent(new SoulseekEventDto
                {
                    EventType = "searchProgress",
                    RequestId = req.RequestId,
                    Results = fresh,
                });
            }

            var cts = new CancellationTokenSource();
            _searchCts[req.RequestId] = cts;
            string stopReason = null;
            try
            {
                var searchTask = _client.SearchAsync(
                    query,
                    OnResponse,
                    options: searchOptions,
                    cancellationToken: cts.Token);

                // Watchdog: жёсткий общий бюджет + окно тишины, которое начинает действовать
                // только после первого ответа (до него пиры по распределённой сети ещё
                // получают запрос, и «тишина» ничего не значит).
                var deadline = startedAt.AddMilliseconds(budgetMs);
                long idleTicks = TimeSpan.FromMilliseconds(idleMs).Ticks;

                while (!searchTask.IsCompleted)
                {
                    await Task.WhenAny(searchTask, Task.Delay(SearchWatchdogTickMs)).ConfigureAwait(false);
                    if (searchTask.IsCompleted)
                    {
                        break;
                    }

                    if (cts.IsCancellationRequested)
                    {
                        stopReason = "cancelled";
                        break;
                    }

                    EmitProgress();

                    var now = DateTime.UtcNow;
                    long last = Interlocked.Read(ref lastResponseTicks);
                    if (now >= deadline || (last != 0 && now.Ticks - last >= idleTicks))
                    {
                        stopReason = now >= deadline ? "budget" : "idle";
                        cts.Cancel();
                        break;
                    }
                }

                try
                {
                    var search = await searchTask.ConfigureAwait(false);
                    // Завершилась сама библиотека: лимит ответов/файлов или её таймаут.
                    stopReason ??= search.State.ToString();
                }
                catch (OperationCanceledException) when (cts.IsCancellationRequested)
                {
                    // Остановлено watchdog'ом или cancelSearch — возвращаем накопленное.
                    stopReason ??= "cancelled";
                }
            }
            finally
            {
                _searchCts.TryRemove(req.RequestId, out _);
                cts.Dispose();
            }

            string data;
            lock (resultsLock)
            {
                // Диагностика для замеров: почему и когда остановился поиск
                // (adb logcat -s SoulseekBridge).
                long first = Interlocked.Read(ref firstResponseTicks);
                Android.Util.Log.Info(
                    "SoulseekBridge",
                    $"search stop={stopReason} elapsed={(DateTime.UtcNow - startedAt).TotalMilliseconds:F0}ms "
                    + $"firstResponse={(first == 0 ? "none" : ((first - startedAt.Ticks) / TimeSpan.TicksPerMillisecond) + "ms")} "
                    + $"responses={responseCount} files={results.Count}");

                data = JsonSerializer.Serialize(results, JsonOpts);
            }

            return SuccessJson(data);
        }

        /// <summary>
        ///   Отменяет идущий поиск по requestId. Накопленное к этому моменту вернёт
        ///   исходный вызов searchAsync. false — поиск уже завершён или неизвестен.
        /// </summary>
        [Export("cancelSearch")]
        public bool CancelSearch(string requestId)
        {
            if (requestId != null && _searchCts.TryGetValue(requestId, out var cts))
            {
                try
                {
                    cts.Cancel();
                    return true;
                }
                catch (ObjectDisposedException)
                {
                    // Поиск завершился между TryGetValue и Cancel.
                }
            }

            return false;
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Folder contents
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Запрашивает у пира полное содержимое папки (как «Get folder contents»
        ///   в SeekerAndroid): поиск отдаёт только совпавшие с запросом файлы.
        ///   jsonRequest: DirectoryRequestDto JSON {username, directory, timeoutMs}.
        ///   Возвращает ResultDto JSON с data = SearchResultDto[] JSON (только аудио,
        ///   полные пути; статистика пира — нули, её знает Dart из поиска).
        /// </summary>
        [Export("getDirectoryContentsAsync")]
        public string GetDirectoryContentsSync(string jsonRequest)
        {
            try
            {
                return Task.Run(() => GetDirectoryContentsCoreAsync(jsonRequest)).GetAwaiter().GetResult();
            }
            catch (Exception ex)
            {
                return ErrorJson(ex, retryable: IsRetryableTransfer(ex));
            }
        }

        private async Task<string> GetDirectoryContentsCoreAsync(string jsonRequest)
        {
            var req = JsonSerializer.Deserialize<DirectoryRequestDto>(jsonRequest, JsonOpts)
                ?? throw new ArgumentException("Invalid directory request JSON");

            if (string.IsNullOrWhiteSpace(req.Username) || string.IsNullOrWhiteSpace(req.Directory))
            {
                throw new ArgumentException("username and directory are required");
            }

            EnsureConnected();

            using var cts = new CancellationTokenSource(req.TimeoutMs > 0 ? req.TimeoutMs : 20000);
            var directories = await _client
                .GetDirectoryContentsAsync(req.Username, req.Directory, cancellationToken: cts.Token)
                .ConfigureAwait(false);

            // В ответе на FolderContentsRequest имена файлов — без каталога
            // ("02 - song.mp3"); для загрузки нужен полный путь, как в поиске.
            var results = new List<SearchResultDto>();
            int index = 0;
            foreach (var dir in directories)
            {
                foreach (var f in dir.Files)
                {
                    var fullName = f.Filename.Contains('\\') && f.Filename.StartsWith(dir.Name, StringComparison.Ordinal)
                        ? f.Filename
                        : dir.Name + "\\" + f.Filename;
                    var file = new SlskFile(f.Code, fullName, f.Size, f.Extension, f.Attributes, f.IsLatin1Decoded, dir.DecodedViaLatin1);
                    if (!PassesFileFilter(file, null))
                    {
                        continue;
                    }

                    results.Add(new SearchResultDto
                    {
                        ResultId = "dir_" + index++,
                        Username = req.Username,
                        Filename = fullName,
                        SizeBytes = file.Size,
                        Extension = ExtensionOf(file),
                        Bitrate = file.BitRate,
                        SampleRate = file.SampleRate,
                        BitDepth = file.BitDepth,
                        DurationSeconds = file.Length,
                    });
                }
            }

            Android.Util.Log.Info(
                "SoulseekBridge",
                $"folder contents user={req.Username} dirs={directories.Count} audio={results.Count}");

            return SuccessJson(JsonSerializer.Serialize(results, JsonOpts));
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

                    // Остаток считается полным только при точном совпадении размера.
                    // Содержимое проверяется единым валидатором с обычным завершением:
                    // oversized или битый остаток не публикуется и не используется
                    // для resume (см. план исправления CACHE-01, раздел 5.3).
                    if (dto.SizeBytes > 0 && startOffset >= dto.SizeBytes)
                    {
                        ValidateDownloadedFile(partPath, safeExtension, dto.SizeBytes);

                        AtomicRename(partPath, finalPath);
                        EmitEvent(new SoulseekEventDto
                        {
                            EventType = "downloadComplete",
                            DownloadId = dto.DownloadId,
                            State = nameof(TransferStates.Succeeded),
                            BytesReceived = dto.SizeBytes,
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

                // Единая валидация ДО публикации: размер точно равен заявленному
                // (если известен), магические байты соответствуют расширению;
                // HTML/JSON-payload отклоняется. Повреждённый файл не публикуется.
                var expectedSize = dto.SizeBytes > 0
                    ? dto.SizeBytes
                    : (transfer.Size > 0 ? transfer.Size : 0L);
                ValidateDownloadedFile(partPath, safeExtension, expectedSize);

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
            catch (FileValidationException vex)
            {
                // Невалидный результат не публикуем: удаляем остаток .part и
                // возможный старый final, чтобы кэш не выдал повреждённый файл.
                // Осмысленная ошибка уходит в downloadFailed (не retryable —
                // повторная передача от того же пира даст тот же байт-поток).
                TryDeleteFile(partPath);
                TryDeleteFile(finalPath);
                EmitEvent(new SoulseekEventDto
                {
                    EventType = "downloadFailed",
                    DownloadId = dto.DownloadId,
                    State = nameof(TransferStates.Errored),
                    ErrorCode = vex.ErrorCode,
                    Message = vex.Message,
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

            // Потоковые результаты поиска (searchProgress) шлёт SearchCoreAsync —
            // там известны requestId и фильтры конкретного запроса.
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
                Extension = ExtensionOf(file),
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

        /// <summary>
        ///   Расширение файла в нижнем регистре без точки. Многие клиенты шлют пустое
        ///   поле extension — тогда берём его из имени файла (пути вида "A\\B\\c.flac").
        /// </summary>
        private static string ExtensionOf(SlskFile file)
        {
            var ext = (file.Extension ?? string.Empty).Trim().TrimStart('.');
            if (ext.Length == 0 && !string.IsNullOrEmpty(file.Filename))
            {
                var name = file.Filename;
                int sep = Math.Max(name.LastIndexOf('\\'), name.LastIndexOf('/'));
                int dot = name.LastIndexOf('.');
                if (dot > sep && dot < name.Length - 1)
                {
                    ext = name.Substring(dot + 1);
                }
            }

            return ext.ToLowerInvariant();
        }

        private static bool PassesFileFilter(SlskFile file, SearchFiltersDto filters)
        {
            var ext = ExtensionOf(file);

            // Расширения: явный список из настроек, иначе — только аудио.
            if (filters?.Extensions != null && filters.Extensions.Count > 0)
            {
                if (!filters.Extensions.Contains(ext))
                {
                    return false;
                }
            }
            else if (!AudioExtensions.Contains(ext))
            {
                return false;
            }

            if (filters == null)
            {
                return true;
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
        //  Валидация скачанного файла (контракт публикации:
        //  close → validate → rename; битое содержимое не публикуется)
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>Отказ валидации: файл не является обещанным аудио.</summary>
        private class FileValidationException : Exception
        {
            public string ErrorCode { get; }

            public FileValidationException(string errorCode, string message)
                : base(message)
            {
                ErrorCode = errorCode;
            }
        }

        /// <summary>
        ///   Проверяет скачанный файл перед публикацией: размер должен точно
        ///   совпадать с заявленным (если известен), магические байты —
        ///   соответствовать расширению контейнера. Для неизвестных расширений
        ///   минимум отклоняются HTML/JSON-подобные payload. Память ограничена
        ///   заголовком в 32 байта (+ точный seek для ID3-префикса FLAC).
        /// </summary>
        private static void ValidateDownloadedFile(string filePath, string extension, long expectedSizeBytes)
        {
            var name = Path.GetFileName(filePath);
            var info = new FileInfo(filePath);
            var actualSize = info.Exists ? info.Length : 0L;

            if (actualSize <= 0L)
            {
                throw new FileValidationException("VALIDATION_EMPTY", $"Downloaded file is empty: {name}");
            }

            if (expectedSizeBytes > 0L && actualSize != expectedSizeBytes)
            {
                // Меньше — обрыв передачи; больше — ошибка resume/счётчиков.
                // Равенство — необходимое, но недостаточное условие.
                var code = actualSize < expectedSizeBytes ? "VALIDATION_INCOMPLETE" : "VALIDATION_SIZE_MISMATCH";
                throw new FileValidationException(
                    code,
                    $"Downloaded size {actualSize} does not match expected {expectedSizeBytes}: {name}");
            }

            var header = new byte[32];
            int read;
            using (var stream = IOFile.OpenRead(filePath))
            {
                read = stream.Read(header, 0, header.Length);
            }

            if (read <= 0)
            {
                throw new FileValidationException("VALIDATION_EMPTY", $"Could not read file header: {name}");
            }

            var ext = (extension ?? string.Empty).TrimStart('.').ToLowerInvariant();
            switch (ext)
            {
                case "flac":
                    ValidateFlac(filePath, name);
                    break;
                case "mp3":
                    ValidateMp3(header, read, name);
                    break;
                case "ogg":
                case "oga":
                case "opus":
                    RequireMagic(header, read, 0, "OggS", name);
                    break;
                case "mp4":
                case "m4a":
                case "m4b":
                    RequireMagic(header, read, 4, "ftyp", name);
                    break;
                case "wav":
                    RequireMagic(header, read, 0, "RIFF", name);
                    break;
                case "ape":
                    RequireMagic(header, read, 0, "MAC ", name);
                    break;
                case "wv":
                    RequireMagic(header, read, 0, "wvpk", name);
                    break;
                case "dsf":
                    RequireMagic(header, read, 0, "DSD ", name);
                    break;
                case "dff":
                    RequireMagic(header, read, 0, "FRM8", name);
                    break;
                default:
                    RejectTextPayload(header, read, name);
                    break;
            }
        }

        /// <summary>
        ///   FLAC: маркер fLaC в начале потока; явно поддержан ID3v2-префикс
        ///   (тег пропускается по synchsafe-размеру, за ним обязан идти fLaC).
        /// </summary>
        private static void ValidateFlac(string filePath, string name)
        {
            using var stream = IOFile.OpenRead(filePath);
            var head = new byte[10];
            var n = stream.Read(head, 0, head.Length);
            if (n >= 4 && HasMagic(head, 0, "fLaC"))
            {
                return;
            }

            if (n >= 10 && HasMagic(head, 0, "ID3"))
            {
                var tagSize = ((head[6] & 0x7F) << 21) | ((head[7] & 0x7F) << 14)
                    | ((head[8] & 0x7F) << 7) | (head[9] & 0x7F);
                stream.Seek(10L + tagSize, SeekOrigin.Begin);
                var probe = new byte[4];
                var m = stream.Read(probe, 0, probe.Length);
                if (m == 4 && HasMagic(probe, 0, "fLaC"))
                {
                    return;
                }
            }

            throw new FileValidationException("VALIDATION_FORMAT", $"Not a FLAC stream (missing fLaC marker): {name}");
        }

        /// <summary>MP3: ID3v2-тег или MPEG frame sync (0xFF 0xEx/0xFx).</summary>
        private static void ValidateMp3(byte[] header, int read, string name)
        {
            if (read >= 3 && HasMagic(header, 0, "ID3"))
            {
                return;
            }

            if (read >= 2 && header[0] == 0xFF && (header[1] & 0xE0) == 0xE0)
            {
                return;
            }

            throw new FileValidationException(
                "VALIDATION_FORMAT",
                $"Not an MP3 stream (missing ID3 tag or frame sync): {name}");
        }

        /// <summary>Неизвестное расширение: минимум отсекаем HTML/JSON-подобный ответ.</summary>
        private static void RejectTextPayload(byte[] header, int read, string name)
        {
            int i = 0;
            while (i < read && (header[i] == (byte)' ' || header[i] == (byte)'\t'
                || header[i] == (byte)'\r' || header[i] == (byte)'\n'))
            {
                i++;
            }

            if (i >= read)
            {
                throw new FileValidationException("VALIDATION_FORMAT", $"File header is whitespace-only: {name}");
            }

            var first = header[i];
            if (first == (byte)'{' || first == (byte)'[')
            {
                throw new FileValidationException("VALIDATION_FORMAT", $"Payload looks like JSON, not audio: {name}");
            }

            var probe = System.Text.Encoding.ASCII
                .GetString(header, i, Math.Min(16, read - i))
                .ToLowerInvariant();
            if (probe.StartsWith("<html") || probe.StartsWith("<!doctype"))
            {
                throw new FileValidationException("VALIDATION_FORMAT", $"Payload looks like HTML, not audio: {name}");
            }
        }

        private static bool HasMagic(byte[] buffer, int offset, string magic)
        {
            if (buffer.Length < offset + magic.Length)
            {
                return false;
            }

            for (int i = 0; i < magic.Length; i++)
            {
                if (buffer[offset + i] != (byte)magic[i])
                {
                    return false;
                }
            }

            return true;
        }

        private static void RequireMagic(byte[] header, int read, int offset, string magic, string name)
        {
            if (read >= offset + magic.Length && HasMagic(header, offset, magic))
            {
                return;
            }

            throw new FileValidationException(
                "VALIDATION_FORMAT",
                $"File does not look like {magic.Trim()} audio (bad magic bytes): {name}");
        }

        /// <summary>Лучше-усилие удаление файла; ошибка не маскирует исходный отказ.</summary>
        private static void TryDeleteFile(string path)
        {
            try
            {
                if (path != null && IOFile.Exists(path))
                {
                    IOFile.Delete(path);
                }
            }
            catch
            {
                // Повторная попытка загрузки перезапишет остаток.
            }
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
            // Soulseek.NET заворачивает сетевые сбои: SocketException →
            // ConnectionException → SoulseekClientException("Failed to connect"),
            // поэтому проверяем всю цепочку InnerException, а не только верхний тип.
            for (var e = ex; e != null; e = e.InnerException)
            {
                if (e is LoginRejectedException)
                {
                    return false;
                }

                if (e is TimeoutException
                    || e is SocketException
                    || e is AddressException
                    || e is ConnectionException)
                {
                    return true;
                }
            }

            return false;
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
