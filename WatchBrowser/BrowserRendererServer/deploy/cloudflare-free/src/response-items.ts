import {
  MAX_RESPONSE_ITEM_BYTES,
  MAX_RESPONSE_ITEMS_BYTES_PER_ASSISTANT,
  MAX_RESPONSE_ITEMS_PER_ASSISTANT,
  type DeepSeekResponseItem
} from "./types";

const MAX_JSON_DEPTH = 16;
const MAX_JSON_NODES = 4_096;
const MAX_JSON_KEY_BYTES = 1_024;
const ALLOWED_RESPONSE_ITEM_TYPES = new Set([
  "reasoning",
  "message",
  "web_search_call"
]);

export type ResponseItemsFailure =
  | "not_array"
  | "count"
  | "invalid_json"
  | "unsupported_type"
  | "invalid_message_role"
  | "missing_assistant_message"
  | "item_too_large"
  | "array_too_large";

export type ResponseItemsInspection =
  | {
      ok: true;
      items: DeepSeekResponseItem[];
      bytes: number;
    }
  | {
      ok: false;
      reason: ResponseItemsFailure;
      itemIndex?: number;
    };

interface JSONValidationState {
  nodes: number;
  active: WeakSet<object>;
}

// Foundation's JSONEncoder escapes forward slashes while JSON.stringify does
// not. Count that extra byte so anything accepted here also remains below the
// Watch-side byte cap after its lossless JSON value is re-encoded.
function watchCompatibleJSONBytes(value: unknown): number | null {
  let encoded: string;
  try {
    encoded = JSON.stringify(value);
  } catch {
    return null;
  }
  const utf8Bytes = new TextEncoder().encode(encoded).byteLength;
  const slashEscapes = encoded.match(/\//g)?.length ?? 0;
  return utf8Bytes + slashEscapes;
}

function validJSONValue(
  value: unknown,
  depth: number,
  state: JSONValidationState
): boolean {
  if (depth > MAX_JSON_DEPTH) return false;
  state.nodes += 1;
  if (state.nodes > MAX_JSON_NODES) return false;
  if (value === null || typeof value === "boolean") return true;
  if (typeof value === "number") return Number.isFinite(value);
  if (typeof value === "string") {
    return new TextEncoder().encode(value).byteLength <= MAX_RESPONSE_ITEM_BYTES;
  }
  if (typeof value !== "object") return false;
  if (state.active.has(value)) return false;
  state.active.add(value);
  try {
    if (Array.isArray(value)) {
      return value.every((child) => validJSONValue(child, depth + 1, state));
    }
    for (const [key, child] of Object.entries(value)) {
      if (new TextEncoder().encode(key).byteLength > MAX_JSON_KEY_BYTES) return false;
      if (!validJSONValue(child, depth + 1, state)) return false;
    }
    return true;
  } finally {
    state.active.delete(value);
  }
}

export function inspectResponseItems(value: unknown): ResponseItemsInspection {
  if (!Array.isArray(value)) return { ok: false, reason: "not_array" };
  if (value.length === 0 || value.length > MAX_RESPONSE_ITEMS_PER_ASSISTANT) {
    return { ok: false, reason: "count" };
  }

  let hasAssistantMessage = false;
  for (let index = 0; index < value.length; index += 1) {
    const rawItem = value[index];
    if (typeof rawItem !== "object" || rawItem === null || Array.isArray(rawItem)) {
      return { ok: false, reason: "invalid_json", itemIndex: index };
    }
    const item = rawItem as DeepSeekResponseItem;
    if (typeof item.type !== "string" || !ALLOWED_RESPONSE_ITEM_TYPES.has(item.type)) {
      return { ok: false, reason: "unsupported_type", itemIndex: index };
    }
    if (item.type === "message" && item.role !== "assistant") {
      return { ok: false, reason: "invalid_message_role", itemIndex: index };
    }
    if (item.type === "message") hasAssistantMessage = true;
    if (!validJSONValue(item, 0, { nodes: 0, active: new WeakSet() })) {
      return { ok: false, reason: "invalid_json", itemIndex: index };
    }

    const itemBytes = watchCompatibleJSONBytes(item);
    if (itemBytes === null) {
      return { ok: false, reason: "invalid_json", itemIndex: index };
    }
    if (itemBytes > MAX_RESPONSE_ITEM_BYTES) {
      return { ok: false, reason: "item_too_large", itemIndex: index };
    }
  }

  if (!hasAssistantMessage) {
    return { ok: false, reason: "missing_assistant_message" };
  }

  const bytes = watchCompatibleJSONBytes(value);
  if (bytes === null) {
    return { ok: false, reason: "invalid_json" };
  }
  if (bytes > MAX_RESPONSE_ITEMS_BYTES_PER_ASSISTANT) {
    return { ok: false, reason: "array_too_large" };
  }
  return { ok: true, items: value as DeepSeekResponseItem[], bytes };
}

export const __test = {
  MAX_JSON_DEPTH,
  MAX_JSON_NODES,
  MAX_JSON_KEY_BYTES,
  watchCompatibleJSONBytes,
  validJSONValue
};
