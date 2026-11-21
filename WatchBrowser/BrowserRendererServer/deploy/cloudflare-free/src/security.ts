import { resolve4, resolve6 } from "node:dns/promises";

import { ServiceError } from "./errors";

export interface ValidatedURL {
  url: string;
  host: string;
  port: number;
  addresses: string[];
}

export type DNSResolver = (host: string) => Promise<string[]>;

const BLOCKED_NAMES = new Set([
  "localhost",
  "localhost.localdomain",
  "metadata",
  "metadata.google.internal",
  "instance-data"
]);

const EXPLICIT_METADATA_V4 = new Set([
  "100.100.100.200",
  "168.63.129.16",
  "169.254.169.254"
]);

const IPV4_BLOCKS: ReadonlyArray<readonly [number, number]> = [
  [0x00000000, 8],
  [0x0a000000, 8],
  [0x64400000, 10],
  [0x7f000000, 8],
  [0xa9fe0000, 16],
  [0xac100000, 12],
  [0xc0000000, 24],
  [0xc0000200, 24],
  [0xc0586300, 24],
  [0xc0a80000, 16],
  [0xc6120000, 15],
  [0xc6336400, 24],
  [0xcb007100, 24],
  [0xe0000000, 4],
  [0xf0000000, 4]
];

const IPV6_BLOCKS: ReadonlyArray<readonly [bigint, number]> = [
  [0n, 128],
  [1n, 128],
  [0n, 96],
  [0x64ff9b00010000000000000000000000n, 48],
  [0x01000000000000000000000000000000n, 64],
  [0x20010000000000000000000000000000n, 23],
  [0x20010db8000000000000000000000000n, 32],
  [0x3fff0000000000000000000000000000n, 20],
  [0x5f000000000000000000000000000000n, 16],
  [0xfc000000000000000000000000000000n, 7],
  [0xfe800000000000000000000000000000n, 10],
  [0xff000000000000000000000000000000n, 8]
];

function blocked(message: string): ServiceError {
  return new ServiceError("url_blocked", message, 400, false);
}

function inIPv4CIDR(value: number, base: number, prefix: number): boolean {
  const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
  return (value & mask) >>> 0 === (base & mask) >>> 0;
}

function inIPv6CIDR(value: bigint, base: bigint, prefix: number): boolean {
  if (prefix === 0) return true;
  const shift = BigInt(128 - prefix);
  return value >> shift === base >> shift;
}

function parseIPv4(input: string): number | null {
  const parts = input.split(".");
  if (parts.length !== 4) return null;
  let value = 0;
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const byte = Number(part);
    if (byte > 255) return null;
    value = value * 256 + byte;
  }
  return value >>> 0;
}

function parseIPv6(input: string): bigint | null {
  let candidate = input.toLowerCase();
  if (candidate.startsWith("[") && candidate.endsWith("]")) {
    candidate = candidate.slice(1, -1);
  }
  if (!candidate || candidate.includes("%")) return null;
  if (candidate.includes(".")) {
    const lastColon = candidate.lastIndexOf(":");
    if (lastColon < 0) return null;
    const v4 = parseIPv4(candidate.slice(lastColon + 1));
    if (v4 === null) return null;
    candidate = `${candidate.slice(0, lastColon)}:${((v4 >>> 16) & 0xffff).toString(16)}:${(v4 & 0xffff).toString(16)}`;
  }
  const halves = candidate.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  if (halves.length === 1 && head.length !== 8) return null;
  if (halves.length === 2 && head.length + tail.length >= 8) return null;
  const fill = halves.length === 2 ? Array(8 - head.length - tail.length).fill("0") : [];
  const pieces = [...head, ...fill, ...tail];
  if (pieces.length !== 8 || pieces.some((part) => !/^[0-9a-f]{1,4}$/.test(part))) {
    return null;
  }
  return pieces.reduce((value, part) => value << 16n | BigInt(`0x${part}`), 0n);
}

