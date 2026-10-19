// <copyright file="SoulseekBridgeCore.cs">
//   Ядро адаптера протокола Soulseek без привязки к платформе.
//   Android: JNI-обёртка SoulseekBridge (AAR, форк Soulseek.NET из SeekerAndroid,
//   символ SEEKER_FORK). Windows: экспорты NativeExports (desktop/, оригинальный
//   NuGet Soulseek 10.0.2). Аудиобайты никогда не проходят через мост — только
//   метаданные и команды.
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
    using Soulseek;

    // Aliases чтобы избежать конфликта между Soulseek.File/Soulseek.Directory и System.IO.
    using IOFile = System.IO.File;
    using IODirectory = System.IO.Directory;
    using SlskFile = Soulseek.File;

    /// <summary>Платформенные различия поведения ядра.</summary>
    public sealed class BridgeHostOptions
    {
        /// <summary>
        ///   Client minor version при логине. Лицензия Soulseek.NET требует уникальный
        ///   номер для каждого приложения (760–7699999 занят slskd).
        /// </summary>
        public int ClientMinorVersion { get; set; }

        /// <summary>
        ///   true — мост сам переименовывает проверенный .part в финальный файл (Android).
        ///   false — downloadComplete приходит с путём .part, публикацию делает хост
        ///   после закрытия своих читателей (Windows: открытый на чтение файл нельзя
        ///   переименовать).
        /// </summary>
        public bool PublishOnComplete { get; set; } = true;

        /// <summary>
        ///   true — .part открывается с FileShare.Read | FileShare.Delete, чтобы его
        ///   можно было читать во время загрузки (Windows). Библиотека по умолчанию
        ///   открывает файл с FileShare.None.
        /// </summary>
        public bool ShareOutputForReading { get; set; }
    }

    /// <summary>
    ///   Адаптер протокола Soulseek. Каждый метод принимает JSON-строку и возвращает
    ///   JSON-строку ResultDto; исключения наружу не выходят. Долгие операции
    ///   (download) идут в фоне; прогресс и завершение приходят событиями.
    /// </summary>
    public sealed class SoulseekBridgeCore
    {
        // Fallback IP сервера Soulseek при неудачном DNS-резолвинге (как в SeekerAndroid).
        private const string FallbackServerIp = "208.76.170.59";

        private const string ServerAddress = "server.slsknet.org";

        private const int ServerPort = 2242;

        // 250ms throttle для прогресс-событий (≈4 раза/сек) в тиках.
        private const long ProgressThrottleTicks = 2_500_000;

        // Период проверки дедлайна / окна тишины в SearchAsync.
        private const int SearchWatchdogTickMs = 200;

        // Опрос места в очереди пира, пока загрузка стоит в Queued|Remotely:
        // первый — вскоре после постановки, затем раз в минуту. Ответ ждём
        // дольше таймаута сообщений клиента (30 с), чтобы молчание пира
        // пришло как его TimeoutException.
        private const int QueueFirstCheckDelayMs = 5_000;
        private const int QueueCheckIntervalMs = 60_000;
        private const int QueueCheckTimeoutMs = 45_000;

        private static readonly JsonSerializerOptions JsonOpts = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
        };

        private static readonly string[] LosslessExtensions = { "flac", "alac", "wav", "ape", "wv", "dsd", "dsf", "dff" };

        // Аудио-расширения по умолчанию: если фильтр расширений пуст, картинки/cue/log/nfo
        // из папок альбомов отсекаются, чтобы не занимать fileLimit и не гонять их через мост.
        private static readonly HashSet<string> AudioExtensions = new HashSet<string>
        {
            "mp3", "flac", "ogg", "oga", "opus", "m4a", "aac", "alac", "wav", "aif", "aiff",
            "ape", "wv", "wma", "mpc", "dsf", "dff",
        };

        private readonly Action<string> _emit;
        private readonly Action<string> _log;
        private readonly BridgeHostOptions _host;

        private SoulseekClient _client;

        // downloadId → CancellationTokenSource для отмены.
        private readonly ConcurrentDictionary<string, CancellationTokenSource> _downloadCts = new();

        // requestId → CancellationTokenSource идущего поиска (cancelSearch).
        private readonly ConcurrentDictionary<string, CancellationTokenSource> _searchCts = new();

        // downloadId → throttle-метка последнего прогресс-события (DateTime.UtcNow.Ticks).
        private readonly ConcurrentDictionary<string, long> _lastProgressTick = new();

        // (username, filename) → downloadId для маппинга глобальных transfer-событий.
        private readonly ConcurrentDictionary<string, string> _transferKeyToDownloadId = new();

        // downloadId → опрос места в очереди пира (пока Queued|Remotely).
        private readonly ConcurrentDictionary<string, QueueMonitor> _queueMonitors = new();

        /// <param name="emit">Получатель событий (JSON SoulseekEventDto); вызывается из любых потоков.</param>
        /// <param name="log">Диагностический лог.</param>
        public SoulseekBridgeCore(Action<string> emit, Action<string> log, BridgeHostOptions host)
        {
            _emit = emit ?? (_ => { });
            _log = log ?? (_ => { });
            _host = host ?? throw new ArgumentNullException(nameof(host));

            // minorVersion > 100 требуется конструктором SoulseekClient.
            if (_host.ClientMinorVersion <= 100)
            {
                throw new ArgumentOutOfRangeException(nameof(host), "ClientMinorVersion must be > 100");
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Connect
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Подключается к серверу Soulseek и логинится.
        ///   jsonAccount: AccountOptions JSON {username, password, listenPort, ...}.
        /// </summary>
        public async Task<string> ConnectAsync(string jsonAccount)
        {
            try
            {
                return await ConnectCoreAsync(jsonAccount).ConfigureAwait(false);
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

            // Освобождаем предыдущий клиент если был. Сначала отцепляем его от
            // _client: события Disconnecting/Disconnected старого клиента
            // отфильтровываются в обработчиках и не выглядят как обрыв нового.
            var previous = _client;
            _client = null;
            previous?.Dispose();

            var client = new SoulseekClient(_host.ClientMinorVersion, CreateClientOptions(opts, listenPort));
            _client = client;

            // Подписка на глобальные события клиента.
            WireClientEvents(client);

            try
            {
#if SEEKER_FORK
                // ConnectAsync(username, password) → подключается к серверу по умолчанию
                // (server.slsknet.org:2242) через addressResolver форка и выполняет login.
                await client.ConnectAsync(opts.Username, opts.Password).ConfigureAwait(false);
#else
                // В оригинальной библиотеке нет addressResolver: резолвим сами (IPv4,
                // таймаут, фолбэк на IP) и подключаемся по адресу.
                var address = await ResolveAddressAsync(ServerAddress).ConfigureAwait(false);
                await client.ConnectAsync(address.ToString(), ServerPort, opts.Username, opts.Password).ConfigureAwait(false);
#endif
            }
            catch
            {
                if (ReferenceEquals(_client, client))
                {
                    _client = null;
                }

                client.Dispose();
                throw;
            }

            var data = JsonSerializer.Serialize(new
            {
                username = opts.Username,
                state = client.State.ToString(),
            }, JsonOpts);
            return SuccessJson(data);
        }

        // Распределённая сеть выключена: она нужна, чтобы получать и
        // пересылать чужие поисковые запросы (родитель + до 25 «детей»), а
        // раздачи у нас нет — это только фоновые соединения и трафик, в т.ч.
        // через VPN-туннель на телефоне. Собственные поиски идут через сервер
        // и от этого не зависят.
        private static SoulseekClientOptions CreateClientOptions(AccountOptions opts, int listenPort)
        {
#if SEEKER_FORK
            return new SoulseekClientOptions(
                enableListener: opts.EnableListener,
                listenPort: listenPort,
                enableDistributedNetwork: false,
                acceptDistributedChildren: false,
                messageTimeout: opts.MessageTimeoutMs,
                maximumConcurrentSearches: 5,
                maximumConcurrentDownloads: int.MaxValue,
                // Upload slots управляются Kotlin-стороной; отдаём max.
                maximumConcurrentUploads: int.MaxValue,
                addressResolver: ResolveAddressAsync);
#else
            // Раздельные настройки соединений по образцу slskd: серверное соединение
            // не рвётся по бездействию (keepalive вместо inactivity timeout),
            // трансферы — с большими буферами и более терпеливым таймаутом
            // (медленные пиры), пиры и distributed — на умеренных значениях.
            return new SoulseekClientOptions(
                enableListener: opts.EnableListener,
                listenPort: listenPort,
                enableDistributedNetwork: false,
                acceptDistributedChildren: false,
                messageTimeout: opts.MessageTimeoutMs,
                maximumConcurrentSearches: 5,
                maximumConcurrentDownloads: int.MaxValue,
                // Раздачи нет: отдавать некому, слоты не нужны.
                maximumConcurrentUploads: 1,
                serverConnectionOptions: new ConnectionOptions(
                    connectTimeout: 10000,
                    inactivityTimeout: -1,
                    configureSocket: EnableKeepAlive),
                peerConnectionOptions: new ConnectionOptions(
                    connectTimeout: 10000,
                    inactivityTimeout: 15000),
                transferConnectionOptions: new ConnectionOptions(
                    readBufferSize: 262144,
                    writeBufferSize: 262144,
                    connectTimeout: 15000,
                    inactivityTimeout: 30000),
                incomingConnectionOptions: new ConnectionOptions(
                    connectTimeout: 10000,
                    inactivityTimeout: 15000),
                distributedConnectionOptions: new ConnectionOptions(
                    connectTimeout: 10000,
                    inactivityTimeout: 60000));
#endif
        }

#if !SEEKER_FORK
        /// <summary>TCP keepalive серверного сокета: обрыв сети обнаруживается за ~минуту.</summary>
        private static void EnableKeepAlive(Socket socket)
        {
            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime, 15);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveInterval, 15);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveRetryCount, 3);
        }
