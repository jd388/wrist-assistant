import { ServiceError, validationError } from "./errors";
import { inspectResponseItems } from "./response-items";
import {
  MAX_RESPONSE_ITEMS_BYTES_PER_HISTORY,
  MAX_RESPONSE_ITEM_BYTES,
  MAX_RESPONSE_ITEMS_PER_ASSISTANT,
  type AskHistoryMessage,
  type AskPageContext,
  type AskRequest,
  type FillRequest,
  type OpenRequest,
  type ReadBlock,
  type ReadRequest,
  type ScrollRequest,
  type TapRequest
} from "./types";

type JSONObject = Record<string, unknown>;

function object(value: unknown): JSONObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw validationError("body: a JSON object is required");
  }
  return value as JSONObject;
}

function strict(value: JSONObject, keys: readonly string[]): void {
  const allowed = new Set(keys);
  const extra = Object.keys(value).find((key) => !allowed.has(key));
  if (extra) throw validationError(`body.${extra}: extra fields are not permitted`);
}

function string(
  value: unknown,
  name: string,
  minimum: number,
  maximum: number
): string {
  const characterCount = typeof value === "string" ? Array.from(value).length : 0;
  if (typeof value !== "string" || characterCount < minimum || characterCount > maximum) {
    throw validationError(`${name}: must be a string between ${minimum} and ${maximum} characters`);
  }
  return value;
}

function number(
  value: unknown,
  name: string,
  minimum: number,
  maximum: number,
  integer = false
): number {
  if (
    typeof value !== "number" ||
    !Number.isFinite(value) ||
    value < minimum ||
    value > maximum ||
    integer && !Number.isInteger(value)
  ) {
    throw validationError(`${name}: must be ${integer ? "an integer" : "a number"} between ${minimum} and ${maximum}`);
  }
  return value;
}

function boolean(value: unknown, name: string, fallback: boolean): boolean {
  if (value === undefined) return fallback;
  if (typeof value !== "boolean") throw validationError(`${name}: must be a boolean`);
  return value;
}

export function parseOpen(value: unknown): OpenRequest {
  const body = object(value);
  strict(body, ["url", "viewport_width", "viewport_height"]);
  return {
    url: string(body.url, "body.url", 1, 4096),
    viewport_width: number(body.viewport_width ?? 396, "body.viewport_width", 160, 512, true),
    viewport_height: number(body.viewport_height ?? 484, "body.viewport_height", 160, 640, true)
  };
}

export function parseScroll(value: unknown): ScrollRequest {
  const body = object(value);
  strict(body, ["amount"]);
  return { amount: number(body.amount, "body.amount", -3, 3) };
}

export function parseTap(value: unknown): TapRequest {
  const body = object(value);
  strict(body, ["x", "y"]);
  return {
    x: number(body.x, "body.x", 0, 1),
    y: number(body.y, "body.y", 0, 1)
  };
}

export function parseFill(value: unknown): FillRequest {
  const body = object(value);
  strict(body, ["text", "submit"]);
  return {
    text: string(body.text, "body.text", 0, 500),
    submit: boolean(body.submit, "body.submit", false)
  };
}

export function parseEmpty(value: unknown): Record<string, never> {
  const body = object(value);
  strict(body, []);
  return {};
}

export function parseRead(value: unknown): ReadRequest {
  const body = object(value);
  strict(body, ["url", "prefer_dynamic", "max_blocks", "max_characters", "max_links"]);
  return {
    url: string(body.url, "body.url", 1, 4096),
    prefer_dynamic: boolean(body.prefer_dynamic, "body.prefer_dynamic", false),
    max_blocks: number(body.max_blocks ?? 40, "body.max_blocks", 1, 80, true),
    max_characters: number(body.max_characters ?? 12_000, "body.max_characters", 500, 20_000, true),
    max_links: number(body.max_links ?? 30, "body.max_links", 0, 60, true)
  };
}

