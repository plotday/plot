import { Hono } from "hono";
import superjson from "superjson";

import type { Bindings } from "../env";
import { authRateLimiter } from "../middleware/rate-limit";
import { Integrations } from "../twist/tools/integrations";

const authBridgeRoutes = new Hono<{ Bindings: Bindings }>();

authBridgeRoutes.use("/auth/bridge", authRateLimiter);

// GET /auth/bridge - Browser-rendered OAuth callback for providers that
// require HTTPS redirect URIs. Completes the token exchange server-side,
// then returns HTML that deep-links back to the client's original custom
// scheme URI (plotday://auth/callback) with a visible fallback so the user
// can close the tab manually if the deep link doesn't fire.
//
// Mounted at the root of the API worker (outside the /app section) because
// OAuth providers redirect here with no user-auth context.
authBridgeRoutes.get("/auth/bridge", async (c) => {
  const query = c.req.query();
  const state = query.state;
  const error = query.error;

  // Peek authState to recover bridgeUri before HandleOauthCallback consumes it.
  let bridgeUri: string | null = null;
  if (state) {
    try {
      const storageObj = c.env.STORAGE.get(c.env.STORAGE.idFromName("auth"));
      const raw = await storageObj.get(state);
      if (raw) {
        const parsed = superjson.parse<{ bridgeUri?: string }>(raw);
        bridgeUri = parsed.bridgeUri ?? null;
      }
    } catch {
      // Non-fatal: the bridge will render a generic "close this tab" page.
    }
  }

  if (error) {
    return htmlBridgeResponse({ bridgeUri, state, error });
  }

  try {
    const result = await Integrations.HandleOauthCallback(
      c.env.STORAGE,
      c.env.CALLBACKS,
      query,
      c.env
    );
    // HandleOauthCallback returns JSON; a non-2xx status means the exchange
    // failed and we should render an error bridge page.
    if (!result.ok) {
      let message = "OAuth exchange failed";
      try {
        const body = (await result.clone().json()) as { error?: string };
        if (body.error) message = body.error;
      } catch {
        // Response wasn't JSON — fall back to the generic message.
      }
      return htmlBridgeResponse({ bridgeUri, state, error: message });
    }
    return htmlBridgeResponse({ bridgeUri, state });
  } catch (e) {
    return htmlBridgeResponse({
      bridgeUri,
      state,
      error: e instanceof Error ? e.message : "Authentication failed",
    });
  }
});

/** Render the bridge HTML response. Escapes all interpolated values. */
function htmlBridgeResponse({
  bridgeUri,
  state,
  error,
}: {
  bridgeUri: string | null;
  state: string | undefined;
  error?: string;
}): Response {
  const returnUrl = bridgeUri
    ? appendQuery(bridgeUri, {
        ...(state ? { state } : {}),
        ...(error ? { error } : { success: "1" }),
      })
    : null;

  const title = error ? "Authentication failed" : "Authentication complete";
  const message = error
    ? `Authentication failed: ${error}. You can close this window and try again in Plot.`
    : "Authentication complete. You can close this window and return to Plot.";

  const returnUrlJs = returnUrl ? JSON.stringify(returnUrl) : "null";
  const body = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${escapeHtml(title)}</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  body { font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
         padding: 2rem; text-align: center; color: #111; background: #fafafa; }
  p { max-width: 28rem; margin: 1rem auto; line-height: 1.5; }
</style>
</head>
<body>
<p>${escapeHtml(message)}</p>
<script>
  (function () {
    var url = ${returnUrlJs};
    if (url) { window.location.replace(url); }
  })();
</script>
</body>
</html>`;

  return new Response(body, {
    status: error ? 400 : 200,
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

function appendQuery(uri: string, extra: Record<string, string>): string {
  const entries = Object.entries(extra);
  if (entries.length === 0) return uri;
  const separator = uri.includes("?") ? "&" : "?";
  const query = entries
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");
  return `${uri}${separator}${query}`;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export default authBridgeRoutes;
