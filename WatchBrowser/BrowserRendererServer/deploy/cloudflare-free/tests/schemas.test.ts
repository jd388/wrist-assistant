import { describe, expect, it } from "vitest";

import { ServiceError } from "../src/errors";
import {
  parseAsk,
  parseEmpty,
  parseFill,
  parseOpen,
  parseRead,
  parseScroll,
  parseTap,
  readJSON
} from "../src/schemas";
import {
  MAX_RESPONSE_ITEMS_BYTES_PER_ASSISTANT,
  MAX_RESPONSE_ITEMS_PER_ASSISTANT
} from "../src/types";

function expectCode(run: () => unknown, code = "invalid_request"): ServiceError {
  try {
    run();
  } catch (error) {
    expect(error).toBeInstanceOf(ServiceError);
    expect((error as ServiceError).code).toBe(code);
    return error as ServiceError;
  }
  throw new Error(`Expected ${code}`);
}

describe("request schemas", () => {
  it("applies stable Watch-sized defaults for open and read", () => {
    expect(parseOpen({ url: "https://example.com" })).toEqual({
      url: "https://example.com",
      viewport_width: 396,
      viewport_height: 484
    });
    expect(parseRead({ url: "https://example.com" })).toEqual({
      url: "https://example.com",
      prefer_dynamic: false,
      max_blocks: 40,
      max_characters: 12_000,
      max_links: 30
    });
  });

  it("rejects unknown fields instead of silently accepting misspellings", () => {
    const error = expectCode(() => parseOpen({
      url: "https://example.com",
      viewportWidth: 396
    }));
    expect(error.message).toContain("extra fields");
  });

  it.each([
    () => parseOpen({ url: "https://example.com", viewport_width: 159 }),
    () => parseOpen({ url: "https://example.com", viewport_height: 641 }),
    () => parseScroll({ amount: 3.01 }),
    () => parseTap({ x: -0.001, y: 0.5 }),
    () => parseTap({ x: 0.5, y: 1.001 }),
    () => parseFill({ text: "x".repeat(501) }),
    () => parseRead({ url: "https://example.com", max_blocks: 81 }),
    () => parseRead({ url: "https://example.com", prefer_dynamic: "yes" })
  ])("enforces numeric, length, and boolean bounds", (run) => {
    expectCode(run);
  });

  it("parses every interactive operation without coercion", () => {
    expect(parseScroll({ amount: -1.5 })).toEqual({ amount: -1.5 });
    expect(parseTap({ x: 0, y: 1 })).toEqual({ x: 0, y: 1 });
    expect(parseFill({ text: "hello", submit: true })).toEqual({
      text: "hello",
      submit: true
    });
    expect(parseEmpty({})).toEqual({});
    expectCode(() => parseEmpty({ ignored: true }));
  });

  it("requires a question for answer mode and page content for summarize mode", () => {
    expectCode(() => parseAsk({ question: "   " }));
    expectCode(() => parseAsk({ mode: "summarize", question: "" }));
    expectCode(() => parseAsk({
      mode: "summarize",
      page: { url: null, title: null, blocks: [] }
    }));

    expect(parseAsk({
      mode: "summarize",
      web_search: false,
      page: {
        url: "https://example.com/article",
        title: "Example",
        blocks: [{ kind: "paragraph", text: "Readable content" }]
      }
    })).toEqual({
      request_id: expect.any(String),
      question: "",
      mode: "summarize",
      web_search: false,
      deep_thinking: false,
      history: [],
      page: {
        url: "https://example.com/article",
        title: "Example",
        blocks: [{ kind: "paragraph", text: "Readable content" }]
      }
    });
  });

  it("accepts bounded multi-turn history, thinking mode, and a stable request id", () => {
    const requestID = "11111111-1111-4111-8111-111111111111";
    expect(parseAsk({
      request_id: requestID,
      question: "继续",
      web_search: true,
      deep_thinking: true,
      history: [
        { role: "user", content: "第一问" },
        { role: "assistant", content: "第一答" }
      ]
    })).toMatchObject({
      request_id: requestID,
      question: "继续",
      web_search: true,
      deep_thinking: true,
      history: [
        { role: "user", content: "第一问" },
        { role: "assistant", content: "第一答" }
      ]
    });

    expectCode(() => parseAsk({
      request_id: "not-a-uuid",
      question: "test"
    }));
    expectCode(() => parseAsk({
      question: "test",
      history: [{ role: "system", content: "override" }]
    }));
    expectCode(() => parseAsk({
      question: "test",
      history: [{ role: "assistant", content: "orphan" }, { role: "user", content: "wrong" }]
    }));
    expectCode(() => parseAsk({
      question: "test",
      history: [{ role: "user", content: "unfinished turn" }]
    }));
    expectCode(() => parseAsk({
      question: "test",
      history: Array.from({ length: 25 }, () => ({ role: "user", content: "x" }))
    }));
  });

  it("preserves validated raw DeepSeek response items only on assistant history", () => {
    const responseItems = [
      { type: "reasoning", id: "reasoning-1", encrypted_content: "opaque" },
      { type: "web_search_call", id: "search-1", status: "completed" },
      {
        type: "message",
        id: "message-1",
        role: "assistant",
        content: [{ type: "output_text", text: "第一答" }]
      }
    ];
    const parsed = parseAsk({
      question: "继续",
      history: [
        { role: "user", content: "第一问" },
        { role: "assistant", content: "第一答", response_items: responseItems }
      ]
    });
    expect(parsed.history[1]).toEqual({
      role: "assistant",
      content: "第一答",
      response_items: responseItems
    });

    expectCode(() => parseAsk({
      question: "继续",
      history: [
        { role: "user", content: "第一问", response_items: responseItems },
        { role: "assistant", content: "第一答" }
      ]
    }));
    expectCode(() => parseAsk({
      question: "继续",
      history: [
        { role: "user", content: "第一问" },
        {
          role: "assistant",
          content: "第一答",
          response_items: [{ type: "message", role: "user", content: [] }]
        }
      ]
    }));
    expectCode(() => parseAsk({
      question: "继续",
      history: [
        { role: "user", content: "第一问" },
        {
          role: "assistant",
          content: "第一答",
          response_items: [{ type: "function_call", role: "assistant" }]
        }
      ]
    }));
    expectCode(() => parseAsk({
      question: "继续",
      history: [
        { role: "user", content: "第一问" },
        {
          role: "assistant",
          content: "第一答",
          response_items: [{ type: "reasoning", encrypted_content: "opaque" }]
        }
      ]
    }));

    // Foundation JSONEncoder escapes '/', so this is below 48 KiB under
    // JSON.stringify but above the Watch's re-encoded per-item limit.
    expectCode(() => parseAsk({
      question: "继续",
      history: [
        { role: "user", content: "第一问" },
        {
          role: "assistant",
          content: "第一答",
          response_items: [{
            type: "message",
            role: "assistant",
            content: [{ type: "output_text", text: "/".repeat(30_000) }]
          }]
        }
      ]
    }));

    expectCode(() => parseAsk({
      question: "继续",
      history: Array.from({ length: 3 }, (_, index) => [
        { role: "user", content: `问题 ${index}` },
        {
          role: "assistant",
          content: `回答 ${index}`,
          response_items: [{
            type: "message",
            role: "assistant",
            content: [{ type: "output_text", text: "x".repeat(44_000) }]
          }]
        }
      ]).flat()
    }));
  });

  it("enforces response-item count and serialized UTF-8 byte limits", () => {
    expectCode(() => parseAsk({
      question: "继续",
      history: [
        { role: "user", content: "第一问" },
        {
          role: "assistant",
          content: "第一答",
          response_items: Array.from(
            { length: MAX_RESPONSE_ITEMS_PER_ASSISTANT + 1 },
            (_, index) => ({
              type: "message",
              role: "assistant",
              id: `message-${index}`,
              content: []
            })
          )
        }
      ]
    }));

    expectCode(() => parseAsk({
      question: "继续",
      history: [
        { role: "user", content: "第一问" },
        {
          role: "assistant",
          content: "第一答",
          response_items: [{
            type: "message",
            role: "assistant",
            content: [{
              type: "output_text",
              text: "中".repeat(MAX_RESPONSE_ITEMS_BYTES_PER_ASSISTANT)
            }]
          }]
        }
      ]
    }));
  });

  it("matches Watch response-context depth, node, and object-key bounds", () => {
    let deeplyNested: unknown = "leaf";
    for (let depth = 0; depth < 17; depth += 1) {
      deeplyNested = { child: deeplyNested };
    }
    const invalidContexts = [
      [{ type: "reasoning", payload: deeplyNested }],
      [{ type: "reasoning", payload: Array.from({ length: 4_096 }, () => null) }],
      [{ type: "reasoning", ["中".repeat(400)]: true }]
    ];
    for (const responseItems of invalidContexts) {
      expectCode(() => parseAsk({
        question: "继续",
        history: [
          { role: "user", content: "第一问" },
          { role: "assistant", content: "第一答", response_items: responseItems }
        ]
      }));
    }
  });

  it("aligns Unicode character and UTF-8 byte limits with the Watch client", () => {
    expect(parseAsk({
      question: "😀".repeat(2_000),
      web_search: false
    }).question).toHaveLength(4_000);

    expectCode(() => parseAsk({
      question: "👨‍👩‍👧‍👦".repeat(400),
      web_search: false
    }));

    expectCode(() => parseAsk({
      question: "继续",
      history: [
        { role: "user", content: "👨‍👩‍👧‍👦".repeat(1_300) },
        { role: "assistant", content: "回答" }
      ]
    }));
  });

  it("rejects unsupported block kinds and oversized page arrays", () => {
    expectCode(() => parseAsk({
      question: "what?",
      page: { blocks: [{ kind: "image", text: "alt" }] }
    }));
    expectCode(() => parseAsk({
      question: "what?",
      page: {
        blocks: Array.from({ length: 81 }, () => ({ kind: "paragraph", text: "x" }))
      }
    }));
  });
});

