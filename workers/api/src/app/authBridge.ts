import { Hono } from "hono";
import superjson from "superjson";

import type { Bindings } from "../env";
import { authRateLimiter } from "../middleware/rate-limit";
import { Integrations } from "../twist/tools/integrations";
import { completeSlackInstall } from "./slackInstall";

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

  // Peek authState to recover bridgeUri, provider, and detect the installOnly
  // admin flow before HandleOauthCallback consumes the state.
  let bridgeUri: string | null = null;
  let installOnly = false;
  let provider: string | null = null;
  if (state) {
    try {
      const storageObj = c.env.STORAGE.get(c.env.STORAGE.idFromName("auth"));
      const raw = await storageObj.get(state);
      if (raw) {
        const parsed = superjson.parse<{
          bridgeUri?: string;
          installOnly?: boolean;
          provider?: string;
        }>(raw);
        bridgeUri = parsed.bridgeUri ?? null;
        installOnly = parsed.installOnly === true;
        provider = parsed.provider ?? null;
      }
    } catch {
      // Non-fatal: the bridge will render a generic "close this tab" page.
    }
  }

  if (installOnly) {
    return handleSlackInstallCallback(c.env, state, query, error);
  }

  const handleError = (message: string): Response => {
    if (provider === "slack" && isSlackInstallGateError(message)) {
      return htmlSlackMemberErrorResponse({
        bridgeUri,
        error: message,
        siteUrl: c.env.SITE_ROOT,
      });
    }
    return htmlBridgeResponse({ bridgeUri, state, error: message });
  };

  if (error) {
    return handleError(error);
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
      return handleError(message);
    }
    return htmlBridgeResponse({ bridgeUri, state });
  } catch (e) {
    return handleError(
      e instanceof Error ? e.message : "Authentication failed",
    );
  }
});

// Slack returns these error codes when workspace install policy blocks the
// install, a requested scope isn't allowed, or the user cancels. All three are
// "ask an admin" territory from the member's perspective.
const SLACK_INSTALL_GATE_ERRORS = [
  "invalid_scope",
  "invalid scope",
  "invalid_permissions",
  "invalid permissions",
  "access_denied",
  "not_authed",
  "team_access_not_granted",
  "org_access_not_granted",
];

function isSlackInstallGateError(message: string): boolean {
  const lower = message.toLowerCase();
  return SLACK_INSTALL_GATE_ERRORS.some((e) => lower.includes(e));
}


async function handleSlackInstallCallback(
  env: Bindings,
  state: string | undefined,
  query: Record<string, string>,
  error: string | undefined,
): Promise<Response> {
  if (error || !state || !query.code) {
    return htmlSlackInstallResponse({
      error: error ?? "Missing code or state",
    });
  }
  try {
    const { teamName } = await completeSlackInstall({
      code: query.code,
      state,
      env,
    });
    return htmlSlackInstallResponse({ teamName, appRoot: env.APP_ROOT });
  } catch (e) {
    return htmlSlackInstallResponse({
      error: e instanceof Error ? e.message : "Install failed",
    });
  }
}

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

