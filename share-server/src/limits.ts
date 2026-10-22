// Все лимиты сервера в одном месте. Клиент (lib/core/share) держит такие же
// значения для понятных ошибок до отправки, но источник истины — здесь.

/** Максимальный размер сжатого тела POST /api/p. */
export const MAX_COMPRESSED_BYTES = 2 * 1024 * 1024;

/** Максимальный размер JSON после распаковки (защита от zip-бомбы). */
export const MAX_DECOMPRESSED_BYTES = 20 * 1024 * 1024;

export const MAX_TRACKS = 20_000;
export const MAX_NAME_LENGTH = 200;
export const MAX_STRING_LENGTH = 1_000;
export const MAX_URL_LENGTH = 2_000;
export const MAX_EXTRA_KEYS = 32;
export const MAX_EXTRA_KEY_LENGTH = 100;
/** Глубина вложенности `extra` (Soulseek `alternates`, SoundCloud `transcodings`). */
export const MAX_EXTRA_DEPTH = 4;
/** Всего значений внутри `extra` одного трека, включая вложенные. */
export const MAX_EXTRA_NODES = 300;

/** Сколько треков показывает HTML-страница плейлиста. */
export const PAGE_TRACK_LIMIT = 300;
