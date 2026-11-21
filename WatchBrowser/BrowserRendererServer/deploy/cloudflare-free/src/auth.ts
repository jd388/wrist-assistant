import { ServiceError } from "./errors";

const encoder = new TextEncoder();

function constantTimeEqual(left: string, right: string): boolean {
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  const length = Math.max(a.length, b.length, 1);
  let difference = a.length ^ b.length;
  for (let index = 0; index < length; index += 1) {
    difference |= (a[index % Math.max(a.length, 1)] ?? 0)
      ^ (b[index % Math.max(b.length, 1)] ?? 0);
  }
  return difference === 0;
}

export function requireBearer(request: Request, configuredToken?: string): void {
  const expected = configuredToken?.trim() ?? "";
  if (!expected) {
    throw new ServiceError(
      "server_not_configured",
      "The renderer bearer token is not configured.",
      503,
      false
    );
  }
  const raw = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(raw);
  const supplied = match?.[1]?.trim() ?? "";
  if (!supplied || !constantTimeEqual(supplied, expected)) {
    throw new ServiceError(
      "unauthorized",
      "A valid renderer bearer token is required.",
      401,
      false,
      { "WWW-Authenticate": "Bearer" }
    );
  }
}
