export type BlockKind =
  | "heading"
  | "paragraph"
  | "list_item"
  | "quote"
  | "code";

export interface ReadBlock {
  kind: BlockKind;
  text: string;
}

export interface ReadLink {
  text: string;
  url: string;
}

export interface ReadRequest {
  url: string;
  prefer_dynamic: boolean;
  max_blocks: number;
  max_characters: number;
  max_links: number;
}

export interface ReadResponse {
  url: string;
  final_url: string;
  title: string;
  blocks: ReadBlock[];
  links: ReadLink[];
  truncated: boolean;
  links_truncated: boolean;
  character_count: number;
  total_character_count: number;
  source: "static" | "browser";
  blocked_subresources: number;
}

export interface OpenRequest {
  url: string;
  viewport_width: number;
  viewport_height: number;
}

export interface ScrollRequest {
  amount: number;
}

export interface TapRequest {
  x: number;
  y: number;
}

export interface FillRequest {
  text: string;
  submit: boolean;
}

export interface FrameResponse {
  session_id: string;
  sequence: number;
  url: string;
  title: string;
  can_go_back: boolean;
  scroll_progress: number;
  image_base64: string;
  message: string;
  focused_input: boolean;
  focused_input_label: string | null;
}

export interface HealthResponse {
  status: "ok" | "degraded";
  browser_ready: boolean;
  browser_egress_isolated: boolean;
  reader_ready: boolean;
  ai_configured: boolean;
  active_sessions: number;
  max_sessions: number;
  detail: string | null;
}

export interface BrowserSessionHealth {
  active: boolean;
  daily_limit_until: number | null;
}

export interface AskPageContext {
  url: string | null;
  title: string | null;
  blocks: ReadBlock[];
}

export type DeepSeekResponseItem = Record<string, unknown>;

export type AskHistoryMessage =
  | {
      role: "user";
      content: string;
      response_items?: never;
    }
  | {
      role: "assistant";
      content: string;
      response_items?: DeepSeekResponseItem[];
    };

// Keep one provider context small enough to return to a Watch and leave room
// for visible history inside the 256 KiB /v1/ask request envelope.
export const MAX_RESPONSE_ITEMS_PER_ASSISTANT = 24;
export const MAX_RESPONSE_ITEM_BYTES = 48 * 1024;
export const MAX_RESPONSE_ITEMS_BYTES_PER_ASSISTANT = 64 * 1024;
export const MAX_RESPONSE_ITEMS_BYTES_PER_HISTORY = 128 * 1024;

export interface AskRequest {
  request_id: string;
  question: string;
  mode: "answer" | "summarize";
  web_search: boolean;
  deep_thinking: boolean;
  history: AskHistoryMessage[];
  page: AskPageContext | null;
}

export interface Citation {
  title: string;
  url: string;
}

export type WebSearchProvider = "deepseek";

export interface AskResponse {
  answer: string;
  reasoning: string | null;
  citations: Citation[];
  model: string;
  web_search_used: boolean;
  web_search_provider: WebSearchProvider | null;
  page_context_used: boolean;
  truncated: boolean;
  response_items?: DeepSeekResponseItem[];
}

export type AskStreamEvent =
  | ({ type: "metadata" } & Omit<AskResponse, "answer" | "reasoning" | "truncated">)
  | { type: "reasoning_delta"; text: string }
  | { type: "delta"; text: string }
  | { type: "done"; answer: string; reasoning: string | null; truncated: boolean }
  | { type: "error"; code: string; message: string; retryable: boolean };

export interface Environment {
  BROWSER: Fetcher;
  BROWSER_SESSION: DurableObjectNamespace;
  BROWSER_RENDERER_TOKEN?: string;
  DEEPSEEK_API_KEY?: string;
  BROWSER_RENDERER_AI_API_KEY?: string;
}
