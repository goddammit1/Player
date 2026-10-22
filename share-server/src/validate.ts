import { HttpError } from "./http";
import {
  MAX_EXTRA_DEPTH,
  MAX_EXTRA_KEYS,
  MAX_EXTRA_KEY_LENGTH,
  MAX_EXTRA_NODES,
  MAX_NAME_LENGTH,
  MAX_STRING_LENGTH,
  MAX_TRACKS,
  MAX_URL_LENGTH,
} from "./limits";

// Формат совпадает с PlaylistShareCodec в плеере
// (lib/core/share/playlist_share_codec.dart).
export const FORMAT_TAG = "player_playlist_share";
export const FORMAT_VERSION = 1;

export type ExtraValue = string | number | boolean | null | ExtraValue[] | { [key: string]: ExtraValue };

export interface SharedTrack {
  id: string;
  source_id: string;
  title: string;
  artist: string;
  duration_ms?: number;
  artwork_url?: string;
  quality_score?: number;
  quality_label?: string;
  extra?: Record<string, ExtraValue>;
}

export interface SharePayload {
  format: typeof FORMAT_TAG;
  version: typeof FORMAT_VERSION;
  playlist: { name: string; tracks: SharedTrack[] };
}

/**
 * Проверяет распарсенный JSON и возвращает нормализованную копию: только
 * известные поля, `null` у необязательных полей отброшен. Сохраняется именно
 * она, поэтому в KV не попадает ничего, кроме формата плейлиста.
 */
export function validatePayload(input: unknown): SharePayload {
  if (!isObject(input)) bad("Expected a JSON object");
  if (input.format !== FORMAT_TAG) bad("Not a playlist share payload");
  if (input.version !== FORMAT_VERSION) bad(`Unsupported version: ${String(input.version)}`);

  const playlist = input.playlist;
  if (!isObject(playlist)) bad("Missing playlist");

  const name = typeof playlist.name === "string" ? playlist.name.trim() : "";
  if (name.length === 0) bad("Playlist name is required");
  if (name.length > MAX_NAME_LENGTH) bad("Playlist name is too long");

  const rawTracks = playlist.tracks;
  if (!Array.isArray(rawTracks)) bad("Missing tracks");
  if (rawTracks.length === 0) bad("Playlist is empty");
  if (rawTracks.length > MAX_TRACKS) throw new HttpError(413, `Too many tracks (max ${MAX_TRACKS})`);

  const tracks = rawTracks.map((t, i) => validateTrack(t, i));
  return { format: FORMAT_TAG, version: FORMAT_VERSION, playlist: { name, tracks } };
}

function validateTrack(input: unknown, index: number): SharedTrack {
  const where = `track #${index}`;
  if (!isObject(input)) bad(`${where}: expected an object`);

  const track: SharedTrack = {
    id: requiredString(input.id, `${where}.id`),
    source_id: requiredString(input.source_id, `${where}.source_id`),
    title: string(input.title, `${where}.title`),
    artist: string(input.artist, `${where}.artist`),
  };

  const duration = input.duration_ms;
  if (duration != null) {
    if (!Number.isInteger(duration) || (duration as number) < 0) bad(`${where}.duration_ms: invalid`);
    track.duration_ms = duration as number;
  }

  // Локальные пути обложек клиент не отправляет; если всё же пришли — тихо
  // отбрасываем, у получателя они бесполезны.
  const artwork = input.artwork_url;
  if (artwork != null) {
    if (typeof artwork !== "string" || artwork.length > MAX_URL_LENGTH) bad(`${where}.artwork_url: invalid`);
    if (/^https?:\/\//i.test(artwork)) track.artwork_url = artwork;
  }

  const score = input.quality_score;
  if (score != null) {
    if (!Number.isInteger(score)) bad(`${where}.quality_score: invalid`);
    track.quality_score = score as number;
  }

  const label = input.quality_label;
  if (label != null) track.quality_label = string(label, `${where}.quality_label`);

  const extra = input.extra;
  if (extra != null) {
    const clean = validateExtra(extra, where);
    if (Object.keys(clean).length > 0) track.extra = clean;
  }

  return track;
}

/**
 * `extra` — произвольный JSON источника (как в бэкапе), но ограниченный:
 * ключей на уровень, глубина и общее число значений.
 */
function validateExtra(input: unknown, where: string): Record<string, ExtraValue> {
  if (!isObject(input)) bad(`${where}.extra: expected an object`);
  const budget = { nodes: 0 };
  return extraValue(input, `${where}.extra`, 1, budget) as Record<string, ExtraValue>;
}

function extraValue(v: unknown, where: string, depth: number, budget: { nodes: number }): ExtraValue {
  if (++budget.nodes > MAX_EXTRA_NODES) bad(`${where}: too many values`);
  if (v === null || typeof v === "boolean") return v;
  if (typeof v === "number") {
    if (!Number.isFinite(v)) bad(`${where}: invalid number`);
    return v;
  }
  if (typeof v === "string") {
    if (v.length > MAX_URL_LENGTH) bad(`${where}: too long`);
    return v;
  }
  if (depth > MAX_EXTRA_DEPTH) bad(`${where}: nested too deeply`);
  if (Array.isArray(v)) {
    if (v.length > MAX_EXTRA_KEYS) bad(`${where}: too many items`);
    return v.map((item, i) => extraValue(item, `${where}[${i}]`, depth + 1, budget));
  }
  if (isObject(v)) {
    const keys = Object.keys(v);
    if (keys.length > MAX_EXTRA_KEYS) bad(`${where}: too many keys`);
    const out: Record<string, ExtraValue> = {};
    for (const key of keys) {
      if (key.length === 0 || key.length > MAX_EXTRA_KEY_LENGTH) bad(`${where}: invalid key`);
      out[key] = extraValue(v[key], `${where}.${key}`, depth + 1, budget);
    }
    return out;
  }
  bad(`${where}: unsupported value`);
}

function requiredString(v: unknown, where: string): string {
  const s = string(v, where);
  if (s.length === 0) bad(`${where}: required`);
  return s;
}

function string(v: unknown, where: string): string {
  if (typeof v !== "string") bad(`${where}: expected a string`);
  if (v.length > MAX_STRING_LENGTH) bad(`${where}: too long`);
  return v;
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function bad(message: string): never {
  throw new HttpError(400, message);
}
