// <copyright file="SoulseekDtos.cs">
//   Фаза 1 — .NET wrapper для Soulseek (Android AAR).
//   DTO классы для JSON-маршалинга между C# bridge и Kotlin/Flutter.
//   Аудиобайты никогда не проходят через эти DTO — только метаданные и команды.
// </copyright>

namespace Soulseek.Wrapper
{
    using System.Collections.Generic;
    using System.Text.Json.Serialization;

    /// <summary>
    ///   Учётные данные и параметры подключения, передаваемые из Kotlin в ConnectAsync.
    /// </summary>
    public class AccountOptions
    {
        [JsonPropertyName("username")]
        public string Username { get; set; }

        [JsonPropertyName("password")]
        public string Password { get; set; }

        /// <summary>Порт, на котором клиент слушает входящие peer-соединения (listener).</summary>
        [JsonPropertyName("listenPort")]
        public int ListenPort { get; set; }

        /// <summary>Включить listener для входящих соединений (по умолчанию true).</summary>
        [JsonPropertyName("enableListener")]
        public bool EnableListener { get; set; } = true;

        /// <summary>Таймаут серверных сообщений, мс (по умолчанию 30000).</summary>
        [JsonPropertyName("messageTimeoutMs")]
        public int MessageTimeoutMs { get; set; } = 30000;
    }

    /// <summary>
    ///   Параметры поискового запроса, передаваемые из Kotlin в SearchAsync.
    /// </summary>
    public class SearchRequestDto
    {
        [JsonPropertyName("requestId")]
        public string RequestId { get; set; }

        [JsonPropertyName("query")]
        public string Query { get; set; }

        /// <summary>
        ///   Жёсткий общий бюджет поиска, мс (от отправки запроса серверу).
        ///   По истечении поиск останавливается и возвращает накопленное.
        /// </summary>
        [JsonPropertyName("timeoutMs")]
        public int TimeoutMs { get; set; } = 10000;

        /// <summary>
        ///   «Окно тишины», мс: после ПЕРВОГО ответа поиск завершается, если
        ///   новых ответов нет дольше этого окна. До первого ответа не действует.
        /// </summary>
        [JsonPropertyName("idleTimeoutMs")]
        public int IdleTimeoutMs { get; set; } = 2500;

        /// <summary>Максимальное количество ответов (responses), по умолчанию 100.</summary>
        [JsonPropertyName("responseLimit")]
        public int ResponseLimit { get; set; } = 100;

        /// <summary>
        ///   Максимальное количество файлов (после фильтров), по достижении которого
        ///   поиск завершается досрочно. По умолчанию 200.
        /// </summary>
        [JsonPropertyName("fileLimit")]
        public int FileLimit { get; set; } = 200;

        [JsonPropertyName("filters")]
        public SearchFiltersDto Filters { get; set; }
    }

    /// <summary>
    ///   Фильтры поиска, применяемые на стороне C# bridge к SearchOptions и пост-фильтрации.
    /// </summary>
    public class SearchFiltersDto
    {
        /// <summary>Разрешённые расширения файлов без точки, нижний регистр (например ["flac","mp3"]).</summary>
        [JsonPropertyName("extensions")]
        public List<string> Extensions { get; set; }

        [JsonPropertyName("minSizeBytes")]
        public long? MinSizeBytes { get; set; }

        [JsonPropertyName("maxSizeBytes")]
        public long? MaxSizeBytes { get; set; }

        /// <summary>Минимальный битрейт, kbps.</summary>
        [JsonPropertyName("minBitrate")]
        public int? MinBitrate { get; set; }

        /// <summary>Только lossless (flac, alac, wav, ape, wv).</summary>
        [JsonPropertyName("losslessOnly")]
        public bool LosslessOnly { get; set; }

        /// <summary>Минимальная скорость загрузки пира, KiB/s.</summary>
        [JsonPropertyName("minPeerUploadSpeed")]
        public int? MinPeerUploadSpeed { get; set; }

        /// <summary>Максимальная длина очереди пира.</summary>
        [JsonPropertyName("maxPeerQueueLength")]
        public int? MaxPeerQueueLength { get; set; }
    }

    /// <summary>
    ///   Один файл из результатов поиска. Маппится из Soulseek.File + SearchResponse.
    /// </summary>
    public class SearchResultDto
    {
        [JsonPropertyName("resultId")]
        public string ResultId { get; set; }

        [JsonPropertyName("username")]
        public string Username { get; set; }

        [JsonPropertyName("filename")]
        public string Filename { get; set; }

        [JsonPropertyName("sizeBytes")]
        public long SizeBytes { get; set; }

        [JsonPropertyName("extension")]
        public string Extension { get; set; }

        /// <summary>Битрейт, kbps (FileAttributeType.BitRate).</summary>
        [JsonPropertyName("bitrate")]
        public int? Bitrate { get; set; }

        /// <summary>Частота дискретизации, kHz (FileAttributeType.SampleRate).</summary>
        [JsonPropertyName("sampleRate")]
        public int? SampleRate { get; set; }

        /// <summary>Разрядность, бит (FileAttributeType.BitDepth).</summary>
        [JsonPropertyName("bitDepth")]
        public int? BitDepth { get; set; }

