import { askAI, hasDeepSeekCredential, streamAI } from "./ai";
import { requireBearer } from "./auth";
import { browserFixture } from "./browser-fixture";
import { BrowserSession, readDynamic } from "./browser";
import { ServiceError, errorResponse, jsonResponse } from "./errors";
import { readStatic, type StaticReadResult } from "./reader";
import {
  parseAsk,
  parseEmpty,
  parseFill,
  parseOpen,
  parseRead,
  parseScroll,
  parseTap,
  readJSON
} from "./schemas";
import type {
  BrowserSessionHealth,
  Environment,
  HealthResponse,
  ReadRequest
} from "./types";

export { BrowserSession };

const SESSION_OBJECT_NAME = "primary";
const MAX_ASK_REQUEST_BYTES = 256 * 1024;

function stub(env: Environment): DurableObjectStub {
  return env.BROWSER_SESSION.getByName(SESSION_OBJECT_NAME);
}

async function sessionRequest(
  env: Environment,
  path: string,
  method: "GET" | "POST" | "DELETE",
  body?: unknown
): Promise<Response> {
  const headers = body === undefined ? undefined : { "Content-Type": "application/json" };
  const response = await stub(env).fetch(new Request(`https://browser-session${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body)
  }));
  return harden(response);
}

function harden(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set("Cache-Control", "no-store");
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Referrer-Policy", "no-referrer");
  headers.set("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers
  });
}

async function health(env: Environment): Promise<Response> {
  let state: BrowserSessionHealth = { active: false, daily_limit_until: null };
  let detail: string | null = null;
  try {
    const response = await sessionRequest(env, "/health", "GET");
    if (!response.ok) throw new Error("session health unavailable");
    state = await response.json() as BrowserSessionHealth;
  } catch {
    detail = "Browser session state is temporarily unavailable.";
  }
  const limited = state.daily_limit_until !== null && state.daily_limit_until > Date.now();
  if (limited) {
    detail = `The free browser allowance resets after ${new Date(state.daily_limit_until!).toISOString()}.`;
  }
  const browserReady = detail === null && !limited;
  return jsonResponse({
    status: browserReady ? "ok" : "degraded",
    browser_ready: browserReady,
    // Browser Run guardrails, per-request URL/DNS validation, and public-only
    // Worker fetches reduce SSRF exposure, but are not a container-level egress
    // firewall or DNS-pinned socket. Keep this capability claim conservative.
    browser_egress_isolated: false,
    reader_ready: true,
    ai_configured: hasDeepSeekCredential(env),
    active_sessions: state.active ? 1 : 0,
    max_sessions: 1,
    detail
  } satisfies HealthResponse);
}

function mayUseDynamic(error: ServiceError): boolean {
  return new Set([
    "web_response_too_large",
    "web_fetch_timeout",
    "web_fetch_failed",
    "web_upstream_rejected",
    "empty_page",
    "unsupported_text_encoding"
  ]).has(error.code);
}

async function read(request: ReadRequest, env: Environment): Promise<Response> {
  let staticResult: StaticReadResult | null = null;
  let staticError: ServiceError | null = null;
  try {
    staticResult = await readStatic(request);
  } catch (error) {
    if (!(error instanceof ServiceError)) throw error;
    if (!mayUseDynamic(error)) throw error;
    staticError = error;
  }
  if (
    staticResult
    && !request.prefer_dynamic
    && !staticResult.requiresDynamic
  ) {
    return jsonResponse(staticResult.response);
  }
  try {
    return jsonResponse(await readDynamic(request, env));
  } catch (error) {
    // A readable static result is a useful zero-cost recovery path when the
    // free browser is busy, expired, or out of daily minutes.
    if (staticResult && staticResult.response.blocks.length > 0) {
      return jsonResponse(staticResult.response);
    }
    if (error instanceof ServiceError) throw error;
    if (staticError) throw staticError;
    throw error;
  }
}

function methodNotAllowed(allow: string): Response {
  return errorResponse(new ServiceError(
    "method_not_allowed",
    "The endpoint does not support this HTTP method.",
    405,
    false,
    { Allow: allow }
  ));
}

async function route(request: Request, env: Environment): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;

  // This inert HTML page is intentionally public so the local iPhone renderer
  // can exercise real HTTPS navigation without receiving the gateway bearer.
  if (path === "/support/browser-fixture") {
    if (request.method !== "GET") return methodNotAllowed("GET");
    return browserFixture(url);
  }

  requireBearer(request, env.BROWSER_RENDERER_TOKEN);

  if (path === "/health") {
    if (request.method !== "GET") return methodNotAllowed("GET");
    return health(env);
  }
  if (path === "/v1/read") {
    if (request.method !== "POST") return methodNotAllowed("POST");
    return read(parseRead(await readJSON(request)), env);
  }
  if (path === "/v1/ask") {
    if (request.method !== "POST") return methodNotAllowed("POST");
    return jsonResponse(await askAI(
      parseAsk(await readJSON(request, MAX_ASK_REQUEST_BYTES)),
      env,
      request.signal
    ));
  }
  if (path === "/v1/ask/stream") {
    if (request.method !== "POST") return methodNotAllowed("POST");
    return streamAI(
      parseAsk(await readJSON(request, MAX_ASK_REQUEST_BYTES)),
      env,
      request.signal
    );
  }
  if (path === "/v1/sessions/open") {
    if (request.method !== "POST") return methodNotAllowed("POST");
    return sessionRequest(env, "/open", "POST", parseOpen(await readJSON(request)));
  }

  const operation = /^\/v1\/sessions\/([^/]+)\/(scroll|tap|fill|back|refresh)$/.exec(path);
  if (operation) {
    if (request.method !== "POST") return methodNotAllowed("POST");
    const sessionId = operation[1] ?? "";
    const action = operation[2] ?? "";
    const raw = await readJSON(request);
    let body: unknown;
    if (action === "scroll") body = parseScroll(raw);
    else if (action === "tap") body = parseTap(raw);
    else if (action === "fill") body = parseFill(raw);
    else body = parseEmpty(raw);
    return sessionRequest(
      env,
      `/sessions/${encodeURIComponent(sessionId)}/${action}`,
      "POST",
      body
    );
  }

  const closing = /^\/v1\/sessions\/([^/]+)$/.exec(path);
  if (closing) {
    if (request.method !== "DELETE") return methodNotAllowed("DELETE");
    return sessionRequest(
      env,
      `/sessions/${encodeURIComponent(closing[1] ?? "")}`,
      "DELETE"
    );
  }

  return errorResponse(new ServiceError("not_found", "The renderer endpoint was not found.", 404, false));
}

export default {
  async fetch(request: Request, env: Environment): Promise<Response> {
    try {
      return harden(await route(request, env));
    } catch (error) {
      return harden(errorResponse(error));
    }
  }
} satisfies ExportedHandler<Environment>;

export const __test = { route, health, mayUseDynamic, methodNotAllowed };
