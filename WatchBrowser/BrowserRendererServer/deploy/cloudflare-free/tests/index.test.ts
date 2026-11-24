import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("@cloudflare/playwright", () => ({
  launch: vi.fn()
}));

import worker from "../src/index";
import { QUICK_DEEPSEEK_MODEL } from "../src/ai";
import type { Environment } from "../src/types";

interface FakeEnvironment {
  env: Environment;
  stubFetch: ReturnType<typeof vi.fn>;
}

function fakeEnvironment(
  sessionHandler?: (request: Request) => Response | Promise<Response>
): FakeEnvironment {
  const stubFetch = vi.fn(async (request: Request) => {
    if (sessionHandler) return sessionHandler(request);
    if (new URL(request.url).pathname === "/health") {
      return Response.json({ active: false, daily_limit_until: null });
    }
    return Response.json({ delegated: true });
  });
  const env = {
    BROWSER: {} as Fetcher,
    BROWSER_SESSION: {
      getByName(name: string) {
        expect(name).toBe("primary");
        return { fetch: stubFetch };
      }
    } as unknown as DurableObjectNamespace,
    BROWSER_RENDERER_TOKEN: "renderer-secret",
    DEEPSEEK_API_KEY: "not-a-real-deepseek-secret"
  } satisfies Environment;
  return { env, stubFetch };
}

function deepSeekJSON(answer = "AI answer", title?: string): Response {
  return Response.json({
    status: "completed",
    model: QUICK_DEEPSEEK_MODEL,
    title,
    output: [{
      type: "message",
      role: "assistant",
      content: [{ type: "output_text", text: answer }]
    }]
  });
}

function apiRequest(path: string, init: RequestInit = {}, authorize = true): Request {
  const headers = new Headers(init.headers);
  if (authorize) headers.set("Authorization", "Bearer renderer-secret");
  return new Request(`https://renderer.example${path}`, { ...init, headers });
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("official conversation title", () => {
  it.each(["/v1/ask", "/v1/ask/stream"])("returns the title from the only upstream call on %s", async (path) => {
    const { env } = fakeEnvironment();
    const upstream = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      expect(JSON.parse(String(init?.body))).toMatchObject({ title: { enabled: true } });
      const result = deepSeekJSON("完整回答", "问题的主题");
      if (path.endsWith("/stream")) {
        const event = { type: "response.completed", response: await result.json() };
        return new Response(`data: ${JSON.stringify(event)}\n\n`, {
          headers: { "Content-Type": "text/event-stream" }
        });
      }
      return result;
    });
    vi.stubGlobal("fetch", upstream);

    const response = await worker.fetch(apiRequest(path, {
      method: "POST",
      headers: { "X-Wrist-Conversation-Title": "true" },
      body: JSON.stringify({ question: "这个问题的主题是什么？" })
    }), env);

    expect(response.status).toBe(200);
    expect(await response.text()).toContain('"conversation_title":"问题的主题"');
    expect(upstream).toHaveBeenCalledTimes(1);
  });
});

