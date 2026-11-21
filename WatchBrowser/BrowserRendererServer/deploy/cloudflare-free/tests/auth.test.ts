import { describe, expect, it } from "vitest";

import { requireBearer } from "../src/auth";
import { ServiceError } from "../src/errors";

function captureError(run: () => void): ServiceError {
  try {
    run();
  } catch (error) {
    expect(error).toBeInstanceOf(ServiceError);
    return error as ServiceError;
  }
  throw new Error("Expected requireBearer to reject the request");
}

describe("requireBearer", () => {
  it("fails closed when the deployment secret is absent or blank", () => {
    for (const configured of [undefined, "", "   "]) {
      const request = new Request("https://renderer.test/health", {
        headers: { Authorization: "Bearer attacker-value" }
      });
      const error = captureError(() => requireBearer(request, configured));
      expect(error.code).toBe("server_not_configured");
      expect(error.status).toBe(503);
      expect(error.retryable).toBe(false);
    }
  });

  it("accepts only the exact configured bearer value", () => {
    const request = new Request("https://renderer.test/health", {
      headers: { Authorization: "bearer exact-secret" }
    });
    expect(() => requireBearer(request, "exact-secret")).not.toThrow();
  });

  it.each([
    ["missing header", undefined],
    ["wrong scheme", "Basic exact-secret"],
    ["empty bearer", "Bearer   "],
    ["prefix only", "Bearer exact"],
    ["suffix added", "Bearer exact-secret-more"],
    ["wrong case in value", "Bearer Exact-Secret"]
  ])("rejects %s", (_label, authorization) => {
    const headers = authorization ? { Authorization: authorization } : undefined;
    const error = captureError(() => requireBearer(
      new Request("https://renderer.test/health", { headers }),
      "exact-secret"
    ));
    expect(error.code).toBe("unauthorized");
    expect(error.status).toBe(401);
    expect(error.headers.get("WWW-Authenticate")).toBe("Bearer");
  });
});
