import { env } from "cloudflare:workers";
import {
  Container,
  ContainerProxy,
  getContainer
} from "@cloudflare/containers";

import {
  chromiumIsolationValue,
  DENIED_EGRESS_TARGETS,
  SINGLETON_CONTAINER_ID
} from "./policy";

export { ContainerProxy };

interface WatchBrowserEnvironment {
  RENDERER: DurableObjectNamespace<WatchBrowserContainer>;
  BROWSER_RENDERER_TOKEN: string;
  BROWSER_RENDERER_AI_API_KEY?: string;
  BROWSER_RENDERER_AI_BASE_URL: string;
  BROWSER_RENDERER_AI_MODEL: string;
  WATCHBROWSER_CHROMIUM_EGRESS_ACK: string;
}

declare global {
  namespace Cloudflare {
    interface Env extends WatchBrowserEnvironment {}
  }
}

/**
 * A single stateful instance serves one Watch installation. The platform
 * blocks every non-HTTP(S) outbound connection and evaluates deniedHosts
 * before the catch-all public web allowance. TLS stays end-to-end: this
 * policy intentionally does not enable HTTPS interception.
 */
export class WatchBrowserContainer extends Container<WatchBrowserEnvironment> {
  override defaultPort = 8000;
  override requiredPorts = [8000];
  override sleepAfter = "15m";

  override enableInternet = false;
  override allowedHosts = ["*"];
  override deniedHosts = [...DENIED_EGRESS_TARGETS];

  override envVars = {
    BROWSER_RENDERER_TOKEN: env.BROWSER_RENDERER_TOKEN,
    BROWSER_RENDERER_AI_API_KEY: env.BROWSER_RENDERER_AI_API_KEY ?? "",
    BROWSER_RENDERER_AI_BASE_URL: env.BROWSER_RENDERER_AI_BASE_URL,
    BROWSER_RENDERER_AI_MODEL: env.BROWSER_RENDERER_AI_MODEL,
    WATCHBROWSER_CHROMIUM_EGRESS_ACK:
      env.WATCHBROWSER_CHROMIUM_EGRESS_ACK,
    BROWSER_RENDERER_CHROMIUM_EGRESS_ISOLATED: chromiumIsolationValue(
      env.WATCHBROWSER_CHROMIUM_EGRESS_ACK
    )
  };
}

export default {
  async fetch(
    request: Request,
    workerEnv: WatchBrowserEnvironment
  ): Promise<Response> {
    const container = getContainer(
      workerEnv.RENDERER,
      SINGLETON_CONTAINER_ID
    );
    const response = await container.fetch(request);
    const headers = new Headers(response.headers);
    headers.set("Cache-Control", "no-store");
    headers.set("X-Content-Type-Options", "nosniff");
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers
    });
  }
} satisfies ExportedHandler<WatchBrowserEnvironment>;