#endif

        // ─────────────────────────────────────────────────────────────────────
        //  Search
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Выполняет поиск по сети Soulseek.
        ///   jsonRequest: SearchRequestDto JSON {requestId, query, timeoutMs, filters}.
        ///   Возвращает ResultDto JSON с data = SearchResultDto[] JSON.
        /// </summary>
        public async Task<string> SearchAsync(string jsonRequest)
        {
            try
            {
                return await SearchCoreAsync(jsonRequest).ConfigureAwait(false);
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

            var client = EnsureConnected();

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
                var searchTask = client.SearchAsync(
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
                // Диагностика для замеров: почему и когда остановился поиск.
                long first = Interlocked.Read(ref firstResponseTicks);
                _log(
                    $"search stop={stopReason} elapsed={(DateTime.UtcNow - startedAt).TotalMilliseconds:F0}ms "
                    + $"firstResponse={(first == 0 ? "none" : ((first - startedAt.Ticks) / TimeSpan.TicksPerMillisecond) + "ms")} "
                    + $"responses={responseCount} files={results.Count}");

                data = JsonSerializer.Serialize(results, JsonOpts);
            }

            return SuccessJson(data);
        }

        /// <summary>
        ///   Отменяет идущий поиск по requestId. Накопленное к этому моменту вернёт
        ///   исходный вызов SearchAsync. false — поиск уже завершён или неизвестен.
        /// </summary>
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
        public async Task<string> GetDirectoryContentsAsync(string jsonRequest)
        {
            try
            {
                return await GetDirectoryContentsCoreAsync(jsonRequest).ConfigureAwait(false);
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

            var client = EnsureConnected();

            using var cts = new CancellationTokenSource(req.TimeoutMs > 0 ? req.TimeoutMs : 20000);
            var directories = await client
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
#if SEEKER_FORK
                    var file = new SlskFile(f.Code, fullName, f.Size, f.Extension, f.Attributes, f.IsLatin1Decoded, dir.DecodedViaLatin1);
#else
                    var file = new SlskFile(f.Code, fullName, f.Size, f.Extension, f.Attributes);
#endif
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

            _log($"folder contents user={req.Username} dirs={directories.Count} audio={results.Count}");

            return SuccessJson(JsonSerializer.Serialize(results, JsonOpts));
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Download
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Запускает загрузку файла в фоновую задачу.
        ///   jsonRequest: DownloadRequestDto JSON.
        ///   Возвращает немедленно ResultDto с data = downloadId (download started).
        ///   Прогресс и завершение приходят событиями.
        ///   Использует .part файл (+ atomic rename при PublishOnComplete) для resume.
        /// </summary>
        public string StartDownload(string jsonRequest)
        {
            try
            {
                var dto = JsonSerializer.Deserialize<DownloadRequestDto>(jsonRequest, JsonOpts)
                    ?? throw new ArgumentException("Invalid download request JSON");

                ValidateDownloadRequest(dto);
                var client = EnsureConnected();

                var cts = new CancellationTokenSource();
                // Тот же downloadId ещё не отпущен прошлым запуском (Android переиспользует
                // id при resume): прошлый запуск вытесняется, его cleanup не тронет новый.
                // Два писателя одного .part испортили бы файл — прошлый отменяем.
                CancellationTokenSource previous = null;
                _downloadCts.AddOrUpdate(dto.DownloadId, cts, (_, old) =>
                {
                    previous = old;
                    return cts;
                });
                try
                {
                    previous?.Cancel();
                }
                catch (ObjectDisposedException)
                {
                }
                _transferKeyToDownloadId[TransferKey(dto.PeerUsername, dto.RemoteFilename)] = dto.DownloadId;

                // Fire-and-forget: вся долгая работа в фоне.
                _ = Task.Run(() => DownloadToFileCoreAsync(client, dto, cts));

                return SuccessJson(JsonSerializer.Serialize(dto.DownloadId));
            }
            catch (Exception ex)
            {
                // Клиент переподключается после обрыва сети — retry-loop Kotlin
                // повторит, когда сессия восстановится.
                return ErrorJson(ex, retryable: ex is ClientNotReadyException);
            }
        }

        private async Task DownloadToFileCoreAsync(SoulseekClient client, DownloadRequestDto dto, CancellationTokenSource cts)
        {
            var ct = cts.Token;
            string partPath = null;
            string finalPath = null;
            try
            {
                // Санитизация и подготовка путей.
                var safeDir = SanitizeDirectory(dto.LocalDirectory);
                IODirectory.CreateDirectory(safeDir);

                var safeCacheKey = SanitizeFilename(dto.CacheKey);
                var safeExtension = SanitizeFilename(dto.FileExtension ?? "dat");

                if (string.IsNullOrEmpty(dto.PartPath))
                {
                    partPath = Path.Combine(safeDir, safeCacheKey + ".part");
                }
                else
                {
                    partPath = Path.Combine(SanitizeDirectory(Path.GetDirectoryName(dto.PartPath)), SanitizeFilename(Path.GetFileName(dto.PartPath)));
                    IODirectory.CreateDirectory(Path.GetDirectoryName(partPath));
                }

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
                        EmitComplete(dto.DownloadId, Publish(partPath, finalPath), dto.SizeBytes, dto.SizeBytes);
                        return;
                    }
                }

                // TransferOptions: stateChanged + progressUpdated с throttle 250ms.
                var transferOptions = new TransferOptions(
                    stateChanged: args => OnTransferStateChanged(dto.DownloadId, cts, args.Transfer, args.PreviousState),
                    progressUpdated: args => OnTransferProgress(dto.DownloadId, args.Transfer),
                    disposeOutputStreamOnCompletion: true,
                    seekOutputStreamAutomatically: true);

                long? size = dto.SizeBytes > 0 ? dto.SizeBytes : (long?)null;
                Transfer transfer;
                if (_host.ShareOutputForReading)
                {
                    // Тот же режим, что у DownloadAsync(localFilename) — append при
                    // startOffset > 0, create при 0, — но файл остаётся доступным на
                    // чтение (стриминг во время загрузки) и удаление.
                    var path = partPath;
                    var offset = startOffset;
                    var mode = startOffset > 0 ? FileMode.Append : FileMode.Create;
                    transfer = await client.DownloadAsync(
                        dto.PeerUsername,
                        dto.RemoteFilename,
                        () =>
                        {
                            // Поток открывается, когда пир принял запрос (может быть через
                            // минуты): .part мог измениться или исчезнуть. Иначе дописали бы
                            // не с того места (или с дырой из нулей) — пусть retry
                            // перемеряет offset.
                            var current = IOFile.Exists(path) ? new FileInfo(path).Length : 0L;
                            if (offset > 0 && current != offset)
                            {
                                throw new PartFileChangedException(
                                    $"partial file changed from {offset} to {current} bytes before the transfer started");
                            }

                            return Task.FromResult<Stream>(new FileStream(path, mode, FileAccess.Write, FileShare.Read | FileShare.Delete));
                        },
                        size: size,
                        startOffset: startOffset,
                        options: transferOptions,
                        cancellationToken: ct).ConfigureAwait(false);
                }
                else
                {
                    // Soulseek.NET сам управляет FileStream: append при startOffset > 0, create при 0.
                    transfer = await client.DownloadAsync(
                        dto.PeerUsername,
                        dto.RemoteFilename,
                        partPath,
                        size: size,
                        startOffset: startOffset,
                        options: transferOptions,
                        cancellationToken: ct).ConfigureAwait(false);
                }

                // Единая валидация ДО публикации: размер точно равен заявленному
                // (если известен), магические байты соответствуют расширению;
                // HTML/JSON-payload отклоняется. Повреждённый файл не публикуется.
                var expectedSize = dto.SizeBytes > 0
                    ? dto.SizeBytes
                    : (transfer.Size > 0 ? transfer.Size : 0L);
                ValidateDownloadedFile(partPath, safeExtension, expectedSize);

                EmitComplete(dto.DownloadId, Publish(partPath, finalPath), transfer.BytesTransferred, transfer.Size);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
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
                _log($"transfer {dto.DownloadId} invalid file peer={dto.PeerUsername}: {vex.ErrorCode}: {vex.Message}");
                TryDeleteFile(partPath);
                if (_host.PublishOnComplete)
                {
                    // На Windows финальный файл публикует хост; здесь мог лежать
                    // уже проверенный кэш того же ключа — не трогаем его.
                    TryDeleteFile(finalPath);
                }
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
                _log($"transfer {dto.DownloadId} failed peer={dto.PeerUsername}: {ex.GetType().Name}: {ex.Message}");
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
                CleanupDownload(dto.DownloadId, cts, dto.PeerUsername, dto.RemoteFilename);
            }
        }

        /// <summary>
        ///   Публикация проверенного файла: atomic rename .part → final (Android) или
        ///   путь .part как есть — его опубликует хост (Windows). Возвращает путь
        ///   для события downloadComplete.
        /// </summary>
        private string Publish(string partPath, string finalPath)
        {
            if (!_host.PublishOnComplete)
            {
                return partPath;
            }

            AtomicRename(partPath, finalPath);
            return finalPath;
        }

        private void EmitComplete(string downloadId, string localPath, long bytesReceived, long totalBytes)
        {
            EmitEvent(new SoulseekEventDto
            {
                EventType = "downloadComplete",
                DownloadId = downloadId,
                State = nameof(TransferStates.Succeeded),
                BytesReceived = bytesReceived,
                TotalBytes = totalBytes,
                LocalPath = localPath,
            });
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Cancel Transfer
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Отменяет активную загрузку по downloadId.
        ///   transferId: JSON-строка с downloadId.
        /// </summary>
        public string CancelTransfer(string transferId)
        {
            try
            {
                var downloadId = JsonSerializer.Deserialize<string>(transferId, JsonOpts)
                    ?? transferId?.Trim('"');

                if (string.IsNullOrEmpty(downloadId))
                {
                    throw new ArgumentException("downloadId is required");
                }

                // Только отмена: запись удалит и CTS освободит сама задача загрузки
                // (CleanupDownload), когда размотается, — токен ей ещё нужен.
                if (_downloadCts.TryGetValue(downloadId, out var cts))
                {
                    try
                    {
                        cts.Cancel();
                    }
                    catch (ObjectDisposedException)
                    {
                    }
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
        public async Task<string> ConfigureSharingAsync(string jsonConfig)
        {
            try
            {
                var cfg = JsonSerializer.Deserialize<SharingConfigDto>(jsonConfig, JsonOpts)
                    ?? throw new ArgumentException("Invalid sharing config JSON");

                var client = _client
                    ?? throw new InvalidOperationException("Client not initialized; call connectAsync first");

                // SoulseekClientOptionsPatch позволяет частичное переопределение опций.
                var patch = new SoulseekClientOptionsPatch(
                    enableListener: cfg.EnableListener,
                    listenPort: cfg.ListenPort,
                    maximumUploadSpeed: cfg.MaximumUploadSpeed,
                    maximumDownloadSpeed: cfg.MaximumDownloadSpeed);

                await client.ReconfigureOptionsAsync(patch).ConfigureAwait(false);

                return SuccessJson(null);
            }
            catch (Exception ex)
            {
                return ErrorJson(ex, retryable: false);
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Shutdown
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        ///   Отменяет загрузки и освобождает клиент. Новый Connect создаст новый клиент.
        /// </summary>
        public void Shutdown()
        {
            try
            {
                // Отменяем все активные загрузки.
                // CTS освобождают сами задачи загрузки (CleanupDownload).
                foreach (var pair in _downloadCts)
                {
                    try { pair.Value.Cancel(); } catch { }
                }

                _downloadCts.Clear();
                _transferKeyToDownloadId.Clear();
                _lastProgressTick.Clear();

                foreach (var pair in _searchCts)
                {
                    try { pair.Value.Cancel(); } catch { }
                }

                var client = _client;
                _client = null;
                client?.Dispose();
            }
            catch
            {
                // best-effort
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        //  Внутренние хелперы — события клиента
        // ─────────────────────────────────────────────────────────────────────

        private void WireClientEvents(SoulseekClient client)
        {
            // StateChanged: переходы между SoulseekClientStates (Disconnected → Connected → LoggedIn).
            client.StateChanged += (sender, e) =>
            {
                // Освобождённый (заменённый) клиент — не текущее соединение.
                if (!ReferenceEquals(sender, _client))
                {
                    return;
                }

                EmitEvent(new SoulseekEventDto
                {
                    EventType = "clientStateChanged",
                    State = e.State.ToString(),
                    Message = e.Message,
                    ErrorCode = e.Exception?.GetType().Name,
                    ExceptionMessage = e.Exception?.Message,
                });
            };

            // Disconnected: сервер разорвал соединение. errorCode — тип причины:
            // хост решает по нему, переподключаться ли (не после выхода
            // пользователя, неверного пароля и входа тем же ником с другого устройства).
            client.Disconnected += (sender, e) =>
            {
                if (!ReferenceEquals(sender, _client))
                {
                    return;
                }

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

            // Отказ и сбой со стороны пира — для диагностики «почему не качается»
            // (сама загрузка завершится исключением в DownloadToFileCoreAsync).
            client.DownloadDenied += (sender, e) =>
                _log($"peer {e.Username} denied {ShortName(e.Filename)}: {e.Message}");
            client.DownloadFailed += (sender, e) =>
                _log($"peer {e.Username} reported failure for {ShortName(e.Filename)}");

            // Потоковые результаты поиска (searchProgress) шлёт SearchCoreAsync —
            // там известны requestId и фильтры конкретного запроса.
        }

        private void OnTransferStateChanged(string downloadId, CancellationTokenSource owner, Transfer transfer, TransferStates previousState)
        {
            var state = transfer.State;
            string eventType;

            _log($"transfer {downloadId} {previousState} -> {state} peer={transfer.Username} bytes={transfer.BytesTransferred}");

            // Очередь у пира: опрашиваем место, пока файл в ней стоит.
            if (state == (TransferStates.Queued | TransferStates.Remotely))
            {
                StartQueueMonitor(downloadId, owner, transfer.Username, transfer.Filename);
            }
            else
            {
                StopQueueMonitor(downloadId, owner);
            }

            // Completed всегда сопровождается Succeeded/Cancelled/TimedOut/Errored/Rejected/Aborted.
            if (state.HasFlag(TransferStates.Completed))
            {
                // Успех и неудача обрабатываются в DownloadToFileCoreAsync (валидация +
                // публикация; DownloadAsync бросает исключение при неуспехе) — там же
                // одно терминальное событие с верной retryable-классификацией
                // (TimedOut не входит в Errored, здесь он считался бы окончательным).
                return;
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
            // Попытка уже завершена (поздний колбэк) — не воскрешаем её запись.
            if (!_downloadCts.ContainsKey(downloadId))
            {
                return;
            }

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
        //  Очередь у пира
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>Опрос очереди пира, принадлежащий попытке загрузки [Owner].</summary>
        private sealed class QueueMonitor
        {
            public QueueMonitor(CancellationTokenSource owner, CancellationTokenSource cts)
            {
                Owner = owner;
                Cts = cts;
            }

            public CancellationTokenSource Owner { get; }

            public CancellationTokenSource Cts { get; }
        }

        /// <summary>
        ///   Запускает опрос места в очереди пира для попытки [owner]. Пока
        ///   файл стоит в Queued|Remotely, пир сам не сообщает ничего, кроме
        ///   (иногда) места — без опроса не отличить движущуюся очередь от
        ///   зависшей или от ушедшего из сети пира.
        /// </summary>
        private void StartQueueMonitor(string downloadId, CancellationTokenSource owner, string username, string filename)
        {
            CancellationTokenSource cts;
            try
            {
                cts = CancellationTokenSource.CreateLinkedTokenSource(owner.Token);
            }
            catch (ObjectDisposedException)
            {
                return;
            }

            var monitor = new QueueMonitor(owner, cts);
            QueueMonitor previous = null;
            var added = false;
            _queueMonitors.AddOrUpdate(
                downloadId,
                _ =>
                {
                    added = true;
                    return monitor;
                },
                (_, old) =>
                {
                    // Опрос этой попытки уже идёт — оставляем его.
                    if (ReferenceEquals(old.Owner, owner))
                    {
                        added = false;
                        return old;
                    }

                    previous = old;
                    added = true;
                    return monitor;
                });

            if (!added)
            {
                cts.Dispose();
                return;
            }

            CancelMonitor(previous);
            _ = Task.Run(() => MonitorQueueAsync(downloadId, monitor, username, filename));
        }

        /// <summary>Останавливает опрос очереди попытки [owner] (не чужой).</summary>
        private void StopQueueMonitor(string downloadId, CancellationTokenSource owner)
        {
            if (_queueMonitors.TryGetValue(downloadId, out var monitor) &&
                ReferenceEquals(monitor.Owner, owner) &&
                _queueMonitors.TryRemove(new KeyValuePair<string, QueueMonitor>(downloadId, monitor)))
            {
                CancelMonitor(monitor);
            }
        }

        private static void CancelMonitor(QueueMonitor monitor)
        {
            try
            {
                monitor?.Cts.Cancel();
            }
            catch (ObjectDisposedException)
            {
            }
        }

        private async Task MonitorQueueAsync(string downloadId, QueueMonitor monitor, string username, string filename)
        {
            var ct = monitor.Cts.Token;
            try
            {
                await Task.Delay(QueueFirstCheckDelayMs, ct).ConfigureAwait(false);
                while (!ct.IsCancellationRequested)
                {
                    var client = _client;
                    if (client == null)
                    {
                        return;
                    }

                    int? place = null;
                    string status;
                    string error = null;
                    using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct))
                    {
                        timeout.CancelAfter(QueueCheckTimeoutMs);
                        try
                        {
                            place = await client.GetDownloadPlaceInQueueAsync(username, filename, timeout.Token).ConfigureAwait(false);
                            status = "ok";
                        }
                        catch (OperationCanceledException) when (ct.IsCancellationRequested)
                        {
                            return;
                        }
                        catch (TransferNotFoundException)
                        {
                            // Загрузка уже не в очереди (началась или закончилась).
                            return;
                        }
                        catch (UserOfflineException ex)
                        {
                            status = "offline";
                            error = ex.Message;
                        }
                        catch (Exception ex) when (ex is TimeoutException || ex is OperationCanceledException)
                        {
                            status = "noResponse";
                            error = ex.Message;
                        }
                        catch (Exception ex)
                        {
                            status = "unreachable";
                            error = ex.InnerException?.Message ?? ex.Message;
                        }
                    }

                    if (ct.IsCancellationRequested)
                    {
                        return;
                    }

                    _log(place.HasValue
                        ? $"queue {downloadId} peer={username} place={place.Value}"
                        : $"queue {downloadId} peer={username} {status}: {error}");
                    EmitEvent(new SoulseekEventDto
                    {
                        EventType = "transferQueueInfo",
                        DownloadId = downloadId,
                        State = (TransferStates.Queued | TransferStates.Remotely).ToString(),
                        PlaceInQueue = place,
                        QueueStatus = status,
                        ExceptionMessage = error,
                    });

                    await Task.Delay(QueueCheckIntervalMs, ct).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception ex)
            {
                _log($"queue {downloadId} monitor stopped: {ex.Message}");
            }
            finally
            {
                _queueMonitors.TryRemove(new KeyValuePair<string, QueueMonitor>(downloadId, monitor));
                monitor.Cts.Dispose();
            }
        }

        /// <summary>Имя файла из пути пира (разделитель — обычно '\').</summary>
        private static string ShortName(string remoteFilename)
        {
            if (string.IsNullOrEmpty(remoteFilename))
            {
                return remoteFilename;
            }

            var i = remoteFilename.LastIndexOfAny(new[] { '\\', '/' });
            return i >= 0 ? remoteFilename.Substring(i + 1) : remoteFilename;
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

            // partPath (если задан) — абсолютный путь без traversal.
            if (!string.IsNullOrEmpty(dto.PartPath)
                && (!Path.IsPathRooted(dto.PartPath) || HasTraversalSegment(dto.PartPath)
                    || string.IsNullOrEmpty(Path.GetFileName(dto.PartPath))))
            {
                throw new ArgumentException("partPath must be an absolute file path without traversal");
            }
        }

        private static string SanitizeDirectory(string dir)
        {
            // Запрет traversal в директории.
            if (HasTraversalSegment(dir))
            {
                throw new ArgumentException("localDirectory must not contain path traversal");
            }

            return Path.GetFullPath(dir);
        }

        /// <summary>
        ///   Сегмент пути ".." (а не подстрока: "C:\Music\Artist..." — законный путь).
        /// </summary>
        private static bool HasTraversalSegment(string path)
        {
            foreach (var segment in path.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))
            {
                if (segment == "..")
                {
                    return true;
                }
            }

            return false;
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

        /// <summary>.part изменился между замером offset и открытием потока.</summary>
        /// <summary>Клиент не создан или не залогинен (в т.ч. переподключается).</summary>
        private sealed class ClientNotReadyException : InvalidOperationException
        {
            public ClientNotReadyException(string message)
                : base(message)
            {
            }
        }

        private sealed class PartFileChangedException : IOException
        {
            public PartFileChangedException(string message)
                : base(message)
            {
            }
        }

        /// <summary>Отказ валидации: файл не является обещанным аудио.</summary>
        private sealed class FileValidationException : Exception
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
            using (var stream = OpenForValidation(filePath))
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
        ///   Чтение для проверки, не мешающее параллельным читателям (стриминг)
        ///   и последующему переименованию/удалению.
        /// </summary>
        private static FileStream OpenForValidation(string filePath) =>
            new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);

        /// <summary>
        ///   FLAC: маркер fLaC в начале потока; явно поддержан ID3v2-префикс
        ///   (тег пропускается по synchsafe-размеру, за ним обязан идти fLaC).
        /// </summary>
        private static void ValidateFlac(string filePath, string name)
        {
            using var stream = OpenForValidation(filePath);
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

        private SoulseekClient EnsureConnected()
        {
            var client = _client;
            if (client == null)
            {
                throw new ClientNotReadyException("Client not initialized; call connectAsync first");
            }

            if (!client.State.HasFlag(SoulseekClientStates.Connected) || !client.State.HasFlag(SoulseekClientStates.LoggedIn))
            {
                throw new ClientNotReadyException($"Client must be connected and logged in (currently: {client.State})");
            }

            return client;
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

            // Библиотека заворачивает причину в SoulseekClientException("Failed to
            // download …"), кроме UserOffline и Timeout — смотрим всю цепочку.
            // Отказ пира, несовпадение размера и отказ, о котором сообщил пир, —
            // окончательные: повтор у того же пира даст тот же результат.
            // Обрыв соединения (ConnectionException: «Connection reset by peer»
            // при падении VPN/смене сети) — временный: на Android раньше считался
            // окончательным, и retry-loop Kotlin не запускался.
            for (var e = ex; e != null; e = e.InnerException)
            {
                if (e is TransferRejectedException
                    || e is TransferSizeMismatchException
                    || e is TransferReportedFailedException)
                {
                    return false;
                }

                if (e is UserOfflineException
                    || e is ConnectionException
                    || e is NoResponseException
                    || e is TimeoutException
                    || e is SocketException
                    || e is PartFileChangedException
#if SEEKER_FORK
                    || e.GetType().Name.Contains("CannotConnect")
                    || e.GetType().Name.Contains("Timeout"))
#else
                    || IsTransientIo(e))
#endif
                {
                    return true;
                }
            }

            return false;
        }

#if !SEEKER_FORK
        /// <summary>
        ///   Повтор имеет смысл только для занятого файла (sharing / lock violation)
        ///   и сетевого IO; нехватка места, слишком длинный путь, пропавший каталог —
        ///   окончательные.
        /// </summary>
        private static bool IsTransientIo(Exception e)
        {
            if (e is not IOException io
                || e is PathTooLongException
                || e is DirectoryNotFoundException
                || e is FileNotFoundException)
            {
                return false;
            }

            const int ErrorHandleDiskFull = 0x27;
            const int ErrorDiskFull = 0x70;
            var code = io.HResult & 0xFFFF;
            return code != ErrorHandleDiskFull && code != ErrorDiskFull;
        }
#endif

        // ─────────────────────────────────────────────────────────────────────
        //  Внутренние хелперы — JSON и события
        // ─────────────────────────────────────────────────────────────────────

        private void EmitEvent(SoulseekEventDto evt)
        {
            try
            {
                _emit(JsonSerializer.Serialize(evt, JsonOpts));
            }
            catch
            {
                // получатель может быть уже освобождён; игнорируем
            }
        }

        private static string SuccessJson(string data)
        {
            return JsonSerializer.Serialize(new ResultDto { Success = true, Data = data }, JsonOpts);
        }

        /// <summary>ResultDto ошибки (для обёрток, поймавших исключение вне ядра).</summary>
        public static string ErrorJson(Exception ex, bool retryable)
        {
            return JsonSerializer.Serialize(new ResultDto
            {
                Success = false,
                ErrorCode = ex.GetType().Name,
                ErrorMessage = ex.Message,
                Retryable = retryable,
            }, JsonOpts);
        }

        private void CleanupDownload(string downloadId, CancellationTokenSource cts, string username, string remoteFilename)
        {
            // Только свой CTS: запись мог уже занять новый запуск того же id.
            _downloadCts.TryRemove(new KeyValuePair<string, CancellationTokenSource>(downloadId, cts));
            StopQueueMonitor(downloadId, cts);
            cts.Dispose();

            // Тот же пир/файл мог уже уйти в новую попытку (другой downloadId) —
            // её запись не трогаем.
            _transferKeyToDownloadId.TryRemove(
                new KeyValuePair<string, string>(TransferKey(username, remoteFilename), downloadId));
            _lastProgressTick.TryRemove(downloadId, out _);
        }

        private static string TransferKey(string username, string filename)
        {
            return username + "\0" + filename;
        }
    }
}
