import { describe, expect, it, vi } from "vitest";

vi.mock("@cloudflare/playwright", () => ({
  launch: vi.fn()
}));

import { __test, guardrailDomains } from "../src/browser";
import {
  ServiceError,
  browserServiceError,
  errorResponse,
  jsonResponse
} from "../src/errors";

describe("Browser Run pure safety helpers", () => {
  it("uses the platform default 60 second idle lifetime and the Watch frame cap", () => {
    expect(__test.DEFAULT_IDLE_MS).toBe(60_000);
    expect(__test.MAXIMUM_IMAGE_BYTES).toBe(42_000);
  });

  it("invokes serialized page functions instead of returning function objects", () => {
    const noArgument = __test.invokeScript("() => ({ value: 7 })");
    const withArgument = __test.invokeScript(
      "({ left, right }) => ({ value: left + right })",
      { left: 3, right: 4 }
    );
    expect(Function(`return ${noArgument}`)()).toEqual({ value: 7 });
    expect(Function(`return ${withArgument}`)()).toEqual({ value: 7 });
  });

  it("builds immutable guardrails for only the opened host and its subdomains", () => {
    expect(guardrailDomains("example.com")).toEqual(["example.com", "*.example.com"]);
    expect(guardrailDomains("news.example.com")).toEqual([
      "news.example.com",
      "*.news.example.com"
    ]);
    expect(guardrailDomains("93.184.216.34")).toEqual(["93.184.216.34"]);
    expect(guardrailDomains("2606:4700:4700::1111")).toEqual(["2606:4700:4700::1111"]);
  });

  it("allows same-site subdomains but rejects sibling and suffix-confusion hosts", () => {
    expect(__test.hostWithinPrimary("example.com", "example.com")).toBe(true);
    expect(__test.hostWithinPrimary("cdn.example.com", "example.com")).toBe(true);
    expect(__test.hostWithinPrimary("badexample.com", "example.com")).toBe(false);
    expect(__test.hostWithinPrimary("example.com.attacker.test", "example.com")).toBe(false);
    expect(__test.hostWithinPrimary("93.184.216.34", "93.184.216.34")).toBe(true);
    expect(__test.hostWithinPrimary("x.93.184.216.34", "93.184.216.34")).toBe(false);
  });

  it("maps normalized screenshot coordinates into a scaled no-meta visual viewport", () => {
    const viewport = __test.safeVisualViewport({ width: 980, height: 1_198 }, 396, 484);
    expect(viewport).toEqual({ width: 980, height: 1_198 });
    const point = __test.normalizedPoint(0.5, 0.515, viewport);
    expect(point.x).toBe(490);
    expect(point.y).toBeCloseTo(616.97);
  });

  it("leaves ordinary one-to-one viewport coordinate mapping unchanged", () => {
    const viewport = __test.safeVisualViewport({ width: 396, height: 484 }, 396, 484);
    const point = __test.normalizedPoint(0.5, 0.515, viewport);
    expect(point.x).toBe(198);
    expect(point.y).toBeCloseTo(249.26);
  });

  it("falls back per dimension for missing, non-finite, or out-of-range viewport metrics", () => {
    expect(__test.safeVisualViewport(null, 396, 484)).toEqual({ width: 396, height: 484 });
    expect(__test.safeVisualViewport({ width: Number.NaN, height: Number.POSITIVE_INFINITY }, 396, 484))
      .toEqual({ width: 396, height: 484 });
    expect(__test.safeVisualViewport({ width: 0, height: 4_097 }, 396, 484))
      .toEqual({ width: 396, height: 484 });
    expect(__test.safeVisualViewport({ width: 980, height: "1198" }, 396, 484))
      .toEqual({ width: 980, height: 484 });
  });

  it("normalizes dynamic reader DTOs without preserving unsafe schemes or duplicates", () => {
    expect(__test.dynamicBlocks([
      { kind: "heading", text: " Title " },
      { kind: "unknown", text: " Body " },
      { kind: "paragraph", text: "" },
      null
    ])).toEqual([
      { kind: "heading", text: "Title" },
      { kind: "paragraph", text: "Body" }
    ]);
    expect(__test.dynamicLinks([
      { text: " A ", url: "https://example.com/a" },
      { text: "duplicate", url: "https://example.com/a" },
      { text: "script", url: "javascript:alert(1)" },
      { text: "", url: "https://example.com/b" }
    ])).toEqual([
      { text: "A", url: "https://example.com/a" },
      { text: "example.com", url: "https://example.com/b" }
    ]);
  });
});

describe("Browser Run error mapping", () => {
  it.each([
    ["Browser time limit exceeded for today", "browser_daily_limit", 429, false],
    ["browser time DAILY limit reached", "browser_daily_limit", 429, false],
    ["code 429: too many requests", "browser_busy", 429, true],
    ["another Worker is already connected", "browser_busy", 429, true],
    ["browser session not found", "session_expired", 410, false],
    ["session has expired", "session_expired", 410, false],
    ["Target page, context or browser has been closed", "session_expired", 410, false],
    ["Target closed", "session_expired", 410, false],
    ["navigation timed out", "browser_timeout", 504, true],
    ["unknown remote failure", "browser_unavailable", 503, true]
  ])("maps %s", (message, code, status, retryable) => {
    expect(browserServiceError(new Error(message))).toMatchObject({
      code,
      status,
      retryable
    });
  });

  it("returns the correct retry window for daily and acquisition limits", () => {
    expect(browserServiceError(new Error("time limit exceeded")).headers.get("Retry-After"))
      .toMatch(/^\d+$/);
    expect(browserServiceError(new Error("429 too many requests")).headers.get("Retry-After"))
      .toBe("20");
  });

  it("extracts quota and capacity details from plain Cloudflare error objects", () => {
    expect(browserServiceError({
      code: 429,
      status: 429,
      message: "Browser time limit exceeded for today"
    })).toMatchObject({ code: "browser_daily_limit", status: 429, retryable: false });
    expect(browserServiceError({
      code: 429,
      error: "another Worker is already connected"
    })).toMatchObject({ code: "browser_busy", status: 429, retryable: true });
  });
});

describe("HTTP error envelopes", () => {
  it("serializes only the stable public error contract", async () => {
    const error = new ServiceError("invalid_request", "Bad input", 422, false, {
      "Retry-After": "5"
    });
    const response = errorResponse(error);
    expect(response.status).toBe(422);
    expect(response.headers.get("Content-Type")).toContain("application/json");
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(response.headers.get("Retry-After")).toBe("5");
    await expect(response.json()).resolves.toEqual({
      code: "invalid_request",
      message: "Bad input",
      retryable: false
    });
  });

  it("does not leak unknown exception messages", async () => {
    const response = errorResponse(new Error("secret upstream URL and credentials"));
    expect(response.status).toBe(500);
    const payload = await response.text();
    expect(payload).not.toContain("secret upstream URL");
    expect(payload).toContain("internal_error");
  });

  it("marks all successful JSON as no-store", () => {
    const response = jsonResponse({ ok: true });
    expect(response.headers.get("Cache-Control")).toBe("no-store");
  });
});
