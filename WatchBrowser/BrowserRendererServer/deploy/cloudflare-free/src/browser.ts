import type {
  Browser,
  BrowserContext,
  Frame,
  Page,
  Route,
  WebSocketRoute
} from "@cloudflare/playwright";
import { Buffer } from "node:buffer";

import {
  ServiceError,
  browserServiceError,
  errorResponse,
  jsonResponse
} from "./errors";
import { finalizeDocument } from "./reader";
import { safeHTTPLink, validateURL, type ValidatedURL } from "./security";
import type {
  BrowserSessionHealth,
  Environment,
  FillRequest,
  FrameResponse,
  OpenRequest,
  ReadBlock,
  ReadLink,
  ReadRequest,
  ReadResponse,
  ScrollRequest,
  TapRequest
} from "./types";

const MOBILE_CHROME_USER_AGENT =
  "Mozilla/5.0 (Linux; Android 14; Pixel 7) "
  + "AppleWebKit/537.36 (KHTML, like Gecko) "
  + "Chrome/131.0.0.0 Mobile Safari/537.36";
const DEFAULT_IDLE_MS = 60_000;
const NAVIGATION_TIMEOUT_MS = 20_000;
// Keep the base64-encoded frame plus JSON metadata below the 60 KiB
// WatchConnectivity relay body ceiling. Direct HTTPS clients use the same
// smaller frame, which is still ample for the 396 x 484 Watch viewport.
const MAXIMUM_IMAGE_BYTES = 42_000;
const MAXIMUM_VALIDATED_HOSTS = 20;
const MAXIMUM_INTERACTION_VIEWPORT = 4_096;

let playwrightModule: Promise<typeof import("@cloudflare/playwright")> | null = null;

function playwright(): Promise<typeof import("@cloudflare/playwright")> {
  // Keep Playwright's comparatively large initialization off the static reader
  // and AI-only hot paths of a 10 ms Free Worker.
  playwrightModule ??= import("@cloudflare/playwright");
  return playwrightModule;
}

const SCROLL_PROGRESS_SCRIPT = `() => {
  const root = document.scrollingElement || document.documentElement;
  const top = Math.max(0, root ? root.scrollTop : window.scrollY || 0);
  const height = Math.max(
    root ? root.scrollHeight : 0,
    document.body ? document.body.scrollHeight : 0
  );
  const viewport = Math.max(1, window.innerHeight || 1);
  const maximum = Math.max(0, height - viewport);
  return maximum > 0 ? Math.min(1, Math.max(0, top / maximum)) : 0;
}`;

const VISUAL_VIEWPORT_SCRIPT = `() => {
  const viewport = window.visualViewport;
  return {
    width: viewport ? viewport.width : window.innerWidth,
    height: viewport ? viewport.height : window.innerHeight
  };
}`;

const DOM_SIGNAL_SCRIPT = `() => {
  const body = document.body;
  const text = body && body.innerText ? body.innerText.trim() : "";
  return {
    textChars: Math.min(100000, text.length),
    links: document.querySelectorAll("a[href]").length,
    images: document.querySelectorAll("img,svg,canvas,video").length
  };
}`;

const FOCUSED_INPUT_SCRIPT = `() => {
  if (!document.hasFocus()) return { focused: false, label: null };
  const element = document.activeElement;
  if (!element) return { focused: false, label: null };
  const tag = element.tagName ? element.tagName.toLowerCase() : "";
  const type = tag === "input"
    ? String(element.getAttribute("type") || "text").toLowerCase()
    : "";
  const types = new Set(["text", "search", "url", "tel", "email", "password", "number"]);
  const editable = tag === "textarea"
    || (tag === "input" && types.has(type))
    || element.isContentEditable;
  if (!editable || element.disabled || element.readOnly) {
    return { focused: false, label: null };
  }
  const labelText = element.labels
    ? Array.from(element.labels).map(item => item.innerText || item.textContent || "").join(" ")
    : "";
  const raw = element.getAttribute("aria-label")
    || labelText
    || element.getAttribute("placeholder")
    || element.getAttribute("name")
    || element.getAttribute("title")
    || null;
  const label = raw ? String(raw).replace(/\\s+/g, " ").trim().slice(0, 120) || null : null;
  return { focused: true, label };
}`;

const TAP_LINK_SCRIPT = `({ x, y }) => {
  const element = document.elementFromPoint(x, y);
  const anchor = element && element.closest ? element.closest("a[href]") : null;
  return anchor ? anchor.href : null;
}`;

