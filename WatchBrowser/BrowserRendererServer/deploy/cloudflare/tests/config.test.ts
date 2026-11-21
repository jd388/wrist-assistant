import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const deploymentRoot = resolve(import.meta.dirname, "..");
const config = JSON.parse(
  readFileSync(resolve(deploymentRoot, "wrangler.jsonc"), "utf8")
) as Record<string, unknown>;
const serializedConfig = JSON.stringify(config);
const startScript = readFileSync(
  resolve(deploymentRoot, "container-start.sh"),
  "utf8"
);

describe("Wrangler deployment contract", () => {
  it("uses exactly one standard-1 container", () => {
    const containers = config.containers as Array<Record<string, unknown>>;
    expect(containers).toHaveLength(1);
    expect(containers[0]?.max_instances).toBe(1);
    expect(containers[0]?.instance_type).toBe("standard-1");
    expect(containers[0]?.image_build_context).toBe("../..");
  });

  it("commits the Chromium gate in its disabled state", () => {
    const vars = config.vars as Record<string, unknown>;
    expect(vars.WATCHBROWSER_CHROMIUM_EGRESS_ACK).toBe("disabled");
    expect(serializedConfig).not.toContain(
      "BROWSER_RENDERER_CHROMIUM_EGRESS_ISOLATED"
    );
  });

  it("does not place either application secret in Wrangler vars", () => {
    const vars = config.vars as Record<string, unknown>;
    expect(vars).not.toHaveProperty("BROWSER_RENDERER_TOKEN");
    expect(vars).not.toHaveProperty("BROWSER_RENDERER_AI_API_KEY");
    expect(vars).not.toHaveProperty("DEEPSEEK_API_KEY");
  });

  it("recomputes the Chromium flag in the container entrypoint", () => {
    expect(startScript).toContain(
      "export BROWSER_RENDERER_CHROMIUM_EGRESS_ISOLATED=true"
    );
    expect(startScript).toContain(
      "export BROWSER_RENDERER_CHROMIUM_EGRESS_ISOLATED=false"
    );
    expect(startScript).toContain("BROWSER_RENDERER_TOKEN is required");
  });
});
