import { gunzip, gzip } from "./gzip";
import { canonicalJson, idCandidates, sha256, toHex } from "./id";
import type { SharePayload } from "./validate";

interface SnapshotMeta {
  sha: string;
}

const key = (id: string) => `p:${id}`;

/**
 * Сохраняет снимок и возвращает его id. Тот же плейлист → тот же id без
 * повторной записи (KV бесплатно даёт лишь 1000 записей в день).
 */
export async function saveSnapshot(kv: KVNamespace, payload: SharePayload): Promise<string> {
  const canonical = new TextEncoder().encode(canonicalJson(payload));
  const hash = await sha256(canonical);
  const sha = toHex(hash);

  for (const id of idCandidates(hash)) {
    const existing = await kv.getWithMetadata<SnapshotMeta>(key(id), "stream");
    if (existing.value === null) {
      await kv.put(key(id), await gzip(canonical), { metadata: { sha } satisfies SnapshotMeta });
      return id;
    }
    // Тело не нужно — только метаданные.
    await existing.value.cancel();
    if (existing.metadata?.sha === sha) return id;
  }
  throw new Error("All id candidates collided");
}

/** Сжатый снимок как есть — для GET /api/p/:id. */
export function loadSnapshotGzip(kv: KVNamespace, id: string): Promise<ArrayBuffer | null> {
  return kv.get(key(id), "arrayBuffer");
}

export async function loadSnapshot(kv: KVNamespace, id: string): Promise<SharePayload | null> {
  const data = await loadSnapshotGzip(kv, id);
  if (data === null) return null;
  return JSON.parse(new TextDecoder().decode(await gunzip(data))) as SharePayload;
}