describe("public router", () => {
  it("serves the inert browser fixture without a bearer or Browser Run", async () => {
    const { env, stubFetch } = fakeEnvironment();
    const response = await worker.fetch(
      apiRequest("/support/browser-fixture?q=%3Cprobe%3E", {}, false),
      env
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toContain("text/html");
    expect(response.headers.get("Content-Security-Policy")).toContain("default-src 'none'");
    const html = await response.text();
    expect(html).toContain("已提交：&lt;probe&gt;");
    expect(html).not.toContain("已提交：<probe>");
    expect(stubFetch).not.toHaveBeenCalled();
  });

  it("rejects non-GET fixture requests without touching any binding", async () => {
    const { env, stubFetch } = fakeEnvironment();
    const response = await worker.fetch(apiRequest(
      "/support/browser-fixture",
      { method: "POST" },
      false
    ), env);
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("GET");
    expect(stubFetch).not.toHaveBeenCalled();
  });

  it("authenticates health and fails closed before touching any binding", async () => {
    const { env, stubFetch } = fakeEnvironment();
    env.BROWSER_RENDERER_TOKEN = undefined;
    const response = await worker.fetch(apiRequest("/health", {}, false), env);
    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toMatchObject({
      code: "server_not_configured",
      retryable: false
    });
    expect(stubFetch).not.toHaveBeenCalled();
  });

  it("returns conservative health capabilities and hardened headers", async () => {
    const { env } = fakeEnvironment(() => Response.json({
      active: true,
      daily_limit_until: null
    }));
    const response = await worker.fetch(apiRequest("/health"), env);
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(response.headers.get("Referrer-Policy")).toBe("no-referrer");
    expect(response.headers.get("Permissions-Policy")).toContain("camera=()");
    await expect(response.json()).resolves.toEqual({
      status: "ok",
      browser_ready: true,
      browser_egress_isolated: false,
      reader_ready: true,
      ai_configured: true,
      active_sessions: 1,
      max_sessions: 1,
      detail: null
    });
  });

  it("exposes a degraded health result while the Browser Run daily limit is active", async () => {
    const limit = Date.now() + 60_000;
    const { env } = fakeEnvironment(() => Response.json({
      active: false,
      daily_limit_until: limit
    }));
    const response = await worker.fetch(apiRequest("/health"), env);
    await expect(response.json()).resolves.toMatchObject({
      status: "degraded",
      browser_ready: false,
      reader_ready: true,
      ai_configured: true,
      active_sessions: 0
    });
  });

  it("reports AI as unconfigured when no DeepSeek Worker secret exists", async () => {
    const { env } = fakeEnvironment();
    env.DEEPSEEK_API_KEY = undefined;
    const response = await worker.fetch(apiRequest("/health"), env);
    await expect(response.json()).resolves.toMatchObject({ ai_configured: false });
  });

  it("returns 405 with an Allow header and a stable envelope", async () => {
    const { env } = fakeEnvironment();
    const response = await worker.fetch(apiRequest("/health", { method: "POST" }), env);
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("GET");
    await expect(response.json()).resolves.toMatchObject({ code: "method_not_allowed" });
  });

  it("returns a hardened 404 for unknown routes", async () => {
    const { env } = fakeEnvironment();
    const response = await worker.fetch(apiRequest("/v1/unknown"), env);
    expect(response.status).toBe(404);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    await expect(response.json()).resolves.toEqual({
      code: "not_found",
      message: "The renderer endpoint was not found.",
      retryable: false
    });
  });
});

describe("API delegation", () => {
  it("normalizes an open request and delegates it to the singleton session object", async () => {
    const frame = {
      session_id: "session-1",
      sequence: 1,
      url: "https://example.com/",
      title: "Example",
      can_go_back: false,
      scroll_progress: 0,
      image_base64: "AA==",
      message: "Page opened.",
      focused_input: false,
      focused_input_label: null
    };
    const { env, stubFetch } = fakeEnvironment(() => Response.json(frame));
    const response = await worker.fetch(apiRequest("/v1/sessions/open", {
      method: "POST",
      body: JSON.stringify({ url: "https://example.com" })
    }), env);
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual(frame);

    const delegated = stubFetch.mock.calls[0]?.[0] as Request;
    expect(new URL(delegated.url).pathname).toBe("/open");
    expect(delegated.method).toBe("POST");
    await expect(delegated.json()).resolves.toEqual({
      url: "https://example.com",
      viewport_width: 396,
      viewport_height: 484
    });
  });

  it.each([
    ["scroll", { amount: 1.25 }],
    ["tap", { x: 0.25, y: 0.75 }],
    ["fill", { text: "query", submit: true }],
    ["back", {}],
    ["refresh", {}]
  ])("delegates the %s operation with its validated body", async (action, body) => {
    const { env, stubFetch } = fakeEnvironment();
    const response = await worker.fetch(apiRequest(`/v1/sessions/abc123/${action}`, {
      method: "POST",
      body: JSON.stringify(body)
    }), env);
    expect(response.status).toBe(200);
    const delegated = stubFetch.mock.calls[0]?.[0] as Request;
    expect(new URL(delegated.url).pathname).toBe(`/sessions/abc123/${action}`);
    await expect(delegated.json()).resolves.toEqual(body);
  });

  it("delegates idempotent session deletion without inventing a response body", async () => {
    const { env, stubFetch } = fakeEnvironment(() => new Response(null, { status: 204 }));
    const response = await worker.fetch(apiRequest("/v1/sessions/abc123", {
      method: "DELETE"
    }), env);
    expect(response.status).toBe(204);
    const delegated = stubFetch.mock.calls[0]?.[0] as Request;
    expect(delegated.method).toBe("DELETE");
    expect(new URL(delegated.url).pathname).toBe("/sessions/abc123");
  });

  it("serves static reading without consuming Browser Run when HTML is sufficient", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(
      "<html><head><title>Static</title></head><body><main><p>Readable now</p></main></body></html>",
      { headers: { "Content-Type": "text/html" } }
    )));
    const { env, stubFetch } = fakeEnvironment();
    const response = await worker.fetch(apiRequest("/v1/read", {
      method: "POST",
      body: JSON.stringify({ url: "https://93.184.216.34/article" })
    }), env);
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      title: "Static",
      source: "static",
      blocks: [{ kind: "paragraph", text: "Readable now" }]
    });
    expect(stubFetch).not.toHaveBeenCalled();
  });

  it("proxies a legacy ask request to the official DeepSeek Responses API", async () => {
    const deepSeekFetch = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      expect(JSON.parse(String(init?.body))).toMatchObject({
        model: QUICK_DEEPSEEK_MODEL,
        stream: false
      });
      return deepSeekJSON();
    });
    vi.stubGlobal("fetch", deepSeekFetch);
    const { env } = fakeEnvironment();
    const response = await worker.fetch(apiRequest("/v1/ask", {
      method: "POST",
      body: JSON.stringify({ question: "Answer briefly" })
    }), env);
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      answer: "AI answer",
      model: QUICK_DEEPSEEK_MODEL,
      web_search_used: false,
      web_search_provider: null
    });
    expect(deepSeekFetch).toHaveBeenCalledOnce();
  });

  it("keeps old-client deep-search history working through the safe transcript fallback", async () => {
    const deepSeekFetch = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      const payload = JSON.parse(String(init?.body)) as {
        input: Array<{ role: string; content: string }>;
        tools: unknown[];
      };
      expect(payload.input).toHaveLength(1);
      expect(payload.input[0]?.role).toBe("user");
      expect(payload.input[0]?.content).toContain('{"role":"assistant","content":"Old answer"}');
      expect(payload.tools).toEqual([{ type: "web_search" }]);
      return deepSeekJSON("Compatible answer");
    });
    vi.stubGlobal("fetch", deepSeekFetch);
    const { env } = fakeEnvironment();
    const response = await worker.fetch(apiRequest("/v1/ask", {
      method: "POST",
      body: JSON.stringify({
        question: "Continue",
        web_search: true,
        deep_thinking: true,
        history: [
          { role: "user", content: "Old question" },
          { role: "assistant", content: "Old answer" }
        ]
      })
    }), env);
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      answer: "Compatible answer",
      response_items: [{ type: "message", role: "assistant" }]
    });
    expect(deepSeekFetch).toHaveBeenCalledOnce();
  });

  it("accepts a valid CJK conversation whose UTF-8 JSON exceeds the generic 64 KiB cap", async () => {
    const deepSeekFetch = vi.fn(async () => deepSeekJSON("继续回答"));
    vi.stubGlobal("fetch", deepSeekFetch);
    const { env } = fakeEnvironment();
    const content = "中".repeat(6_000);
    const body = JSON.stringify({
      question: "继续",
      history: [
        { role: "user", content },
        { role: "assistant", content },
        { role: "user", content },
        { role: "assistant", content }
      ]
    });
    expect(new TextEncoder().encode(body).byteLength).toBeGreaterThan(64 * 1024);
    const response = await worker.fetch(apiRequest("/v1/ask", {
      method: "POST",
      body
    }), env);
    expect(response.status).toBe(200);
    expect(deepSeekFetch).toHaveBeenCalledOnce();
  });
});
