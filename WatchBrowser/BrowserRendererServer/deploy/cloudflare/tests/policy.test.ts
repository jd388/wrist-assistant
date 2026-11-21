import { describe, expect, it } from "vitest";

import {
  CHROMIUM_EGRESS_ACKNOWLEDGEMENT,
  chromiumIsolationValue,
  DENIED_EGRESS_TARGETS,
  SINGLETON_CONTAINER_ID
} from "../src/policy";

describe("Chromium egress acknowledgement", () => {
  it("fails closed for missing, empty, and near-match values", () => {
    expect(chromiumIsolationValue(undefined)).toBe("false");
    expect(chromiumIsolationValue("")).toBe("false");
    expect(chromiumIsolationValue("disabled")).toBe("false");
    expect(
      chromiumIsolationValue(`${CHROMIUM_EGRESS_ACKNOWLEDGEMENT} `)
    ).toBe("false");
  });

  it("enables only the exact reviewed policy acknowledgement", () => {
    expect(chromiumIsolationValue(CHROMIUM_EGRESS_ACKNOWLEDGEMENT)).toBe(
      "true"
    );
  });
});

describe("deployment policy", () => {
  it("uses a stable non-empty singleton id", () => {
    expect(SINGLETON_CONTAINER_ID).toMatch(/^watchbrowser-.+-v\d+$/);
  });

  it.each([
    "localhost",
    "*.local",
    "metadata.google.internal",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "224.0.0.0/4",
    "240.0.0.0/4",
    "::1/128",
    "fc00::/7",
    "fe80::/10",
    "ff00::/8",
    "fd00:ec2::254/128"
  ])("denies mandatory non-public target %s", target => {
    expect(DENIED_EGRESS_TARGETS).toContain(target);
  });

  it("contains no public catch-all in the deny list", () => {
    expect(DENIED_EGRESS_TARGETS).not.toContain("0.0.0.0/0");
    expect(DENIED_EGRESS_TARGETS).not.toContain("::/0");
  });
});