function parseReadBlock(value: unknown, index: number): ReadBlock {
  const block = object(value);
  strict(block, ["kind", "text"]);
  const kind = string(block.kind, `body.page.blocks.${index}.kind`, 1, 20);
  if (!["heading", "paragraph", "list_item", "quote", "code"].includes(kind)) {
    throw validationError(`body.page.blocks.${index}.kind: unsupported block kind`);
  }
  return {
    kind: kind as ReadBlock["kind"],
    text: string(block.text, `body.page.blocks.${index}.text`, 1, 20_000)
  };
}

function parsePage(value: unknown): AskPageContext | null {
  if (value === undefined || value === null) return null;
  const page = object(value);
  strict(page, ["url", "title", "blocks"]);
  if (page.url !== undefined && page.url !== null && typeof page.url !== "string") {
    throw validationError("body.page.url: must be a string or null");
  }
  if (page.title !== undefined && page.title !== null && typeof page.title !== "string") {
    throw validationError("body.page.title: must be a string or null");
  }
  const url = page.url === undefined || page.url === null
    ? null
    : string(page.url, "body.page.url", 0, 4096).trim() || null;
  const title = page.title === undefined || page.title === null
    ? null
    : string(page.title, "body.page.title", 0, 512).trim() || null;
  const rawBlocks = page.blocks ?? [];
  if (!Array.isArray(rawBlocks) || rawBlocks.length > 80) {
    throw validationError("body.page.blocks: must be an array containing at most 80 blocks");
  }
  const blocks = rawBlocks.map(parseReadBlock);
  if (!url && !title && !blocks.length) {
    throw validationError("body.page: must contain a URL, title, or content block");
  }
  return { url, title, blocks };
}

function parseResponseItems(
  value: unknown,
  messageIndex: number
): ReturnType<typeof inspectResponseItems> & { ok: true } {
  const name = `body.history.${messageIndex}.response_items`;
  const inspected = inspectResponseItems(value);
  if (!inspected.ok) {
    const item = inspected.itemIndex === undefined ? name : `${name}.${inspected.itemIndex}`;
    if (inspected.reason === "count" || inspected.reason === "not_array") {
      throw validationError(
        `${name}: must be a non-empty array containing at most ${MAX_RESPONSE_ITEMS_PER_ASSISTANT} items`
      );
    }
    if (inspected.reason === "unsupported_type") {
      throw validationError(`${item}.type: must be reasoning, message, or web_search_call`);
    }
    if (inspected.reason === "invalid_message_role") {
      throw validationError(`${item}.role: message items must have assistant role`);
    }
    if (inspected.reason === "missing_assistant_message") {
      throw validationError(`${name}: must contain an assistant message item`);
    }
    if (inspected.reason === "item_too_large") {
      throw validationError(`${item}: JSON must not exceed ${MAX_RESPONSE_ITEM_BYTES} UTF-8 bytes`);
    }
    throw validationError(`${item}: must be bounded, valid JSON`);
  }
  return inspected;
}

