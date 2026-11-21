/**
 * The committed configuration is deliberately fail-closed. The exact
 * acknowledgement is only set after a deployed instance passes the egress
 * acceptance checks documented in README.md.
 */
export const CHROMIUM_EGRESS_ACKNOWLEDGEMENT =
  "cloudflare-public-http-egress-v1-verified";

/** One stable Container/Durable Object keeps the in-memory browser session alive. */
export const SINGLETON_CONTAINER_ID = "watchbrowser-renderer-singleton-v1";

/**
 * Cloudflare evaluates deniedHosts before allowedHosts. These entries mirror
 * and extend the FastAPI URLGuard boundary so a Chromium navigation cannot
 * reach local, private, metadata, documentation, benchmark, multicast, or
 * otherwise non-public destinations after DNS resolution.
 */
export const DENIED_EGRESS_TARGETS = Object.freeze([
  "localhost",
  "localhost.localdomain",
  "*.localhost",
  "*.local",
  "*.internal",
  "home.arpa",
  "*.home.arpa",
  "metadata",
  "*.metadata",
  "metadata.google.internal",
  "instance-data",

  "0.0.0.0/8",
  "10.0.0.0/8",
  "100.64.0.0/10",
  "100.100.100.200/32",
  "127.0.0.0/8",
  "168.63.129.16/32",
  "169.254.0.0/16",
  "172.16.0.0/12",
  "192.0.0.0/24",
  "192.0.2.0/24",
  "192.88.99.0/24",
  "192.168.0.0/16",
  "198.18.0.0/15",
  "198.51.100.0/24",
  "203.0.113.0/24",
  "224.0.0.0/4",
  "240.0.0.0/4",

  "::/128",
  "::1/128",
  "::ffff:0:0/96",
  "64:ff9b::/96",
  "64:ff9b:1::/48",
  "100::/64",
  "2001::/23",
  "2001:db8::/32",
  "2002::/16",
  "fc00::/7",
  "fd00:ec2::254/128",
  "fe80::/10",
  "ff00::/8"
] as const);

export function chromiumIsolationValue(
  acknowledgement: string | undefined
): "true" | "false" {
  return acknowledgement === CHROMIUM_EGRESS_ACKNOWLEDGEMENT
    ? "true"
    : "false";
}