const READER_DOCUMENT_SCRIPT = `({ maxBlocks, maxCharacters, maxLinks }) => {
  const clean = value => String(value || "").replace(/\\s+/g, " ").trim();
  const root = document.querySelector("main")
    || document.querySelector("article")
    || document.querySelector('[role="main"]')
    || document.body
    || document.documentElement;
  const selector = "h1,h2,h3,h4,h5,h6,p,li,blockquote,pre";
  const candidates = root ? Array.from(root.querySelectorAll(selector)).slice(0, 5000) : [];
  const blocks = [];
  const seenText = new Set();
  let totalCharacterCount = 0;
  let remaining = maxCharacters;
  let truncated = candidates.length >= 5000;
  for (const element of candidates) {
    const parentBlock = element.parentElement && element.parentElement.closest(selector);
    if (parentBlock && root.contains(parentBlock)) continue;
    if (element.closest('[hidden],[aria-hidden="true"]')) continue;
    const style = window.getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden") continue;
    const text = clean(element.innerText || element.textContent);
    if (!text || seenText.has(text)) continue;
    seenText.add(text);
    totalCharacterCount += text.length;
    if (blocks.length >= maxBlocks || remaining <= 0) {
      truncated = true;
      continue;
    }
    let kind = "paragraph";
    const tag = element.tagName.toLowerCase();
    if (/^h[1-6]$/.test(tag)) kind = "heading";
    else if (tag === "li") kind = "list_item";
    else if (tag === "blockquote") kind = "quote";
    else if (tag === "pre") kind = "code";
    let rendered = text;
    if (rendered.length > remaining) {
      rendered = rendered.slice(0, remaining).trim();
      if (rendered.length > 1) rendered = rendered.slice(0, -1) + "…";
      truncated = true;
    }
    if (rendered) blocks.push({ kind, text: rendered });
    remaining -= rendered.length;
  }
  if (!blocks.length && root) {
    const fallback = clean(root.innerText || root.textContent);
    totalCharacterCount = Math.max(totalCharacterCount, fallback.length);
    if (fallback) {
      let rendered = fallback.slice(0, maxCharacters);
      if (fallback.length > rendered.length && rendered.length > 1) {
        rendered = rendered.slice(0, -1) + "…";
        truncated = true;
      }
      blocks.push({ kind: "paragraph", text: rendered });
    }
  }
  const links = [];
  const seenURLs = new Set();
  const anchors = root ? Array.from(root.querySelectorAll("a[href]")).slice(0, 2000) : [];
  let linksTruncated = anchors.length >= 2000;
  for (const anchor of anchors) {
    let parsed;
    try { parsed = new URL(anchor.getAttribute("href"), location.href); }
    catch (_) { continue; }
    if (!new Set(["http:", "https:"]).has(parsed.protocol)) continue;
    if (parsed.username || parsed.password || seenURLs.has(parsed.href)) continue;
    seenURLs.add(parsed.href);
    if (links.length >= maxLinks) {
      linksTruncated = true;
      continue;
    }
    const label = clean(anchor.innerText || anchor.textContent) || parsed.hostname || "Link";
    links.push({ text: label.slice(0, 160), url: parsed.href.slice(0, 4096) });
  }
  return {
    title: clean(document.title), blocks, links, totalCharacterCount, truncated, linksTruncated
  };
}`;

function invokeScript(script: string, argument?: unknown): string {
  if (argument === undefined) return `(${script})()`;
  const serialized = JSON.stringify(argument);
  if (serialized === undefined) {
    throw new TypeError("Browser script arguments must be JSON serializable.");
  }
  return `(${script})(${serialized})`;
}

interface StoredBrowserSession {
  appSessionId: string;
  browserSessionId: string;
  primaryHost: string;
  viewportWidth: number;
  viewportHeight: number;
  sequence: number;
  lastAccess: number;
}

interface InteractionViewport {
  width: number;
  height: number;
}

interface QuotaState {
  dailyLimitUntil: number | null;
}

interface LiveBrowserSession {
  browser: Browser;
  context: BrowserContext;
  page: Page;
  guard: NetworkGuard;
}

interface FocusedInput {
  frame: Frame;
  label: string | null;
}

interface DynamicExtraction {
  title?: unknown;
  blocks?: unknown;
  links?: unknown;
  totalCharacterCount?: unknown;
  truncated?: unknown;
  linksTruncated?: unknown;
}

