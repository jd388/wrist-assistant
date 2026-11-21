const FIXTURE_PATH = "/support/browser-fixture";

function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;"
  })[character] ?? character);
}

/**
 * A deterministic, zero-cost page used by the Watch/iPhone end-to-end probe.
 * It contains no script, fetches no subresources, and never reads credentials.
 */
export function browserFixture(requestURL: URL): Response {
  const query = (requestURL.searchParams.get("q") ?? "").slice(0, 80);
  const page = requestURL.searchParams.get("page") === "2" ? 2 : 1;
  const escapedQuery = escapeHTML(query);
  const title = query
    ? `WatchBrowser 查询 ${escapedQuery}`
    : `WatchBrowser 验收页 ${page}`;
  const nextPage = page === 1 ? 2 : 1;

  const html = `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
  <title>${title}</title>
  <style>
    :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; color: #10243e; background: #f5f8ff; }
    main { padding: 14px 16px 28px; }
    h1 { margin: 0 0 8px; font-size: 23px; line-height: 29px; }
    p { margin: 8px 0; line-height: 1.45; }
    form { display: grid; grid-template-columns: minmax(0, 1fr) 84px; gap: 8px; margin: 8px 0; }
    input, button, a { min-height: 44px; border-radius: 10px; font: inherit; }
    input { width: 100%; border: 1px solid #7993ba; padding: 0 12px; background: white; }
    button { border: 0; color: white; background: #1769e0; font-weight: 650; }
    a { display: flex; align-items: center; padding: 0 12px; color: #0757c7; background: #e4eeff; }
    .result { min-height: 24px; color: #136333; font-weight: 650; }
    .spacer { height: 920px; margin-top: 12px; border-radius: 14px; background: linear-gradient(#dbe8ff, #f8fbff); }
    footer { margin-top: 14px; font-weight: 650; }
  </style>
</head>
<body>
  <main>
    <h1>本地交互验收 · 第 ${page} 页</h1>
    <p class="result" id="result">${query ? `已提交：${escapedQuery}` : "等待输入"}</p>
    <form action="${FIXTURE_PATH}" method="get">
      <input id="query" name="q" aria-label="验收输入框" placeholder="输入测试文字" value="${escapedQuery}">
      <button id="submit" type="submit">提交</button>
    </form>
    <a id="page-link" href="${FIXTURE_PATH}?page=${nextPage}">前往第 ${nextPage} 页</a>
    <div class="spacer" aria-label="滚动测试区域"></div>
    <footer id="bottom">已到页面底部</footer>
  </main>
</body>
</html>`;

  return new Response(html, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
      "Permissions-Policy": "camera=(), microphone=(), geolocation=()"
    }
  });
}

export const __test = { FIXTURE_PATH, escapeHTML };