/** Render the admin-facing page shown after /slack/install completes. */
function htmlSlackInstallResponse({
  teamName,
  appRoot,
  error,
}: {
  teamName?: string | null;
  appRoot?: string;
  error?: string;
}): Response {
  const title = error
    ? "Slack install didn't complete"
    : `Plot Sync installed${teamName ? ` in ${teamName}` : ""}`;
  const message = error
    ? `We couldn't complete the Slack install (${error}). You can close this window and try again from plot.day/slack.`
    : `Plot Sync is now available in${teamName ? ` ${teamName}` : " your workspace"}. Members can connect their own Slack accounts from Plot.`;
  const appLink = appRoot || "https://app.plot.day";

  const body = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${escapeHtml(title)}</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  body { font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
         padding: 2rem; text-align: center; color: #111; background: #fafafa; }
  h1 { font-size: 1.25rem; margin: 1rem auto; }
  p { max-width: 32rem; margin: 1rem auto; line-height: 1.5; color: #333; }
  a.cta { display: inline-block; margin-top: 1rem; padding: 0.6rem 1.1rem;
          background: #111; color: #fff; border-radius: 6px;
          text-decoration: none; font-weight: 500; }
</style>
</head>
<body>
<h1>${escapeHtml(title)}</h1>
<p>${escapeHtml(message)}</p>
${error ? "" : `<p><a class="cta" href="${escapeHtml(appLink)}">Open Plot</a></p>`}
</body>
</html>`;

  return new Response(body, {
    status: error ? 400 : 200,
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

/**
 * Render the member-facing error page when a Slack connect attempt fails at
 * the workspace install gate. Primary CTA is sharing the plot.day/slack link
 * with an admin (copy-message button); secondary is a manual "return to Plot"
 * deep link. Unlike htmlBridgeResponse, this page does NOT auto-redirect —
 * the user needs to read it and copy the message first.
 */
function htmlSlackMemberErrorResponse({
  bridgeUri,
  error,
  siteUrl,
}: {
  bridgeUri: string | null;
  error: string;
  siteUrl: string;
}): Response {
  const adminInstallUrl = `${siteUrl}/slack`;
  const adminMessage =
    `Hi — I'd like to connect Slack to Plot (plot.day), but our workspace requires admin approval to install apps. ` +
    `Could you install Plot Sync for our workspace? It's a one-time step that only requests team:read (workspace name/icon) and grants no access to messages, channels, or DMs. ` +
    `Once installed, each team member connects their own Slack individually inside Plot.\n\n` +
    `Install here: ${adminInstallUrl}`;

  const returnUrl = bridgeUri
    ? appendQuery(bridgeUri, { error })
    : null;

  const body = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Couldn't connect Slack</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  body { font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
         padding: 2rem; color: #111; background: #fafafa;
         display: flex; justify-content: center; }
  .card { max-width: 34rem; width: 100%; background: #fff; padding: 2rem;
          border-radius: 10px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
  h1 { font-size: 1.35rem; margin: 0 0 0.75rem; }
  p { line-height: 1.55; color: #333; margin: 0.6rem 0; }
  ul { line-height: 1.55; color: #333; padding-left: 1.2rem; }
  .detail { color: #6b7280; font-size: 0.85rem; margin-top: 0.25rem; }
  .actions { margin-top: 1.5rem; display: flex; flex-wrap: wrap; gap: 0.6rem; }
  button, a.btn { font: inherit; padding: 0.55rem 1rem; border-radius: 6px;
                  cursor: pointer; text-decoration: none; border: 1px solid #111;
                  background: #111; color: #fff; font-weight: 500; }
  button.secondary, a.btn.secondary { background: #fff; color: #111; }
  button:disabled { opacity: 0.7; cursor: default; }
  code { background: #f1f1f1; padding: 0.1rem 0.35rem; border-radius: 3px;
         font-size: 0.9em; }
</style>
</head>
<body>
<div class="card">
  <h1>Couldn't connect Slack</h1>
  <p>
    Slack rejected the install request. This usually means one of:
  </p>
  <ul>
    <li>Your workspace restricts app installs to admins or App Managers.</li>
    <li>You're a guest in this workspace (guests can't install apps).</li>
    <li>The workspace is on Slack's Free plan and has hit the 10-app limit.</li>
  </ul>
  <p>
    Ask a workspace admin to install Plot Sync for your team at
    <a href="${escapeHtml(adminInstallUrl)}">${escapeHtml(adminInstallUrl)}</a>.
    After they install it, you can come back and connect your own Slack account.
  </p>
  <p class="detail">Slack error: <code>${escapeHtml(error)}</code></p>
  <div class="actions">
    <button id="copyBtn" type="button">Copy message for admin</button>
    ${returnUrl ? `<a class="btn secondary" href="${escapeHtml(returnUrl)}">Return to Plot</a>` : ""}
  </div>
</div>
<script>
  (function () {
    var btn = document.getElementById("copyBtn");
    var message = ${JSON.stringify(adminMessage)};
    btn.addEventListener("click", function () {
      navigator.clipboard.writeText(message).then(function () {
        var original = btn.textContent;
        btn.textContent = "Copied";
        btn.disabled = true;
        setTimeout(function () {
          btn.textContent = original;
          btn.disabled = false;
        }, 2000);
      }).catch(function () {
        btn.textContent = "Copy failed";
      });
    });
  })();
</script>
</body>
</html>`;

  return new Response(body, {
    status: 400,
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
