import { ServiceError } from "./errors";
import { safeHTTPLink, validateURL, type DNSResolver } from "./security";
import type { BlockKind, ReadBlock, ReadLink, ReadRequest, ReadResponse } from "./types";

export interface StaticReadResult {
  response: ReadResponse;
  requiresDynamic: boolean;
}

export type Fetcher = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

const REDIRECTS = new Set([301, 302, 303, 307, 308]);
const ALLOWED_TYPES = new Set(["text/html", "application/xhtml+xml", "text/plain"]);
// A Free Worker has a 10 ms CPU budget. Keep attacker-controlled HTML bounded
// and parse it with the single-pass tokenizer below instead of whole-document
// backtracking regular expressions.
const MAXIMUM_RESPONSE_BYTES = 192_000;
const MAXIMUM_REDIRECTS = 5;
const DYNAMIC_THRESHOLD = 180;
// The public API can return at most 80 blocks and 60 links. Scan a small
// reserve for empty/duplicate entries, then keep walking only to recognize the
// document shape; do not allocate thousands of attacker-controlled records.
const MAXIMUM_SCANNED_BLOCKS = 160;
const MAXIMUM_SCANNED_LINKS = 120;
const READER_USER_AGENT = "WatchBrowser/0.6 (+https://workers.cloudflare.com)";

function cleanText(value: string): string {
  return decodeEntities(value).replace(/\s+/g, " ").trim();
}

function decodeEntities(value: string): string {
  const named: Record<string, string> = {
    amp: "&",
    apos: "'",
    gt: ">",
    lt: "<",
    nbsp: " ",
    quot: "\""
  };
  return value.replace(/&(#x[0-9a-f]+|#\d+|amp|apos|gt|lt|nbsp|quot);/gi, (match, entity: string) => {
    const lower = entity.toLowerCase();
    if (lower.startsWith("#x")) {
      const point = Number.parseInt(lower.slice(2), 16);
      return Number.isSafeInteger(point) && point <= 0x10ffff ? String.fromCodePoint(point) : "�";
    }
    if (lower.startsWith("#")) {
      const point = Number.parseInt(lower.slice(1), 10);
      return Number.isSafeInteger(point) && point <= 0x10ffff ? String.fromCodePoint(point) : "�";
    }
    return named[lower] ?? match;
  });
}

function mediaType(header: string | null): string | null {
  const value = header?.split(";", 1)[0]?.trim().toLowerCase();
  return value || null;
}

function charset(header: string | null): string {
  const match = /charset\s*=\s*["']?([^;"'\s]+)/i.exec(header ?? "");
  return match?.[1]?.trim().toLowerCase() || "utf-8";
}

interface BoundedBody {
  bytes: Uint8Array;
  truncated: boolean;
}

async function boundedBytes(response: Response): Promise<BoundedBody> {
  const declared = response.headers.get("content-length");
  let truncated = Boolean(
    declared
    && /^\d+$/.test(declared)
    && Number(declared) > MAXIMUM_RESPONSE_BYTES
  );
  if (!response.body) return { bytes: new Uint8Array(), truncated };
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      if (!value) continue;
      const available = MAXIMUM_RESPONSE_BYTES - total;
      if (value.byteLength > available) {
        if (available > 0) {
          chunks.push(value.subarray(0, available));
          total += available;
        }
        truncated = true;
        await reader.cancel("reader prefix complete");
        break;
      }
      chunks.push(value);
      total += value.byteLength;
      if (total === MAXIMUM_RESPONSE_BYTES) {
        // Do not issue another body read merely to prove an untrusted response
        // ended at this exact byte. Content-Length still gives the precise case.
        truncated ||= declared === null || Number(declared) !== total;
        await reader.cancel("reader prefix complete");
        break;
      }
    }
  } finally {
    reader.releaseLock();
  }
  const output = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { bytes: output, truncated };
}

function decodeBody(bytes: Uint8Array, encoding: string): string {
  try {
    return new TextDecoder(encoding, { fatal: false }).decode(bytes);
  } catch {
    try {
      return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
    } catch {
      throw new ServiceError(
        "unsupported_text_encoding",
        "The target document uses an unsupported text encoding.",
        415,
        false
      );
    }
  }
}

