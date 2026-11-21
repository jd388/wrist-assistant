import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("@cloudflare/playwright", () => ({
  launch: vi.fn()
}));

import { launch } from "@cloudflare/playwright";
import { BrowserSession } from "../src/browser";
import type { Environment } from "../src/types";

beforeEach(() => {
  vi.mocked(launch).mockReset();
});

interface FakeSurface {
  browser: Record<string, unknown>;
  context: Record<string, unknown>;
  page: Record<string, unknown>;
  browserClose: ReturnType<typeof vi.fn>;
  touchTap: ReturnType<typeof vi.fn>;
  wheel: ReturnType<typeof vi.fn>;
}

function surface(
  remoteSessionId: string,
  initialURL: string,
  tapTarget: string | null,
  visualViewport: unknown = { width: 396, height: 484 }
): FakeSurface {
  let currentURL = initialURL;
  let connected = true;
  const browserClose = vi.fn(async () => { connected = false; });
  const touchTap = vi.fn(async () => undefined);
  const wheel = vi.fn(async () => undefined);
  const context: Record<string, unknown> = {};
  const page: Record<string, unknown> = {
    setDefaultNavigationTimeout: vi.fn(),
    setDefaultTimeout: vi.fn(),
    goto: vi.fn(async (url: string) => { currentURL = url; return null; }),
    waitForLoadState: vi.fn(async () => undefined),
    waitForTimeout: vi.fn(async () => undefined),
    url: vi.fn(() => currentURL),
    title: vi.fn(async () => `Page ${remoteSessionId}`),
    screenshot: vi.fn(async () => new Uint8Array([1, 2, 3])),
    frames: vi.fn(() => []),
    context: vi.fn(() => context),
    mouse: { wheel },
    touchscreen: { tap: touchTap },
    evaluate: vi.fn(async (script: string) => {
      if (script.includes("window.visualViewport")) return visualViewport;
      if (script.includes("textChars")) return { textChars: 10, links: 1, images: 0 };
      if (script.includes("scrollingElement")) return 0;
      if (script.includes("elementFromPoint")) return tapTarget;
      return null;
    })
  };
  Object.assign(context, {
    route: vi.fn(async () => undefined),
    routeWebSocket: vi.fn(async () => undefined),
    newPage: vi.fn(async () => page),
    setOffline: vi.fn(async () => undefined),
    close: vi.fn(async () => undefined),
    newCDPSession: vi.fn(async () => ({
      send: vi.fn(async () => ({ entries: [], currentIndex: 0 })),
      detach: vi.fn(async () => undefined)
    }))
  });
  const browser: Record<string, unknown> = {
    sessionId: vi.fn(() => remoteSessionId),
    newContext: vi.fn(async () => context),
    close: vi.fn(browserClose),
    isConnected: vi.fn(() => connected)
  };
  return { browser, context, page, browserClose, touchTap, wheel };
}

function durableState(): {
  state: DurableObjectState;
  put: ReturnType<typeof vi.fn>;
} {
  const values = new Map<string, unknown>();
  const put = vi.fn(async (key: string, value: unknown) => { values.set(key, value); });
  const storage = {
    get: vi.fn(async (key: string) => values.get(key)),
    put,
    delete: vi.fn(async (key: string) => values.delete(key)),
    setAlarm: vi.fn(async () => undefined),
    deleteAlarm: vi.fn(async () => undefined)
  };
  const state = {
    storage,
    blockConcurrencyWhile: <T>(callback: () => Promise<T>) => callback()
  } as unknown as DurableObjectState;
  return { state, put };
}

function environment(): Environment {
  return {
    BROWSER: {} as Fetcher,
    BROWSER_SESSION: {} as DurableObjectNamespace,
    BROWSER_RENDERER_TOKEN: "test-only"
  };
}