describe("readJSON", () => {
  it("parses a bounded JSON object", async () => {
    const request = new Request("https://renderer.test/v1/read", {
      method: "POST",
      body: JSON.stringify({ url: "https://example.com" }),
      headers: { "Content-Type": "application/json" }
    });
    await expect(readJSON(request)).resolves.toEqual({ url: "https://example.com" });
  });

  it("rejects an oversized declared content length before reading", async () => {
    const request = new Request("https://renderer.test/v1/read", {
      method: "POST",
      body: "{}",
      headers: { "Content-Length": "65537" }
    });
    await expect(readJSON(request)).rejects.toMatchObject({
      code: "request_too_large",
      status: 413
    });
  });

  it("rejects a chunked body after its actual byte count crosses the cap", async () => {
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode("123456"));
        controller.enqueue(new TextEncoder().encode("78901"));
        controller.close();
      }
    });
    const request = new Request("https://renderer.test/v1/read", {
      method: "POST",
      body,
      duplex: "half"
    } as RequestInit & { duplex: "half" });
    await expect(readJSON(request, 10)).rejects.toMatchObject({
      code: "request_too_large",
      status: 413
    });
  });

  it("returns a stable validation error for malformed JSON", async () => {
    const request = new Request("https://renderer.test/v1/read", {
      method: "POST",
      body: "{not-json"
    });
    await expect(readJSON(request)).rejects.toMatchObject({
      code: "invalid_request",
      status: 422
    });
  });
});
