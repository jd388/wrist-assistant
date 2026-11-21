export interface ErrorPayload {
  code: string;
  message: string;
  retryable: boolean;
}

export class ServiceError extends Error {
  readonly code: string;
  readonly status: number;
  readonly retryable: boolean;
  readonly headers: Headers;

  constructor(
    code: string,
    message: string,
    status: number,
    retryable = false,
    headers?: HeadersInit
  ) {
    super(message);
    this.name = "ServiceError";
    this.code = code;
    this.status = status;
    this.retryable = retryable;
    this.headers = new Headers(headers);
  }

  payload(): ErrorPayload {
    return {
      code: this.code,
      message: this.message,
      retryable: this.retryable
    };
  }
}

export function jsonResponse(
  value: unknown,
  status = 200,
  headers?: HeadersInit
): Response {
  const outputHeaders = new Headers(headers);
  outputHeaders.set("Content-Type", "application/json; charset=utf-8");
  outputHeaders.set("Cache-Control", "no-store");
  outputHeaders.set("X-Content-Type-Options", "nosniff");
  return new Response(JSON.stringify(value), { status, headers: outputHeaders });
}

export function errorResponse(error: unknown): Response {
  if (error instanceof ServiceError) {
    return jsonResponse(error.payload(), error.status, error.headers);
  }
  return jsonResponse(
    {
      code: "internal_error",
      message: "The renderer encountered an unexpected error.",
      retryable: true
    } satisfies ErrorPayload,
    500
  );
}

export function validationError(message: string): ServiceError {
  return new ServiceError("invalid_request", message, 422, false);
}

function upstreamErrorText(error: unknown): string {
  if (error instanceof Error) {
    const value = error as Error & { code?: unknown; status?: unknown };
    return [value.code, value.status, error.message]
      .filter((item) => item !== undefined && item !== null)
      .map(String)
      .join(" ");
  }
  if (typeof error === "object" && error !== null) {
    const value = error as Record<string, unknown>;
    return [value.code, value.status, value.error, value.message]
      .filter((item) => item !== undefined && item !== null)
      .map(String)
      .join(" ");
  }
  return String(error);
}

export function browserServiceError(error: unknown): ServiceError {
  const text = upstreamErrorText(error);
  const normalized = text.toLowerCase();
  if (
    normalized.includes("time limit exceeded") ||
    (normalized.includes("browser time") && normalized.includes("limit"))
  ) {
    const now = new Date();
    const nextUTC = Date.UTC(
      now.getUTCFullYear(),
      now.getUTCMonth(),
      now.getUTCDate() + 1
    );
    const retryAfter = Math.max(1, Math.ceil((nextUTC - now.getTime()) / 1000));
    return new ServiceError(
      "browser_daily_limit",
      "Today's free cloud-browser allowance has been used. Static reading and AI remain available; interactive browsing resets after 00:00 UTC.",
      429,
      false,
      { "Retry-After": String(retryAfter) }
    );
  }
  if (
    normalized.includes("too many") ||
    normalized.includes("rate limit") ||
    normalized.includes("429") ||
    normalized.includes("another worker") ||
    normalized.includes("already connected")
  ) {
    return new ServiceError(
      "browser_busy",
      "The free cloud browser is busy. Try again after a short wait.",
      429,
      true,
      { "Retry-After": "20" }
    );
  }
  if (
    (
      normalized.includes("session")
      && (
        normalized.includes("closed")
        || normalized.includes("not found")
        || normalized.includes("does not exist")
        || normalized.includes("expired")
      )
    )
    || normalized.includes("target closed")
    || (
      normalized.includes("has been closed")
      && ["target", "page", "context", "browser"].some((name) => normalized.includes(name))
    )
    || normalized.includes("code: 404")
    || /^404\b/.test(normalized)
  ) {
    return new ServiceError(
      "session_expired",
      "The browser session expired. Open the page again.",
      410,
      false
    );
  }
  if (normalized.includes("timeout") || normalized.includes("timed out")) {
    return new ServiceError(
      "browser_timeout",
      "The cloud browser did not finish in time.",
      504,
      true
    );
  }
  return new ServiceError(
    "browser_unavailable",
    "The free cloud browser is temporarily unavailable.",
    503,
    true
  );
}
