import { describe, expect, it, vi } from "vitest";

import { ServiceError } from "../src/errors";
import {
  isPublicIPAddress,
  safeHTTPLink,
  validateURL,
  type DNSResolver
} from "../src/security";

const publicResolver: DNSResolver = async () => ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"];

describe("isPublicIPAddress", () => {
  it.each([
    "8.8.8.8",
    "1.1.1.1",
    "2606:4700:4700::1111",
    "2001:4860:4860::8888",
    "::ffff:8.8.8.8"
  ])("accepts public address %s", (address) => {
    expect(isPublicIPAddress(address)).toBe(true);
  });

  it.each([
    "0.0.0.0",
    "10.0.0.1",
    "100.64.0.1",
    "127.0.0.1",
    "169.254.169.254",
    "172.16.0.1",
    "192.168.1.1",
    "224.0.0.1",
    "::",
    "::1",
    "::ffff:127.0.0.1",
    "::ffff:168.63.129.16",
    "fc00::1",
    "fe80::1",
    "ff02::1",
    "2001:db8::1"
  ])("rejects private, local, metadata, or reserved address %s", (address) => {
    expect(isPublicIPAddress(address)).toBe(false);
  });
});

describe("validateURL", () => {
  it("normalizes and returns only a fully validated public HTTP(S) target", async () => {
    await expect(validateURL(" HTTPS://Example.COM./a?q=1 ", publicResolver)).resolves.toEqual({
      url: "https://example.com/a?q=1",
      host: "example.com",
      port: 443,
      addresses: ["2606:2800:220:1:248:1893:25c8:1946", "93.184.216.34"]
    });
  });

  it.each([
    "file:///etc/passwd",
    "ftp://example.com/file",
    "https://user:password@example.com/",
    "https://example.com:8443/",
    "http://localhost/",
    "http://service.internal/",
    "http://printer.local/",
    "http://metadata.google.internal/",
    "http://169.254.169.254/latest/meta-data/",
    "http://127.0.0.1/",
    "http://[::1]/",
    "http://2130706433/",
    "https://example.com/\u0000tail"
  ])("blocks unsafe URL %s", async (url) => {
    await expect(validateURL(url, publicResolver)).rejects.toMatchObject({
      code: "url_blocked",
      status: 400,
      retryable: false
    });
  });

  it("fails closed when any DNS answer is private", async () => {
    const rebindingResolver = vi.fn(async () => ["93.184.216.34", "127.0.0.1"]);
    await expect(validateURL("https://rebind.example/", rebindingResolver)).rejects.toMatchObject({
      code: "url_blocked"
    });
    expect(rebindingResolver).toHaveBeenCalledWith("rebind.example");
  });

  it("distinguishes transient DNS failure from an unsafe URL", async () => {
    const resolver = vi.fn(async () => { throw new Error("resolver down"); });
    await expect(validateURL("https://example.com/", resolver)).rejects.toMatchObject({
      code: "dns_resolution_failed",
      status: 502,
      retryable: true
    });
  });
});

describe("safeHTTPLink", () => {
  it("resolves relative web links while filtering active and credentialed schemes", () => {
    expect(safeHTTPLink("/article", "https://example.com/base")).toBe("https://example.com/article");
    expect(safeHTTPLink("javascript:alert(1)", "https://example.com/")).toBeNull();
    expect(safeHTTPLink("data:text/plain,hello")).toBeNull();
    expect(safeHTTPLink("https://user:pass@example.com/")).toBeNull();
  });

  it("never exposes parser exceptions to callers", () => {
    expect(safeHTTPLink("https://[:::]/")).toBeNull();
  });
});

it("ServiceError remains the SSRF contract type", async () => {
  try {
    await validateURL("http://127.0.0.1/", publicResolver);
  } catch (error) {
    expect(error).toBeInstanceOf(ServiceError);
  }
});