function safeViewportDimension(value: unknown, fallback: number): number {
  const safeFallback = Number.isFinite(fallback)
    && fallback >= 1
    && fallback <= MAXIMUM_INTERACTION_VIEWPORT
    ? fallback
    : 1;
  return typeof value === "number"
    && Number.isFinite(value)
    && value >= 1
    && value <= MAXIMUM_INTERACTION_VIEWPORT
    ? value
    : safeFallback;
}

function safeVisualViewport(
  value: unknown,
  fallbackWidth: number,
  fallbackHeight: number
): InteractionViewport {
  const candidate = typeof value === "object" && value !== null
    ? value as Record<string, unknown>
    : {};
  return {
    width: safeViewportDimension(candidate.width, fallbackWidth),
    height: safeViewportDimension(candidate.height, fallbackHeight)
  };
}

function normalizedPoint(
  x: number,
  y: number,
  viewport: InteractionViewport
): { x: number; y: number } {
  return {
    x: Math.min(viewport.width - 1, Math.max(0, x * viewport.width)),
    y: Math.min(viewport.height - 1, Math.max(0, y * viewport.height))
  };
}

async function interactionViewport(
  page: Page,
  session: StoredBrowserSession
): Promise<InteractionViewport> {
  try {
    const raw = await page.evaluate(invokeScript(VISUAL_VIEWPORT_SCRIPT)) as unknown;
    return safeVisualViewport(raw, session.viewportWidth, session.viewportHeight);
  } catch {
    return safeVisualViewport(null, session.viewportWidth, session.viewportHeight);
  }
}

function isIPAddress(host: string): boolean {
  return host.includes(":") || /^\d{1,3}(?:\.\d{1,3}){3}$/.test(host);
}

export function guardrailDomains(host: string): string[] {
  return isIPAddress(host) ? [host] : [host, `*.${host}`];
}

function hostWithinPrimary(host: string, primary: string): boolean {
  return host === primary || !isIPAddress(primary) && host.endsWith(`.${primary}`);
}

function sessionExpired(): ServiceError {
  return new ServiceError(
    "session_expired",
    "The browser session expired. Open the page again.",
    410,
    false
  );
}

function cannotGoBack(): ServiceError {
  return new ServiceError(
    "cannot_go_back",
    "The page has no previous browser history entry.",
    409,
    false
  );
}

class NetworkGuard {
  navigationError: ServiceError | null = null;
  blockedSubresources = 0;
  private readonly validations = new Map<string, Promise<void>>();

  constructor(private readonly primaryHost: string) {}

  async install(context: BrowserContext): Promise<void> {
    await context.route("**/*", (route) => this.route(route));
    await context.routeWebSocket("**/*", (websocket) => this.websocket(websocket));
  }

  assertNavigation(): void {
    if (this.navigationError) throw this.navigationError;
  }

  navigationFailure(): ServiceError | null {
    return this.navigationError;
  }

  reset(): void {
    this.navigationError = null;
    this.blockedSubresources = 0;
    this.validations.clear();
  }

  private async validate(rawURL: string, navigation: boolean): Promise<void> {
    const parsed = new URL(rawURL);
    if (navigation && !hostWithinPrimary(parsed.hostname.toLowerCase(), this.primaryHost)) {
      throw new ServiceError(
        "url_blocked",
        "Cross-site navigation is blocked inside this protected browser session. Open the target as a new page.",
        400,
        false
      );
    }
    const key = `${parsed.protocol}//${parsed.hostname.toLowerCase()}:${parsed.port}`;
    let pending = this.validations.get(key);
    if (!pending) {
      if (this.validations.size >= MAXIMUM_VALIDATED_HOSTS) {
        throw new ServiceError(
          "url_blocked",
          "The page requested too many distinct network hosts.",
          400,
          false
        );
      }
      pending = validateURL(rawURL).then(() => undefined);
      this.validations.set(key, pending);
    }
    await pending;
  }

  private async route(route: Route): Promise<void> {
    const request = route.request();
    const navigation = request.isNavigationRequest()
      && request.frame() === request.frame().page().mainFrame();
    try {
      await this.validate(request.url(), navigation);
      await route.continue();
    } catch (error) {
      const blocked = error instanceof ServiceError
        ? error
        : new ServiceError("url_blocked", "The page requested an unsafe network target.", 400, false);
      if (navigation) this.navigationError = blocked;
      else this.blockedSubresources += 1;
      try {
        await route.abort("blockedbyclient");
      } catch {
        // The browser may have already cancelled this request.
      }
    }
  }

  private async websocket(websocket: WebSocketRoute): Promise<void> {
    this.blockedSubresources += 1;
    await websocket.close({
      code: 1008,
      reason: "WatchBrowser permits HTTP(S) page resources only."
    });
  }
}

