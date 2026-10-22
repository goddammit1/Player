const ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
export const ID_LENGTH = 10;
const ID_SPACE = 62n ** BigInt(ID_LENGTH);

export const ID_PATTERN = /^[0-9A-Za-z]{10}$/;

/** JSON с отсортированными ключами: одинаковый плейлист → одинаковые байты. */
export function canonicalJson(value: unknown): string {
  return JSON.stringify(sortKeys(value));
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (typeof value === "object" && value !== null) {
    const obj = value as Record<string, unknown>;
    return Object.fromEntries(
      Object.keys(obj)
        .sort()
        .map((k) => [k, sortKeys(obj[k])]),
    );
  }
  return value;
}

export async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data));
}

export function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Кандидаты id из хеша: 8-байтовые окна → base62 фиксированной длины.
 * Следующее окно нужно только при коллизии первого (≈ 1 на 10⁹ плейлистов).
 */
export function idCandidates(hash: Uint8Array): string[] {
  const out: string[] = [];
  for (let offset = 0; offset + 8 <= hash.length; offset += 8) {
    let n = 0n;
    for (let i = offset; i < offset + 8; i++) n = (n << 8n) | BigInt(hash[i]);
    out.push(base62(n % ID_SPACE));
  }
  return out;
}

function base62(n: bigint): string {
  let s = "";
  for (let i = 0; i < ID_LENGTH; i++) {
    s = ALPHABET[Number(n % 62n)] + s;
    n /= 62n;
  }
  return s;
}