function internalRequest(path: string, method: "POST" | "DELETE", body?: unknown): Request {
  return new Request(`https://browser-session${path}`, {
    method,
    headers: body === undefined ? undefined : { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
}

describe("BrowserSession cross-site replacement", () => {
  it("reuses the launched browser for a second open on the same host", async () => {
    const current = surface("remote-reused", "https://93.184.216.34/first", null);
    vi.mocked(launch).mockResolvedValueOnce(current.browser as never);
    const { state } = durableState();
    const session = new BrowserSession(state, environment());

    const firstResponse = await session.fetch(internalRequest("/open", "POST", {
      url: "https://93.184.216.34/first",
      viewport_width: 396,
      viewport_height: 484
    }));
    const first = await firstResponse.json() as { session_id: string };

    const secondResponse = await session.fetch(internalRequest("/open", "POST", {
      url: "https://93.184.216.34/second",
      viewport_width: 396,
      viewport_height: 484
    }));
    const second = await secondResponse.json() as { session_id: string; url: string };

    expect(secondResponse.status).toBe(200);
    expect(second.session_id).not.toBe(first.session_id);
    expect(second.url).toBe("https://93.184.216.34/second");
    expect(launch).toHaveBeenCalledOnce();
    expect(current.context.close).toHaveBeenCalledOnce();
    expect(current.browserClose).not.toHaveBeenCalled();
    expect(vi.mocked(launch).mock.calls[0]?.[1]).toMatchObject({
      recording: false,
      guardrails: {
        allowedDomains: ["93.184.216.34"],
        allowedDomainSets: ["common-cdns"]
      }
    });

    const closed = await session.fetch(internalRequest(`/sessions/${second.session_id}`, "DELETE"));
    expect(closed.status).toBe(204);
    expect(current.browserClose).toHaveBeenCalledOnce();
  });

  it("maps screenshot-normalized taps and one-screen scrolls through the actual visual viewport", async () => {
    const current = surface(
      "remote-scaled",
      "https://93.184.216.34/form",
      null,
      { width: 980, height: 1_198 }
    );
    vi.mocked(launch).mockResolvedValueOnce(current.browser as never);
    const { state } = durableState();
    const session = new BrowserSession(state, environment());
    const opened = await session.fetch(internalRequest("/open", "POST", {
      url: "https://93.184.216.34/form",
      viewport_width: 396,
      viewport_height: 484
    }));
    const first = await opened.json() as { session_id: string };

    const tapped = await session.fetch(internalRequest(
      `/sessions/${first.session_id}/tap`,
      "POST",
      { x: 0.5, y: 0.515 }
    ));
    expect(tapped.status).toBe(200);
    expect(current.touchTap).toHaveBeenCalledOnce();
    const tap = current.touchTap.mock.calls[0];
    expect(tap?.[0]).toBe(490);
    expect(tap?.[1]).toBeCloseTo(616.97);

    const scrolled = await session.fetch(internalRequest(
      `/sessions/${first.session_id}/scroll`,
      "POST",
      { amount: 1 }
    ));
    expect(scrolled.status).toBe(200);
    expect(current.wheel).toHaveBeenCalledWith(0, 1_198);
  });

  it("builds a guarded candidate before atomically replacing the old session", async () => {
    const old = surface("remote-old", "https://93.184.216.34/", "https://1.1.1.1/next");
    const candidate = surface("remote-new", "https://1.1.1.1/next", null);
    vi.mocked(launch)
      .mockResolvedValueOnce(old.browser as never)
      .mockResolvedValueOnce(candidate.browser as never);
    const { state, put } = durableState();
    const session = new BrowserSession(state, environment());

    const opened = await session.fetch(internalRequest("/open", "POST", {
      url: "https://93.184.216.34/",
      viewport_width: 396,
      viewport_height: 484
    }));
    const first = await opened.json() as { session_id: string; sequence: number };
    expect(first.sequence).toBe(1);

    const tapped = await session.fetch(internalRequest(
      `/sessions/${first.session_id}/tap`,
      "POST",
      { x: 0.5, y: 0.5 }
    ));
    const second = await tapped.json() as { session_id: string; sequence: number; url: string };
    expect(tapped.status).toBe(200);
    expect(second.sequence).toBe(2);
    expect(second.session_id).not.toBe(first.session_id);
    expect(second.url).toBe("https://1.1.1.1/next");
    expect(old.touchTap).not.toHaveBeenCalled();
    expect(old.browserClose).toHaveBeenCalledOnce();
    expect(candidate.browserClose).not.toHaveBeenCalled();
    expect(put).toHaveBeenCalledTimes(2);
    expect(vi.mocked(launch).mock.calls[1]?.[1]).toMatchObject({
      guardrails: { allowedDomains: ["1.1.1.1"] }
    });

    const closed = await session.fetch(internalRequest(`/sessions/${second.session_id}`, "DELETE"));
    expect(closed.status).toBe(204);
    expect(candidate.browserClose).toHaveBeenCalledOnce();
  });

  it("keeps the old session usable when candidate acquisition is rate limited", async () => {
    const old = surface("remote-stable", "https://93.184.216.34/", "https://1.1.1.1/next");
    vi.mocked(launch)
      .mockResolvedValueOnce(old.browser as never)
      .mockRejectedValueOnce({ code: 429, message: "too many requests" });
    const { state } = durableState();
    const session = new BrowserSession(state, environment());
    const opened = await session.fetch(internalRequest("/open", "POST", {
      url: "https://93.184.216.34/",
      viewport_width: 396,
      viewport_height: 484
    }));
    const first = await opened.json() as { session_id: string };

    const failedTap = await session.fetch(internalRequest(
      `/sessions/${first.session_id}/tap`,
      "POST",
      { x: 0.5, y: 0.5 }
    ));
    expect(failedTap.status).toBe(429);
    await expect(failedTap.json()).resolves.toMatchObject({ code: "browser_busy" });
    expect(old.browserClose).not.toHaveBeenCalled();

    const scrolled = await session.fetch(internalRequest(
      `/sessions/${first.session_id}/scroll`,
      "POST",
      { amount: 1 }
    ));
    expect(scrolled.status).toBe(200);
    await expect(scrolled.json()).resolves.toMatchObject({
      session_id: first.session_id,
      sequence: 2
    });
    expect(old.wheel).toHaveBeenCalledOnce();
  });

  it("captures back and refresh after navigation commit without waiting indefinitely for DOM content", async () => {
    const current = surface("remote-navigation", "https://93.184.216.34/form", null);
    const goBack = vi.fn(async () => {
      const navigate = current.page.goto as (url: string) => Promise<unknown>;
      await navigate("https://93.184.216.34/");
      return null;
    });
    const reload = vi.fn(async () => ({}));
    Object.assign(current.page, { goBack, reload });
    Object.assign(current.context, {
      newCDPSession: vi.fn(async () => ({
        send: vi.fn(async () => ({
          entries: [{ url: "https://93.184.216.34/" }, { url: "https://93.184.216.34/form" }],
          currentIndex: 1
        })),
        detach: vi.fn(async () => undefined)
      }))
    });
    vi.mocked(launch).mockResolvedValueOnce(current.browser as never);
    const { state } = durableState();
    const session = new BrowserSession(state, environment());
    const opened = await session.fetch(internalRequest("/open", "POST", {
      url: "https://93.184.216.34/form",
      viewport_width: 396,
      viewport_height: 484
    }));
    const first = await opened.json() as { session_id: string };

    const backed = await session.fetch(internalRequest(
      `/sessions/${first.session_id}/back`,
      "POST",
      {}
    ));
    expect(backed.status).toBe(200);
    expect(goBack).toHaveBeenCalledWith({ waitUntil: "commit", timeout: 20_000 });

    const refreshed = await session.fetch(internalRequest(
      `/sessions/${first.session_id}/refresh`,
      "POST",
      {}
    ));
    expect(refreshed.status).toBe(200);
    expect(reload).toHaveBeenCalledWith({ waitUntil: "commit", timeout: 20_000 });
  });
});