function titleFromURL(url: string): string {
  try {
    return new URL(url).hostname || "Web page";
  } catch {
    return "Web page";
  }
}

type RootName = "main" | "article" | "body" | "global";

interface ExtractionBucket {
  blocks: ReadBlock[];
  links: ReadLink[];
  fallback: string[];
  fallbackLength: number;
}

interface TextCapture {
  tag: string;
  root: RootName;
  kind: BlockKind;
  parts: string[];
  length: number;
}

interface LinkCapture {
  root: RootName;
  href: string;
  parts: string[];
  length: number;
}

const ROOTS = ["main", "article", "body", "global"] as const;
const BLOCK_TAGS = new Set(["h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "blockquote", "pre"]);
const SUPPRESSED_TAGS = new Set([
  "script", "style", "noscript", "template", "svg", "canvas", "form", "nav", "footer", "header", "aside"
]);
const VOID_TAGS = new Set([
  "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"
]);

function bucket(): ExtractionBucket {
  return { blocks: [], links: [], fallback: [], fallbackLength: 0 };
}

function appendBounded(parts: string[], value: string, length: number, maximum: number): number {
  if (length >= maximum || !value) return length;
  const available = maximum - length;
  const output = value.length > available ? value.slice(0, available) : value;
  parts.push(output);
  return length + output.length;
}

function tagName(rawTag: string): { name: string; closing: boolean; selfClosing: boolean } | null {
  let index = 1;
  while (index < rawTag.length && /\s/.test(rawTag[index] ?? "")) index += 1;
  let closing = false;
  if (rawTag[index] === "/") {
    closing = true;
    index += 1;
    while (index < rawTag.length && /\s/.test(rawTag[index] ?? "")) index += 1;
  }
  const start = index;
  while (index < rawTag.length && /[A-Za-z0-9:-]/.test(rawTag[index] ?? "")) index += 1;
  if (index === start) return null;
  return {
    name: rawTag.slice(start, index).toLowerCase(),
    closing,
    selfClosing: /\/\s*>$/.test(rawTag)
  };
}

function findTagEnd(html: string, start: number): number {
  let quote = "";
  for (let index = start + 1; index < html.length; index += 1) {
    const character = html[index] ?? "";
    if (quote) {
      if (character === quote) quote = "";
    } else if (character === "\"" || character === "'") {
      quote = character;
    } else if (character === ">") {
      return index;
    }
  }
  return html.length - 1;
}

function attribute(rawTag: string, target: string): string | null {
  // Attribute parsing is also linear; very large malformed tags are ignored.
  if (rawTag.length > 8_192) return null;
  let index = 1;
  while (index < rawTag.length && !/\s/.test(rawTag[index] ?? "")) index += 1;
  while (index < rawTag.length - 1) {
    while (index < rawTag.length && /[\s/]/.test(rawTag[index] ?? "")) index += 1;
    const start = index;
    while (index < rawTag.length && /[^\s=/>]/.test(rawTag[index] ?? "")) index += 1;
    if (index === start) {
      index += 1;
      continue;
    }
    const name = rawTag.slice(start, index).toLowerCase();
    while (index < rawTag.length && /\s/.test(rawTag[index] ?? "")) index += 1;
    let value = "";
    if (rawTag[index] === "=") {
      index += 1;
      while (index < rawTag.length && /\s/.test(rawTag[index] ?? "")) index += 1;
      const quote = rawTag[index];
      if (quote === "\"" || quote === "'") {
        index += 1;
        const valueStart = index;
        while (index < rawTag.length && rawTag[index] !== quote) index += 1;
        value = rawTag.slice(valueStart, index);
        if (rawTag[index] === quote) index += 1;
      } else {
        const valueStart = index;
        while (index < rawTag.length && /[^\s>]/.test(rawTag[index] ?? "")) index += 1;
        value = rawTag.slice(valueStart, index);
      }
    }
    if (name === target) return decodeEntities(value);
  }
  return null;
}

function blockKind(tag: string): BlockKind {
  if (tag.startsWith("h")) return "heading";
  if (tag === "li") return "list_item";
  if (tag === "blockquote") return "quote";
  if (tag === "pre") return "code";
  return "paragraph";
}

export function extractHTML(
  html: string,
  finalURL: string
): { title: string; blocks: ReadBlock[]; links: ReadLink[]; requiresDynamic: boolean; scanTruncated: boolean } {
  const buckets: Record<RootName, ExtractionBucket> = {
    main: bucket(), article: bucket(), body: bucket(), global: bucket()
  };
  const depth: Record<Exclude<RootName, "global">, number> = { main: 0, article: 0, body: 0 };
  let capture: TextCapture | null = null;
  let link: LinkCapture | null = null;
  let titleParts: string[] | null = null;
  let titleLength = 0;
  let documentTitle = "";
  let suppressed: string | null = null;
  let suppressedDepth = 0;
  let scriptCount = 0;
  let blocksScanned = 0;
  let linksScanned = 0;
  let scanTruncated = false;

  const currentRoot = (): RootName => {
    if (depth.main > 0) return "main";
    if (depth.article > 0) return "article";
    if (depth.body > 0) return "body";
    return "global";
  };
  const appendText = (raw: string): void => {
    if (!raw || suppressed) return;
    const root = currentRoot();
    const target = buckets[root];
    target.fallbackLength = appendBounded(target.fallback, raw, target.fallbackLength, 40_000);
    if (capture) capture.length = appendBounded(capture.parts, raw, capture.length, 24_000);
    if (link) link.length = appendBounded(link.parts, raw, link.length, 1_000);
    if (titleParts) titleLength = appendBounded(titleParts, raw, titleLength, 2_000);
  };
  const finishBlock = (): void => {
    if (!capture) return;
    const text = cleanText(capture.parts.join(""));
    if (text && buckets[capture.root].blocks.length < MAXIMUM_SCANNED_BLOCKS) {
      buckets[capture.root].blocks.push({ kind: capture.kind, text: text.slice(0, 20_000) });
    } else if (text) {
      scanTruncated = true;
    }
    capture = null;
  };
  const finishLink = (): void => {
    if (!link) return;
    const url = safeHTTPLink(link.href, finalURL);
    if (url && buckets[link.root].links.length < MAXIMUM_SCANNED_LINKS) {
      const text = cleanText(link.parts.join("")) || new URL(url).hostname || "Link";
      buckets[link.root].links.push({ text: text.slice(0, 160), url });
    } else if (url) {
      scanTruncated = true;
    }
    link = null;
  };

  let cursor = 0;
  while (cursor < html.length) {
    const opening = html.indexOf("<", cursor);
    if (opening < 0) {
      appendText(html.slice(cursor));
      break;
    }
    appendText(html.slice(cursor, opening));
    if (html.startsWith("<!--", opening)) {
      const close = html.indexOf("-->", opening + 4);
      cursor = close < 0 ? html.length : close + 3;
      continue;
    }
    const end = findTagEnd(html, opening);
    const rawTag = html.slice(opening, end + 1);
    cursor = end + 1;
    const parsed = tagName(rawTag);
    if (!parsed) continue;

    if (suppressed) {
      if (parsed.name !== suppressed) continue;
      if (parsed.closing) {
        suppressedDepth -= 1;
        if (suppressedDepth <= 0) suppressed = null;
      } else if (!parsed.selfClosing && !VOID_TAGS.has(parsed.name)) {
        suppressedDepth += 1;
      }
      continue;
    }

    if (parsed.closing) {
      if (capture?.tag === parsed.name) finishBlock();
      if (parsed.name === "a") finishLink();
      if (parsed.name === "title" && titleParts) {
        documentTitle = cleanText(titleParts.join(""));
        titleParts = null;
      }
      if (parsed.name === "main" || parsed.name === "article" || parsed.name === "body") {
        depth[parsed.name] = Math.max(0, depth[parsed.name] - 1);
      }
      continue;
    }

    if (!parsed.selfClosing && (parsed.name === "main" || parsed.name === "article" || parsed.name === "body")) {
      depth[parsed.name] += 1;
    }
    if (parsed.name === "script") scriptCount += 1;
    if (SUPPRESSED_TAGS.has(parsed.name) && !parsed.selfClosing) {
      suppressed = parsed.name;
      suppressedDepth = 1;
      continue;
    }
    if (parsed.name === "title") {
      titleParts = [];
      titleLength = 0;
    }
    if (BLOCK_TAGS.has(parsed.name) && !capture && !parsed.selfClosing) {
      blocksScanned += 1;
      if (blocksScanned <= MAXIMUM_SCANNED_BLOCKS) {
        capture = {
          tag: parsed.name,
          root: currentRoot(),
          kind: blockKind(parsed.name),
          parts: [],
          length: 0
        };
      } else {
        scanTruncated = true;
      }
    }
    if (parsed.name === "a" && !link && !parsed.selfClosing) {
      linksScanned += 1;
      const href = attribute(rawTag, "href");
      if (href !== null && linksScanned <= MAXIMUM_SCANNED_LINKS) {
        link = { root: currentRoot(), href, parts: [], length: 0 };
      } else if (linksScanned > MAXIMUM_SCANNED_LINKS) {
        scanTruncated = true;
      }
    }
    if (parsed.name === "br" || parsed.name === "hr") appendText("\n");
  }
  finishBlock();
  finishLink();

  const selectedName = ROOTS.find((name) => {
    const value = buckets[name];
    return value.blocks.length > 0 || value.links.length > 0 || cleanText(value.fallback.join(""));
  }) ?? "global";
  const selected = buckets[selectedName];
  const seenText = new Set<string>();
  const blocks = selected.blocks.filter((block) => {
    if (seenText.has(block.text)) return false;
    seenText.add(block.text);
    return true;
  });
  if (!blocks.length) {
    const fallback = cleanText(selected.fallback.join(""));
    if (fallback) blocks.push({ kind: "paragraph", text: fallback.slice(0, 20_000) });
  }
  const links: ReadLink[] = [];
  const seenURLs = new Set<string>();
  for (const item of selected.links) {
    if (seenURLs.has(item.url)) continue;
    seenURLs.add(item.url);
    links.push(item);
  }
  const title = documentTitle || cleanText((titleParts ?? []).join("")) || titleFromURL(finalURL);
  const totalCharacters = blocks.reduce((sum, block) => sum + block.text.length, 0);
  return {
    title: title.slice(0, 512),
    blocks,
    links,
    requiresDynamic: !blocks.length || scriptCount > 0 && blocks.length <= 1 && totalCharacters < DYNAMIC_THRESHOLD,
    scanTruncated
  };
}

export function finalizeDocument(
  requestedURL: string,
  finalURL: string,
  title: string,
  blocks: ReadBlock[],
  links: ReadLink[],
  request: Pick<ReadRequest, "max_blocks" | "max_characters" | "max_links">,
  source: "static" | "browser",
  blockedSubresources = 0,
  inherentlyTruncated = false
): ReadResponse {
  const totalCharacters = blocks.reduce((sum, block) => sum + cleanText(block.text).length, 0);
  const outputBlocks: ReadBlock[] = [];
  let remaining = request.max_characters;
  let truncated = inherentlyTruncated;
  for (const block of blocks) {
    if (outputBlocks.length >= request.max_blocks || remaining <= 0) {
      truncated = true;
      break;
    }
    let text = cleanText(block.text);
    if (!text) continue;
    if (text.length > remaining) {
      text = text.slice(0, remaining).trim();
      if (text.length > 1) text = `${text.slice(0, -1)}…`;
      truncated = true;
    }
    outputBlocks.push({ kind: block.kind, text });
    remaining -= text.length;
  }
  const outputLinks = links.slice(0, request.max_links);
  if (links.length > outputLinks.length) truncated = true;
  return {
    url: requestedURL,
    final_url: finalURL,
    title: cleanText(title).slice(0, 512) || titleFromURL(finalURL),
    blocks: outputBlocks,
    links: outputLinks,
    truncated,
    links_truncated: links.length > outputLinks.length,
    character_count: outputBlocks.reduce((sum, block) => sum + block.text.length, 0),
    total_character_count: totalCharacters,
    source,
    blocked_subresources: blockedSubresources
  };
}

export async function readStatic(
  request: ReadRequest,
  fetcher: Fetcher = fetch,
  resolver?: DNSResolver
): Promise<StaticReadResult> {
  let currentURL = request.url;
  for (let redirects = 0; redirects <= MAXIMUM_REDIRECTS; redirects += 1) {
    const validated = await validateURL(currentURL, resolver);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 12_000);
    try {
      const response = await fetcher(validated.url, {
        method: "GET",
        redirect: "manual",
        signal: controller.signal,
        headers: {
          Accept: "text/html,application/xhtml+xml,text/plain;q=0.9",
          "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7",
          "User-Agent": READER_USER_AGENT
        }
      });

      if (REDIRECTS.has(response.status)) {
        const location = response.headers.get("location")?.trim();
        try { await response.body?.cancel("following validated redirect"); } catch { /* best effort */ }
        if (!location) {
          throw new ServiceError(
            "invalid_redirect",
            "The target returned a redirect without a location.",
            502,
            false
          );
        }
        if (redirects >= MAXIMUM_REDIRECTS) {
          throw new ServiceError(
            "too_many_redirects",
            "The target exceeded the redirect limit.",
            502,
            false
          );
        }
        currentURL = new URL(location, validated.url).toString();
        continue;
      }
      if (!response.ok) {
        try { await response.body?.cancel("upstream status rejected"); } catch { /* best effort */ }
        throw new ServiceError(
          "web_upstream_rejected",
          `The target website returned HTTP ${response.status}.`,
          502,
          [408, 425, 429].includes(response.status) || response.status >= 500
        );
      }
      const header = response.headers.get("content-type");
      let type = mediaType(header);
      if (type && !ALLOWED_TYPES.has(type)) {
        try { await response.body?.cancel("unsupported content type"); } catch { /* best effort */ }
        throw new ServiceError(
          "unsupported_content_type",
          "The target is not an HTML or plain-text document.",
          415,
          false
        );
      }
      // Keep the AbortController alive through streaming body consumption; a
      // server that sends headers and then stalls must still hit the 12s cap.
      const body = await boundedBytes(response);
      const bytes = body.bytes;
      if (!bytes.length) {
        throw new ServiceError("empty_page", "The target returned an empty document.", 502, false);
      }
      if (!type) {
        const prefix = new TextDecoder().decode(bytes.slice(0, 256)).trimStart().toLowerCase();
        type = prefix.startsWith("<!doctype html") || prefix.startsWith("<html") ? "text/html" : "text/plain";
      }
      const text = decodeBody(bytes, charset(header));
      if (type === "text/plain") {
        const blocks = text.split(/\n\s*\n/).map(cleanText).filter(Boolean)
          .map((value) => ({ kind: "paragraph" as const, text: value }));
        return {
          response: finalizeDocument(
            request.url,
            validated.url,
            titleFromURL(validated.url),
            blocks,
            [],
            request,
            "static",
            0,
            body.truncated
          ),
          requiresDynamic: false
        };
      }
      const extracted = extractHTML(text, validated.url);
      const output = finalizeDocument(
        request.url,
        validated.url,
        extracted.title,
        extracted.blocks,
        extracted.links,
        request,
        "static",
        0,
        extracted.scanTruncated || body.truncated
      );
      return { response: output, requiresDynamic: extracted.requiresDynamic };
    } catch (error) {
      if (error instanceof ServiceError) throw error;
      if (controller.signal.aborted) {
        throw new ServiceError(
          "web_fetch_timeout",
          "The target website did not respond in time.",
          504,
          true
        );
      }
      throw new ServiceError(
        "web_fetch_failed",
        "The target website could not be downloaded.",
        502,
        true
      );
    } finally {
      clearTimeout(timer);
    }
  }
  throw new ServiceError(
    "too_many_redirects",
    "The target exceeded the redirect limit.",
    502,
    false
  );
}