export function isPublicIPAddress(input: string): boolean {
  const normalized = input.replace(/^\[|\]$/g, "").toLowerCase();
  const ipv4 = parseIPv4(normalized);
  if (ipv4 !== null) {
    if (EXPLICIT_METADATA_V4.has(normalized)) return false;
    return !IPV4_BLOCKS.some(([base, prefix]) => inIPv4CIDR(ipv4, base, prefix));
  }
  const ipv6 = parseIPv6(normalized);
  if (ipv6 === null) return false;
  const mappedPrefix = 0xffffn;
  if (ipv6 >> 32n === mappedPrefix) {
    const mapped = Number(ipv6 & 0xffffffffn) >>> 0;
    const mappedText = [24, 16, 8, 0]
      .map((shift) => String(mapped >>> shift & 0xff))
      .join(".");
    if (EXPLICIT_METADATA_V4.has(mappedText)) return false;
    return !IPV4_BLOCKS.some(([base, prefix]) => inIPv4CIDR(mapped, base, prefix));
  }
  if (!inIPv6CIDR(ipv6, 0x20000000000000000000000000000000n, 3)) return false;
  return !IPV6_BLOCKS.some(([base, prefix]) => inIPv6CIDR(ipv6, base, prefix));
}

function isBlockedName(host: string): boolean {
  return BLOCKED_NAMES.has(host)
    || host.endsWith(".localhost")
    || host.endsWith(".local")
    || host.endsWith(".internal")
    || host.endsWith(".home.arpa");
}

async function systemResolver(host: string): Promise<string[]> {
  const answers = await Promise.allSettled([resolve4(host), resolve6(host)]);
  const addresses: string[] = [];
  for (const answer of answers) {
    if (answer.status === "fulfilled") addresses.push(...answer.value);
  }
  return [...new Set(addresses)];
}

export async function validateURL(
  rawURL: string,
  resolver: DNSResolver = systemResolver
): Promise<ValidatedURL> {
  if (!rawURL.trim() || [...rawURL].some((character) => {
    const code = character.charCodeAt(0);
    return code < 32 || code === 127;
  })) {
    throw blocked("The URL is empty or contains forbidden control characters.");
  }
  let parsed: URL;
  try {
    parsed = new URL(rawURL.trim());
  } catch {
    throw blocked("The URL is malformed.");
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw blocked("Only http and https URLs are allowed.");
  }
  if (parsed.username || parsed.password) {
    throw blocked("URLs containing user credentials are not allowed.");
  }
  let host = parsed.hostname.replace(/^\[|\]$/g, "").replace(/\.$/, "").toLowerCase();
  if (!host || isBlockedName(host)) {
    throw blocked("Local and metadata host names are not allowed.");
  }
  const port = parsed.port ? Number(parsed.port) : parsed.protocol === "https:" ? 443 : 80;
  if (!Number.isInteger(port) || ![80, 443].includes(port)) {
    throw blocked("Only public HTTP and HTTPS ports are allowed.");
  }

  const literalV4 = parseIPv4(host);
  const literalV6 = parseIPv6(host);
  let addresses: string[];
  if (literalV4 !== null || literalV6 !== null) {
    if (!isPublicIPAddress(host)) {
      throw blocked("The URL resolves to a local, private, reserved, or metadata address.");
    }
    addresses = [host];
  } else {
    if (host.length > 253 || !host.split(".").every((label) => (
      label.length > 0
      && label.length <= 63
      && !label.startsWith("-")
      && !label.endsWith("-")
      && /^[a-z0-9-]+$/.test(label)
    ))) {
      throw blocked("The URL contains an invalid host name.");
    }
    try {
      addresses = await resolver(host);
    } catch {
      throw new ServiceError(
        "dns_resolution_failed",
        "The host name could not be resolved.",
        502,
        true
      );
    }
    if (!addresses.length) {
      throw new ServiceError(
        "dns_resolution_failed",
        "The host name did not resolve to an address.",
        502,
        true
      );
    }
    if (addresses.some((address) => !isPublicIPAddress(address))) {
      throw blocked("The URL resolves to a local, private, reserved, or metadata address.");
    }
  }
  parsed.hostname = host.includes(":") ? `[${host}]` : host;
  return { url: parsed.toString(), host, port, addresses: [...new Set(addresses)].sort() };
}

export function safeHTTPLink(rawURL: string, base?: string): string | null {
  try {
    const parsed = base ? new URL(rawURL, base) : new URL(rawURL);
    if (
      !["http:", "https:"].includes(parsed.protocol)
      || parsed.username
      || parsed.password
      || parsed.href.length > 4096
    ) return null;
    return parsed.href;
  } catch {
    return null;
  }
}
