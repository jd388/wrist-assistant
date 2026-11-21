import { performance } from "node:perf_hooks";

import { describe, expect, it, vi } from "vitest";

import { finalizeDocument, readStatic, type Fetcher } from "../src/reader";
import type { DNSResolver } from "../src/security";
import type { ReadRequest } from "../src/types";

const publicResolver: DNSResolver = async () => ["93.184.216.34"];

function request(overrides: Partial<ReadRequest> = {}): ReadRequest {
  return {
    url: "https://example.com/start",
    prefer_dynamic: false,
    max_blocks: 40,
    max_characters: 12_000,
    max_links: 30,
    ...overrides
  };
}

describe("readStatic", () => {
  it("extracts useful semantic blocks and safe links without running page scripts", async () => {
    const html = `<!doctype html>
      <html><head><title> Example &amp; Test </title></head><body>
        <nav><p>Navigation should disappear</p></nav>
        <main>
          <h1>Heading</h1>
          <p>Hello <strong>small watch</strong> &amp; reader.</p>
          <blockquote>A quotation</blockquote>
          <pre>const answer = 42;</pre>
          <a href="/next">Next page</a>
          <a href="javascript:alert(1)">Unsafe</a>
        </main>
        <script>throw new Error("must not execute")</script>
      </body></html>`;
    const fetcher = vi.fn<Fetcher>(async () => new Response(html, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8" }
    }));

    const result = await readStatic(request(), fetcher, publicResolver);

    expect(fetcher).toHaveBeenCalledOnce();
    expect(result.response).toMatchObject({
      final_url: "https://example.com/start",
      title: "Example & Test",
      source: "static",
      blocked_subresources: 0
    });
    expect(result.response.blocks).toEqual([
      { kind: "heading", text: "Heading" },
      { kind: "paragraph", text: "Hello small watch & reader." },
      { kind: "quote", text: "A quotation" },
      { kind: "code", text: "const answer = 42;" }
    ]);
    expect(result.response.links).toEqual([
      { text: "Next page", url: "https://example.com/next" }
    ]);
    expect(result.requiresDynamic).toBe(false);
    expect(JSON.stringify(result.response)).not.toContain("must not execute");
  });

  it("marks a script-heavy shell with little text for Browser Run fallback", async () => {
    const html = "<html><head><title>App</title></head><body><main><p>Loading</p></main>"
      + "<script src='/bundle.js'></script></body></html>";
    const result = await readStatic(
      request(),
      async () => new Response(html, { headers: { "Content-Type": "text/html" } }),
      publicResolver
    );
    expect(result.requiresDynamic).toBe(true);
    expect(result.response.blocks).toEqual([{ kind: "paragraph", text: "Loading" }]);
  });

  it("revalidates every redirect and blocks an SSRF redirect before a second fetch", async () => {
    const fetcher = vi.fn<Fetcher>(async () => new Response(null, {
      status: 302,
      headers: { Location: "http://127.0.0.1/admin" }
    }));

    await expect(readStatic(request(), fetcher, publicResolver)).rejects.toMatchObject({
      code: "url_blocked",
      status: 400
    });
    expect(fetcher).toHaveBeenCalledOnce();
  });

  it("supports a validated relative redirect and reports the final URL", async () => {
    const fetcher = vi.fn<Fetcher>(async (input) => {
      const url = String(input);
      if (url.endsWith("/start")) {
        return new Response(null, { status: 303, headers: { Location: "/article" } });
      }
      return new Response("<html><body><main><p>Final document</p></main></body></html>", {
        headers: { "Content-Type": "text/html" }
      });
    });
    const result = await readStatic(request(), fetcher, publicResolver);
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(result.response.final_url).toBe("https://example.com/article");
  });

  it("parses a bounded prefix when Content-Length declares an oversized page", async () => {
    const result = await readStatic(
      request(),
      async () => new Response("useful body prefix", {
        headers: {
          "Content-Type": "text/plain",
          "Content-Length": "10000000"
        }
      }),
      publicResolver
    );
    expect(result.requiresDynamic).toBe(false);
    expect(result.response).toMatchObject({
      source: "static",
      truncated: true,
      blocks: [{ kind: "paragraph", text: "useful body prefix" }]
    });
  });

  it("cancels a chunked response at the safety cap and returns its readable prefix", async () => {
    const large = new Uint8Array(250_000).fill(65);
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(large);
        controller.enqueue(large);
        controller.close();
      }
    });
    const result = await readStatic(
      request(),
      async () => new Response(body, { headers: { "Content-Type": "text/plain" } }),
      publicResolver
    );
    expect(result.requiresDynamic).toBe(false);
    expect(result.response.source).toBe("static");
    expect(result.response.truncated).toBe(true);
    expect(result.response.blocks[0]?.text.length).toBeLessThanOrEqual(20_000);
  });

  it("keeps the timeout active while a response body stalls after its headers", async () => {
    vi.useFakeTimers();
    try {
      const fetcher = vi.fn<Fetcher>(async (_input, init) => {
        const signal = init?.signal;
        const body = new ReadableStream<Uint8Array>({
          start(controller) {
            signal?.addEventListener("abort", () => {
              controller.error(new Error("aborted stalled body"));
            }, { once: true });
          }
        });
        return new Response(body, { headers: { "Content-Type": "text/html" } });
      });
      const pending = readStatic(
        request({ url: "https://93.184.216.34/stalled" }),
        fetcher,
        publicResolver
      );
      const assertion = expect(pending).rejects.toMatchObject({
        code: "web_fetch_timeout",
        status: 504,
        retryable: true
      });
      await Promise.resolve();
      await vi.advanceTimersByTimeAsync(12_001);
      await assertion;
    } finally {
      vi.useRealTimers();
    }
  });

  it("cancels rejected upstream bodies instead of leaving their streams open", async () => {
    const cancel = vi.fn();
    const body = new ReadableStream<Uint8Array>({ cancel });
    await expect(readStatic(
      request(),
      async () => new Response(body, { status: 503 }),
      publicResolver
    )).rejects.toMatchObject({ code: "web_upstream_rejected", status: 502 });
    expect(cancel).toHaveBeenCalledOnce();
  });

  it("keeps bounded scan time and output on a large adversarial document", async () => {
    const paragraphs = Array.from(
      { length: 5_200 },
      (_, index) => `<p>${index.toString(36)}</p>`
    ).join("");
    const links = Array.from(
      { length: 2_100 },
      (_, index) => `<a href="/${index.toString(36)}">x</a>`
    ).join("");
    const malformedNoise = `<script ${"a".repeat(40_000)}`;
    const html = `<html><head><title>Stress</title></head><body><main>${paragraphs}${links}${malformedNoise}</main></body></html>`;
    expect(new TextEncoder().encode(html).byteLength).toBeGreaterThan(100_000);

    const started = performance.now();
    const result = await readStatic(
      request({ max_blocks: 80, max_characters: 20_000, max_links: 60 }),
      async () => new Response(html, { headers: { "Content-Type": "text/html" } }),
      publicResolver
    );
    const elapsed = performance.now() - started;

    // Keep generous host/CI headroom while still catching the former
    // multi-second/backtracking class of regressions near the 10 ms Worker CPU
    // target. This is a local timing guard, not proof of production CPU time.
    expect(elapsed).toBeLessThan(50);
    expect(result.response.blocks).toHaveLength(80);
    expect(result.response.links).toHaveLength(60);
    expect(result.response.truncated).toBe(true);
    expect(result.response.links_truncated).toBe(true);
    expect(result.response.character_count).toBeLessThanOrEqual(20_000);
  });
});

describe("finalizeDocument", () => {
  it("truncates at character, block, and link boundaries with truthful counts", () => {
    const response = finalizeDocument(
      "https://example.com/requested",
      "https://example.com/final",
      "  Title  ",
      [
        { kind: "paragraph", text: "abcdef" },
        { kind: "paragraph", text: "ghijkl" }
      ],
      [
        { text: "one", url: "https://example.com/one" },
        { text: "two", url: "https://example.com/two" }
      ],
      { max_blocks: 2, max_characters: 8, max_links: 1 },
      "static"
    );
    expect(response.blocks).toEqual([
      { kind: "paragraph", text: "abcdef" },
      { kind: "paragraph", text: "g…" }
    ]);
    expect(response.character_count).toBe(8);
    expect(response.total_character_count).toBe(12);
    expect(response.truncated).toBe(true);
    expect(response.links_truncated).toBe(true);
  });
});