        /// <summary>Длительность, секунд (FileAttributeType.Length).</summary>
        [JsonPropertyName("durationSeconds")]
        public int? DurationSeconds { get; set; }

        [JsonPropertyName("queueLength")]
        public int QueueLength { get; set; }

        [JsonPropertyName("freeUploadSlots")]
        public int FreeUploadSlots { get; set; }

        /// <summary>Скорость загрузки пира, KiB/s.</summary>
        [JsonPropertyName("uploadSpeed")]
        public long UploadSpeed { get; set; }
    }

    /// <summary>
    ///   Параметры загрузки, передаваемые из Kotlin в DownloadToFileAsync.
    /// </summary>
    public class DownloadRequestDto
    {
        [JsonPropertyName("downloadId")]
        public string DownloadId { get; set; }

        [JsonPropertyName("peerUsername")]
        public string PeerUsername { get; set; }

        [JsonPropertyName("remoteFilename")]
        public string RemoteFilename { get; set; }

        [JsonPropertyName("sizeBytes")]
        public long SizeBytes { get; set; }

        /// <summary>Ключ кэша; используется как имя .part файла и финального файла (без расширения).</summary>
        [JsonPropertyName("cacheKey")]
        public string CacheKey { get; set; }

        /// <summary>Локальная директория для сохранения (создаётся при необходимости).</summary>
        [JsonPropertyName("localDirectory")]
        public string LocalDirectory { get; set; }

        /// <summary>Финальное расширение файла (например "flac"), добавляется при atomic rename.</summary>
        [JsonPropertyName("fileExtension")]
        public string FileExtension { get; set; }
    }

    /// <summary>
    ///   Событие, маршалируемое в Kotlin через ISoulseekEventSink.onEvent(json).
    /// </summary>
    public class SoulseekEventDto
    {
        /// <summary>
        ///   Тип события: "clientStateChanged", "disconnected", "transferStateChanged",
        ///   "transferProgress", "searchResponseReceived", "downloadComplete", "downloadFailed".
        /// </summary>
        [JsonPropertyName("eventType")]
        public string EventType { get; set; }

        [JsonPropertyName("downloadId")]
        public string DownloadId { get; set; }

        /// <summary>Состояние клиента/трансфера строкой (enum name).</summary>
        [JsonPropertyName("state")]
        public string State { get; set; }

        [JsonPropertyName("bytesReceived")]
        public long BytesReceived { get; set; }

        [JsonPropertyName("totalBytes")]
        public long TotalBytes { get; set; }

        [JsonPropertyName("bytesPerSecond")]
        public long BytesPerSecond { get; set; }

        [JsonPropertyName("localPath")]
        public string LocalPath { get; set; }

        [JsonPropertyName("errorCode")]
        public string ErrorCode { get; set; }

        [JsonPropertyName("retryable")]
        public bool Retryable { get; set; }

        /// <summary>Сообщение о смене состояния (например, причина дисконнекта).</summary>
        [JsonPropertyName("message")]
        public string Message { get; set; }

        /// <summary>Текст исключения, если событие вызвано ошибкой (Exception.Message).</summary>
        [JsonPropertyName("exceptionMessage")]
        public string ExceptionMessage { get; set; }

        /// <summary>searchProgress: id поиска, к которому относятся результаты.</summary>
        [JsonPropertyName("requestId")]
        public string RequestId { get; set; }

        /// <summary>searchProgress: новые результаты с прошлого события (дельта).</summary>
        [JsonPropertyName("results")]
        public List<SearchResultDto> Results { get; set; }
    }

    /// <summary>
    ///   Конфигурация расшаривания, передаваемая в ConfigureSharingAsync.
    /// </summary>
    public class SharingConfigDto
    {
        /// <summary>Включить listener для входящих соединений и ответов на поиск.</summary>
        [JsonPropertyName("enableListener")]
        public bool? EnableListener { get; set; }

        [JsonPropertyName("listenPort")]
        public int? ListenPort { get; set; }

        /// <summary>Максимальная суммарная скорость отдачи, KiB/s.</summary>
        [JsonPropertyName("maximumUploadSpeed")]
        public int? MaximumUploadSpeed { get; set; }

        /// <summary>Максимальная суммарная скорость загрузки, KiB/s.</summary>
        [JsonPropertyName("maximumDownloadSpeed")]
        public int? MaximumDownloadSpeed { get; set; }
    }

    /// <summary>
    ///   Универсальный результат вызова bridge-метода.
    ///   success=true => data содержит JSON полезной нагрузки (или null).
    ///   success=false => errorCode/errorMessage/retryable описывают ошибку.
    /// </summary>
    public class ResultDto
    {
        [JsonPropertyName("success")]
        public bool Success { get; set; }

        [JsonPropertyName("data")]
        public string Data { get; set; }

        [JsonPropertyName("errorCode")]
        public string ErrorCode { get; set; }

        [JsonPropertyName("errorMessage")]
        public string ErrorMessage { get; set; }

        [JsonPropertyName("retryable")]
        public bool Retryable { get; set; }
    }
}