function contextOptions(width: number, height: number) {
  return {
    viewport: { width, height },
    screen: { width, height },
    deviceScaleFactor: 2,
    isMobile: true,
    hasTouch: true,
    acceptDownloads: false,
    ignoreHTTPSErrors: false,
    javaScriptEnabled: true,
    serviceWorkers: "block" as const,
    userAgent: MOBILE_CHROME_USER_AGENT,
    locale: "zh-CN",
    colorScheme: "light" as const,
    extraHTTPHeaders: { "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8" }
  };
}

async function terminateBrowser(browser: Browser): Promise<void> {
  try {
    await browser.close();
  } catch {
    // Best-effort cleanup only.
  }
}

async function settle(page: Page): Promise<void> {
  try {
    await page.waitForLoadState("domcontentloaded", { timeout: 2_000 });
  } catch {
    // Many taps and scrolls do not trigger a navigation.
  }
  await page.waitForTimeout(300);
}

async function focusedInput(page: Page): Promise<FocusedInput | null> {
  for (const frame of page.frames()) {
    try {
      const output = await frame.evaluate(invokeScript(FOCUSED_INPUT_SCRIPT)) as unknown;
      if (typeof output !== "object" || output === null) continue;
      const result = output as Record<string, unknown>;
      if (result.focused !== true) continue;
      return {
        frame,
        label: typeof result.label === "string" ? result.label.slice(0, 120) : null
      };
    } catch {
      // Cross-origin frames may disappear while being inspected.
    }
  }
  return null;
}

