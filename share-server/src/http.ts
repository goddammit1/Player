/** Ошибка с HTTP-статусом: роутер превращает её в JSON-ответ. */
export class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export function json(body: unknown, status = 200, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}

export function errorJson(status: number, message: string): Response {
  return json({ error: message }, status);
}