function parseHistory(value: unknown): AskRequest["history"] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 24) {
    throw validationError("body.history: must be an array containing at most 24 messages");
  }
  let totalCharacters = 0;
  let totalBytes = 0;
  let totalResponseItemBytes = 0;
  const history = value.map((rawMessage, index) => {
    const message = object(rawMessage);
    strict(message, ["role", "content", "response_items"]);
    const role = string(message.role, `body.history.${index}.role`, 1, 20);
    if (role !== "user" && role !== "assistant") {
      throw validationError(`body.history.${index}.role: must be user or assistant`);
    }
    const content = string(
      message.content,
      `body.history.${index}.content`,
      1,
      8_000
    ).trim();
    if (!content) {
      throw validationError(`body.history.${index}.content: must not be blank`);
    }
    const contentBytes = new TextEncoder().encode(content).byteLength;
    if (contentBytes > 32_000) {
      throw validationError(`body.history.${index}.content: must not exceed 32000 UTF-8 bytes`);
    }
    totalCharacters += Array.from(content).length;
    totalBytes += contentBytes;
    if (totalCharacters > 24_000) {
      throw validationError("body.history: total content must not exceed 24000 characters");
    }
    if (totalBytes > 96_000) {
      throw validationError("body.history: total content must not exceed 96000 UTF-8 bytes");
    }
    const hasResponseItems = Object.prototype.hasOwnProperty.call(message, "response_items");
    if (role === "user") {
      if (hasResponseItems) {
        throw validationError(`body.history.${index}.response_items: user messages must not carry response items`);
      }
      return { role: "user", content } satisfies AskHistoryMessage;
    }
    if (!hasResponseItems) {
      return { role: "assistant", content } satisfies AskHistoryMessage;
    }

    const responseItems = parseResponseItems(message.response_items, index);
    totalResponseItemBytes += responseItems.bytes;
    if (totalResponseItemBytes > MAX_RESPONSE_ITEMS_BYTES_PER_HISTORY) {
      throw validationError(
        `body.history: response_items JSON must not exceed ${MAX_RESPONSE_ITEMS_BYTES_PER_HISTORY} total UTF-8 bytes`
      );
    }
    return {
      role: "assistant",
      content,
      response_items: responseItems.items
    } satisfies AskHistoryMessage;
  });
  if (history.length % 2 !== 0) {
    throw validationError("body.history: must contain complete user and assistant turns");
  }
  history.forEach((message, index) => {
    const expected = index % 2 === 0 ? "user" : "assistant";
    if (message.role !== expected) {
      throw validationError("body.history: roles must alternate user then assistant");
    }
  });
  return history;
}

export function parseAsk(value: unknown): AskRequest {
  const body = object(value);
  strict(body, [
    "request_id",
    "question",
    "mode",
    "web_search",
    "deep_thinking",
    "history",
    "page"
  ]);
  const requestID = body.request_id === undefined
    ? crypto.randomUUID()
    : string(body.request_id, "body.request_id", 36, 36).toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(requestID)) {
    throw validationError("body.request_id: must be a UUID");
  }
  const mode = body.mode === undefined
    ? "answer"
    : string(body.mode, "body.mode", 1, 20);
  if (mode !== "answer" && mode !== "summarize") {
    throw validationError("body.mode: must be answer or summarize");
  }
  const question = body.question === undefined
    ? ""
    : string(body.question, "body.question", 0, 2_000).trim();
  if (new TextEncoder().encode(question).byteLength > 8_000) {
    throw validationError("body.question: must not exceed 8000 UTF-8 bytes");
  }
  const page = parsePage(body.page);
  if (mode === "answer" && !question) {
    throw validationError("body.question: must not be empty in answer mode");
  }
  if (mode === "summarize" && page === null) {
    throw validationError("body.page: is required in summarize mode");
  }
  return {
    request_id: requestID,
    question,
    mode,
    web_search: boolean(body.web_search, "body.web_search", false),
    deep_thinking: boolean(body.deep_thinking, "body.deep_thinking", false),
    history: parseHistory(body.history),
    page
  };
}

export async function readJSON(request: Request, maximumBytes = 64 * 1024): Promise<unknown> {
  const declared = request.headers.get("content-length");
  if (declared && /^\d+$/.test(declared) && Number(declared) > maximumBytes) {
    throw requestTooLarge();
  }
  if (!request.body) throw validationError("body: a JSON object is required");
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      if (!value) continue;
      total += value.byteLength;
      if (total > maximumBytes) throw requestTooLarge();
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw validationError("body: malformed JSON");
  }
}

function requestTooLarge(): ServiceError {
  return new ServiceError(
    "request_too_large",
    "The request body exceeded the server safety limit.",
    413,
    false
  );
}