async function canGoBack(page: Page): Promise<boolean> {
  try {
    const cdp = await page.context().newCDPSession(page);
    try {
      const history = await cdp.send("Page.getNavigationHistory");
      return history.entries
        .slice(0, history.currentIndex)
        .some((entry) => /^https?:\/\//i.test(entry.url));
    } finally {
      await cdp.detach();
    }
  } catch {
    return Boolean(await page.evaluate("window.history.length > 1"));
  }
}

async function screenshot(page: Page): Promise<Uint8Array> {
  for (const quality of [60, 45, 30, 20, 10, 1]) {
    const bytes = await page.screenshot({
      type: "jpeg",
      quality,
      fullPage: false,
      scale: "css",
      animations: "disabled",
      caret: "hide",
      timeout: 8_000
    });
    if (bytes.byteLength <= MAXIMUM_IMAGE_BYTES) return bytes;
  }
  throw new ServiceError(
    "frame_too_large",
    "The page image could not be reduced to the Watch frame limit.",
    500,
    true
  );
}

async function buildFrame(
  page: Page,
  session: StoredBrowserSession,
  guard: NetworkGuard,
  message: string
): Promise<FrameResponse> {
  guard.assertNavigation();
  const final = await validateURL(page.url());
  if (!hostWithinPrimary(final.host, session.primaryHost)) {
    throw new ServiceError("url_blocked", "The page navigated outside its protected site boundary.", 400, false);
  }
  const rawSignals = await page.evaluate(invokeScript(DOM_SIGNAL_SCRIPT)) as unknown;
  const signals = typeof rawSignals === "object" && rawSignals !== null
    ? rawSignals as Record<string, unknown>
    : {};
  const hasContent = Number(signals.textChars) > 0
    || Number(signals.links) > 0
    || Number(signals.images) > 0;
  if (!hasContent) {
    throw new ServiceError(
      "empty_page",
      "The target page has no visible page or DOM content.",
      502,
      false
    );
  }
  const image = await screenshot(page);
  const focused = await focusedInput(page);
  const progress = Number(await page.evaluate(invokeScript(SCROLL_PROGRESS_SCRIPT)));
  session.sequence += 1;
  if (guard.blockedSubresources > 0) {
    message = `${message} Blocked ${guard.blockedSubresources} unsafe page resource(s).`;
  }
  return {
    session_id: session.appSessionId,
    sequence: session.sequence,
    url: final.url.slice(0, 4_096),
    title: (await page.title()).trim().slice(0, 256),
    can_go_back: await canGoBack(page),
    scroll_progress: Number.isFinite(progress) ? Math.min(1, Math.max(0, progress)) : 0,
    image_base64: Buffer.from(image).toString("base64"),
    message,
    focused_input: focused !== null,
    focused_input_label: focused?.label ?? null
  };
}

function parseDynamicExtraction(value: unknown): DynamicExtraction {
  return typeof value === "object" && value !== null ? value as DynamicExtraction : {};
}

function dynamicBlocks(raw: unknown): ReadBlock[] {
  if (!Array.isArray(raw)) return [];
  const output: ReadBlock[] = [];
  for (const item of raw) {
    if (typeof item !== "object" || item === null) continue;
    const value = item as Record<string, unknown>;
    const text = typeof value.text === "string" ? value.text.trim().slice(0, 20_000) : "";
    if (!text) continue;
    const kind = ["heading", "paragraph", "list_item", "quote", "code"].includes(String(value.kind))
      ? String(value.kind) as ReadBlock["kind"]
      : "paragraph";
    output.push({ kind, text });
  }
  return output;
}

function dynamicLinks(raw: unknown): ReadLink[] {
  if (!Array.isArray(raw)) return [];
  const output: ReadLink[] = [];
  const seen = new Set<string>();
  for (const item of raw) {
    if (typeof item !== "object" || item === null) continue;
    const value = item as Record<string, unknown>;
    const url = typeof value.url === "string" ? safeHTTPLink(value.url) : null;
    if (!url || seen.has(url)) continue;
    seen.add(url);
    const text = typeof value.text === "string" ? value.text.trim().slice(0, 160) : "";
    output.push({ text: text || new URL(url).hostname || "Link", url });
  }
  return output;
}

export async function readDynamic(request: ReadRequest, env: Environment): Promise<ReadResponse> {
  const requested = await validateURL(request.url);
  let browser: Browser | null = null;
  try {
    const { launch } = await playwright();
    browser = await launch(env.BROWSER, {
      recording: false,
      guardrails: {
        allowedDomains: guardrailDomains(requested.host),
        allowedDomainSets: ["common-cdns"]
      }
    });
    const context = await browser.newContext(contextOptions(396, 484));
    const guard = new NetworkGuard(requested.host);
    await guard.install(context);
    const page = await context.newPage();
    page.setDefaultNavigationTimeout(NAVIGATION_TIMEOUT_MS);
    page.setDefaultTimeout(NAVIGATION_TIMEOUT_MS);
    try {
      await page.goto(requested.url, {
        waitUntil: "domcontentloaded",
        timeout: NAVIGATION_TIMEOUT_MS
      });
    } catch (error) {
      guard.assertNavigation();
      throw error;
    }
    await settle(page);
    await page.waitForTimeout(500);
    guard.assertNavigation();
    const final = await validateURL(page.url());
    if (!hostWithinPrimary(final.host, requested.host)) {
      throw new ServiceError("url_blocked", "The page redirected outside its protected site boundary.", 400, false);
    }
    const extracted = parseDynamicExtraction(await page.evaluate(invokeScript(READER_DOCUMENT_SCRIPT, {
      maxBlocks: request.max_blocks,
      maxCharacters: request.max_characters,
      maxLinks: request.max_links
    })));
    const blocks = dynamicBlocks(extracted.blocks);
    if (!blocks.length) {
      throw new ServiceError("empty_page", "The browser found no readable page content.", 502, false);
    }
    return finalizeDocument(
      request.url,
      final.url,
      typeof extracted.title === "string" ? extracted.title : "",
      blocks,
      dynamicLinks(extracted.links),
      request,
      "browser",
      guard.blockedSubresources,
      Boolean(extracted.truncated) || Boolean(extracted.linksTruncated)
    );
  } catch (error) {
    if (error instanceof ServiceError) throw error;
    throw browserServiceError(error);
  } finally {
    if (browser) await terminateBrowser(browser);
  }
}

export class BrowserSession {
  private current: StoredBrowserSession | null = null;
  private live: LiveBrowserSession | null = null;
  private quota: QuotaState = { dailyLimitUntil: null };
  private readonly ready: Promise<void>;
  private pending: Promise<void> = Promise.resolve();

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Environment
  ) {
    this.ready = state.blockConcurrencyWhile(async () => {
      // Incognito Playwright contexts are disposeOnDetach. If this Durable
      // Object was evicted, its outbound CDP connection is gone and the stored
      // context cannot be reconstructed. Fail closed and let Browser Run reap
      // that orphan at its default 60-second idle timeout.
      if (await state.storage.get<StoredBrowserSession>("session")) {
        await state.storage.delete("session");
      }
      await state.storage.deleteAlarm();
      this.current = null;
      this.quota = await state.storage.get<QuotaState>("quota") ?? { dailyLimitUntil: null };
    });
  }

  async alarm(): Promise<void> {
    await this.ready;
    const execute = async (): Promise<void> => {
      if (!this.current) return;
      const expiresAt = this.current.lastAccess + DEFAULT_IDLE_MS;
      if (expiresAt > Date.now()) {
        await this.state.storage.setAlarm(expiresAt);
        return;
      }
      await this.terminateCurrent();
    };
    let resolveQueue!: () => void;
    const prior = this.pending;
    this.pending = new Promise<void>((resolve) => { resolveQueue = resolve; });
    await prior;
    try {
      await execute();
    } finally {
      resolveQueue();
    }
  }

  async fetch(request: Request): Promise<Response> {
    await this.ready;
    const execute = async (): Promise<Response> => {
      try {
        return await this.route(request);
      } catch (error) {
        const mapped = error instanceof ServiceError ? error : browserServiceError(error);
        if (mapped.code === "browser_daily_limit") {
          const retry = Number(mapped.headers.get("Retry-After") || 0);
          this.quota.dailyLimitUntil = Date.now() + retry * 1_000;
          await this.state.storage.put("quota", this.quota);
        }
        return errorResponse(mapped);
      }
    };
    let resolveQueue!: () => void;
    const prior = this.pending;
    this.pending = new Promise<void>((resolve) => { resolveQueue = resolve; });
    await prior;
    try {
      return await execute();
    } finally {
      resolveQueue();
    }
  }

  private async route(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return jsonResponse(await this.health());
    }
    if (request.method === "POST" && url.pathname === "/open") {
      return jsonResponse(await this.open(await request.json() as OpenRequest));
    }
    const operation = /^\/sessions\/([^/]+)\/(scroll|tap|fill|back|refresh)$/.exec(url.pathname);
    if (request.method === "POST" && operation) {
      const sessionId = decodeURIComponent(operation[1] ?? "");
      const action = operation[2] ?? "";
      const body = await request.json() as ScrollRequest | TapRequest | FillRequest | Record<string, never>;
      return jsonResponse(await this.operate(sessionId, action, body));
    }
    const closing = /^\/sessions\/([^/]+)$/.exec(url.pathname);
    if (request.method === "DELETE" && closing) {
      await this.close(decodeURIComponent(closing[1] ?? ""));
      return new Response(null, { status: 204 });
    }
    return errorResponse(new ServiceError("not_found", "The internal session route was not found.", 404, false));
  }

  private async health(): Promise<BrowserSessionHealth> {
    const limit = this.quota.dailyLimitUntil;
    if (limit !== null && limit <= Date.now()) {
      this.quota.dailyLimitUntil = null;
      await this.state.storage.put("quota", this.quota);
    }
    if (this.current && Date.now() - this.current.lastAccess >= DEFAULT_IDLE_MS) {
      await this.terminateCurrent();
    }
    return {
      active: this.current !== null,
      daily_limit_until: this.quota.dailyLimitUntil
    };
  }

  private async open(input: OpenRequest): Promise<FrameResponse> {
    if (this.quota.dailyLimitUntil !== null && this.quota.dailyLimitUntil > Date.now()) {
      throw new ServiceError(
        "browser_daily_limit",
        "Today's free cloud-browser allowance has been used. Static reading and AI remain available; interactive browsing resets after 00:00 UTC.",
        429,
        false,
        { "Retry-After": String(Math.max(1, Math.ceil((this.quota.dailyLimitUntil - Date.now()) / 1_000))) }
      );
    }
    const target = await validateURL(input.url);
    let browser: Browser | null = null;
    if (this.current && this.live && this.current.primaryHost === target.host) {
      const previous = this.live;
      try {
        browser = previous.browser;
        try { await previous.context.setOffline(true); } catch { /* immutable guardrails remain */ }
        await previous.context.close();
      } catch {
        await this.clearCurrent();
        await terminateBrowser(previous.browser);
        browser = null;
      }
    } else if (this.current) {
      await this.terminateCurrent();
    }
    if (!browser) {
      const { launch } = await playwright();
      browser = await launch(this.env.BROWSER, {
        recording: false,
        guardrails: {
          allowedDomains: guardrailDomains(target.host),
          allowedDomainSets: ["common-cdns"]
        }
      });
    }
    const stored: StoredBrowserSession = {
      appSessionId: crypto.randomUUID().replaceAll("-", ""),
      browserSessionId: browser.sessionId(),
      primaryHost: target.host,
      viewportWidth: input.viewport_width,
      viewportHeight: input.viewport_height,
      sequence: 0,
      lastAccess: Date.now()
    };
    let context: BrowserContext | undefined;
    try {
      context = await browser.newContext(contextOptions(input.viewport_width, input.viewport_height));
      const guard = new NetworkGuard(target.host);
      await guard.install(context);
      const page = await context.newPage();
      page.setDefaultNavigationTimeout(NAVIGATION_TIMEOUT_MS);
      page.setDefaultTimeout(NAVIGATION_TIMEOUT_MS);
      try {
        await page.goto(target.url, {
          waitUntil: "domcontentloaded",
          timeout: NAVIGATION_TIMEOUT_MS
        });
      } catch (error) {
        guard.assertNavigation();
        throw error;
      }
      await settle(page);
      guard.assertNavigation();
      const frame = await buildFrame(page, stored, guard, "Page opened.");
      stored.lastAccess = Date.now();
      this.current = stored;
      this.live = { browser, context, page, guard };
      await this.state.storage.put("session", stored);
      await context.setOffline(true);
      await this.state.storage.setAlarm(stored.lastAccess + DEFAULT_IDLE_MS);
      return frame;
    } catch (error) {
      await terminateBrowser(browser);
      await this.clearCurrent();
      throw error;
    }
  }

  private async operate(
    sessionId: string,
    action: string,
    body: ScrollRequest | TapRequest | FillRequest | Record<string, never>
  ): Promise<FrameResponse> {
    const stored = this.current;
    const live = this.live;
    if (!stored || !live || stored.appSessionId !== sessionId) throw sessionExpired();
    if (Date.now() - stored.lastAccess >= DEFAULT_IDLE_MS) {
      await this.terminateCurrent();
      throw sessionExpired();
    }
    live.guard.reset();
    try {
      await live.context.setOffline(false);
      let message: string;
      if (action === "scroll") {
        const input = body as ScrollRequest;
        const viewport = await interactionViewport(live.page, stored);
        await live.page.mouse.wheel(0, input.amount * viewport.height);
        message = "Page scrolled.";
      } else if (action === "tap") {
        const input = body as TapRequest;
        const viewport = await interactionViewport(live.page, stored);
        const point = normalizedPoint(input.x, input.y, viewport);
        const target = await live.page.evaluate(invokeScript(TAP_LINK_SCRIPT, {
          x: point.x,
          y: point.y
        })) as unknown;
        if (typeof target === "string") {
          const validated = await validateURL(target);
          if (!hostWithinPrimary(validated.host, stored.primaryHost)) {
            return await this.replaceAcrossSite(stored, live, validated);
          }
        }
        await live.page.touchscreen.tap(point.x, point.y);
        message = "Page tapped.";
      } else if (action === "fill") {
        const input = body as FillRequest;
        const focused = await focusedInput(live.page);
        if (!focused) {
          throw new ServiceError(
            "input_not_focused",
            "No editable input is focused. Tap a text field before filling it.",
            409,
            false
          );
        }
        const locator = focused.frame.locator(":focus").first();
        try {
          await locator.fill(input.text);
          if (input.submit) await locator.press("Enter");
        } catch {
          throw new ServiceError(
            "input_not_focused",
            "The focused input is no longer editable. Tap it and try again.",
            409,
            true
          );
        }
        message = input.submit ? "Text submitted." : "Text filled.";
      } else if (action === "back") {
        if (!await canGoBack(live.page)) throw cannotGoBack();
        const previousURL = live.page.url();
        const result = await live.page.goBack({
          // Returning to a cached or form-originated page can commit promptly
          // while DOMContentLoaded remains pending on a slow third-party
          // resource. `settle()` below performs the bounded DOM wait before we
          // validate and capture the frame.
          waitUntil: "commit",
          timeout: NAVIGATION_TIMEOUT_MS
        });
        if (result === null) {
          // Cloudflare's Playwright fork can return null for a successful
          // BFCache/form-history traversal. Only report failure when the page
          // also stayed at the same URL after the bounded settle.
          await settle(live.page);
          live.guard.assertNavigation();
          if (live.page.url() === previousURL) throw cannotGoBack();
        }
        message = "Returned to the previous page.";
      } else if (action === "refresh") {
        await live.page.reload({
          waitUntil: "commit",
          timeout: NAVIGATION_TIMEOUT_MS
        });
        message = "Page refreshed.";
      } else {
        throw new ServiceError("not_found", "The browser operation was not found.", 404, false);
      }
      await settle(live.page);
      live.guard.assertNavigation();
      const frame = await buildFrame(live.page, stored, live.guard, message);
      stored.lastAccess = Date.now();
      await this.state.storage.put("session", stored);
      await live.context.setOffline(true);
      await this.state.storage.setAlarm(stored.lastAccess + DEFAULT_IDLE_MS);
      return frame;
    } catch (error) {
      const navigationError = live.guard.navigationFailure();
      try {
        await live.context.setOffline(true);
      } catch {
        // If the page cannot be put back into the safe idle state, close the
        // whole session rather than leave background network activity running.
        await this.terminateCurrent();
      }
      if (!live.browser.isConnected() && this.live === live) await this.clearCurrent();
      if (navigationError) throw navigationError;
      throw error;
    }
  }

  private async replaceAcrossSite(
    stored: StoredBrowserSession,
    previous: LiveBrowserSession,
    target: ValidatedURL
  ): Promise<FrameResponse> {
    // Browser Run guardrails are immutable. Build the target in a new guarded
    // browser while the old session remains available, then swap only after a
    // complete frame and durable metadata have both succeeded.
    await previous.context.setOffline(true);
    let candidateBrowser: Browser | null = null;
    let candidatePersisted = false;
    try {
      const { launch } = await playwright();
      candidateBrowser = await launch(this.env.BROWSER, {
        recording: false,
        guardrails: {
          allowedDomains: guardrailDomains(target.host),
          allowedDomainSets: ["common-cdns"]
        }
      });
      const context = await candidateBrowser.newContext(
        contextOptions(stored.viewportWidth, stored.viewportHeight)
      );
      const guard = new NetworkGuard(target.host);
      await guard.install(context);
      const page = await context.newPage();
      page.setDefaultNavigationTimeout(NAVIGATION_TIMEOUT_MS);
      page.setDefaultTimeout(NAVIGATION_TIMEOUT_MS);
      try {
        await page.goto(target.url, {
          waitUntil: "domcontentloaded",
          timeout: NAVIGATION_TIMEOUT_MS
        });
      } catch (error) {
        guard.assertNavigation();
        throw error;
      }
      await settle(page);
      guard.assertNavigation();
      const candidate: StoredBrowserSession = {
        appSessionId: crypto.randomUUID().replaceAll("-", ""),
        browserSessionId: candidateBrowser.sessionId(),
        primaryHost: target.host,
        viewportWidth: stored.viewportWidth,
        viewportHeight: stored.viewportHeight,
        // The Watch applies a returned session_id only after accepting a newer
        // frame sequence, so a replacement must continue the old sequence.
        sequence: stored.sequence,
        lastAccess: Date.now()
      };
      const frame = await buildFrame(page, candidate, guard, "Opened the cross-site link in a new protected session.");
      candidate.lastAccess = Date.now();
      await context.setOffline(true);
      await this.state.storage.put("session", candidate);
      candidatePersisted = true;
      await this.state.storage.setAlarm(candidate.lastAccess + DEFAULT_IDLE_MS);

      this.current = candidate;
      this.live = { browser: candidateBrowser, context, page, guard };
      candidateBrowser = null;
      await terminateBrowser(previous.browser);
      return frame;
    } catch (error) {
      if (candidateBrowser) await terminateBrowser(candidateBrowser);
      if (candidatePersisted) {
        try {
          await this.state.storage.put("session", stored);
          await this.state.storage.setAlarm(stored.lastAccess + DEFAULT_IDLE_MS);
        } catch {
          // If the old durable metadata cannot be restored, do not leave an
          // apparently-live in-memory session that will vanish inconsistently.
          if (this.live === previous) await this.terminateCurrent();
        }
      }
      if (this.live === previous) {
        try {
          await previous.context.setOffline(true);
        } catch {
          await this.terminateCurrent();
        }
      }
      throw error;
    }
  }

  private async close(sessionId: string): Promise<void> {
    if (!this.current || this.current.appSessionId !== sessionId) return;
    await this.terminateCurrent();
  }

  private async terminateCurrent(): Promise<void> {
    const live = this.live;
    await this.clearCurrent();
    if (!live) return;
    try { await live.context.setOffline(true); } catch { /* best effort */ }
    await terminateBrowser(live.browser);
  }

  private async clearCurrent(): Promise<void> {
    this.current = null;
    this.live = null;
    await this.state.storage.delete("session");
    await this.state.storage.deleteAlarm();
  }
}

export const __test = {
  DEFAULT_IDLE_MS,
  MAXIMUM_INTERACTION_VIEWPORT,
  MAXIMUM_IMAGE_BYTES,
  invokeScript,
  hostWithinPrimary,
  normalizedPoint,
  safeVisualViewport,
  dynamicBlocks,
  dynamicLinks
};
