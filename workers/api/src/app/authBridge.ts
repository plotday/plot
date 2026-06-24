import { Hono } from "hono";
import superjson from "superjson";

import type { Bindings } from "../env";
import { authRateLimiter } from "../middleware/rate-limit";
import { Integrations } from "../twist/tools/integrations";
import { completeSlackInstall } from "./slackInstall";
import { invokeWebhookCallback } from "../twist/invoke-webhook";
import { disposeRpc } from "../utils/rpc";
import { createLogger } from "@plotday/worker-util";
import { UnipileClient } from "../twist/tools/unipile/client";
import type { HostedAccountProviderData } from "../provider";
import { createDb } from "../db";
import { PROVIDER_CONFIGS } from "../provider";
import { sweepOrphanAccountsForIdentity } from "../twist/tools/unipile/account-cleanup";

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
      query,
      c.env,
      c.executionCtx as unknown as { exports: ExecutionContext["exports"] }
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

// GET /auth/hosted/success - Unipile hosted-auth success redirect.
// Unipile redirects the WebView here after the user completes hosted auth.
// We poll for the `hosted_auth_result:${state}` written by the /hook/messaging
// webhook handler, invoke the connector's onAuth callback, then return HTML
// that deep-links back to the client's original redirectUri.
authBridgeRoutes.get("/auth/hosted/success", async (c) => {
  const logger = createLogger({ route: "auth/hosted/success" });
  const query = c.req.query();

  // Log every query parameter Unipile sends so payload shape is visible
  // without redeploying. account_id is the field we care about most.
  logger.info("hosted/success: query received", {
    keys: Object.keys(query),
    state: query.state ?? null,
    account_id: query.account_id ?? query.accountId ?? null,
    status: query.status ?? null,
  });

  const state = query.state;
  if (!state) {
    logger.warn("hosted/success: missing state");
    return htmlBridgeResponse({ bridgeUri: null, state: undefined, error: "Missing state" });
  }

  const storageObj = c.env.STORAGE.get(c.env.STORAGE.idFromName("auth"));

  // Retrieve the in-flight auth state written by GenerateHostedAuthUrl.
  let bridgeUri: string | null = null;
  let callbackToken: string | null = null;
  let provider: string | null = null;
  try {
    const raw = await storageObj.get(`hosted_auth:${state}`);
    if (raw) {
      const parsed = superjson.parse<{
        provider: string;
        callback: string | null;
        redirectUri: string;
        createdAt: number;
      }>(raw);
      bridgeUri = parsed.redirectUri ?? null;
      callbackToken = parsed.callback ?? null;
      provider = parsed.provider ?? null;
    }
  } catch (e) {
    logger.warn("hosted/success: failed to parse hosted_auth state", {
      error: e instanceof Error ? e.message : String(e),
    });
  }

  if (!callbackToken || !provider) {
    logger.warn("hosted/success: missing callback or provider in stored state", { state });
    return htmlBridgeResponse({
      bridgeUri,
      state,
      error: "Auth session not found or expired. Please try again.",
    });
  }

  // Fast path: Unipile appends account_id to the redirect URL. Use it
  // directly without waiting on a webhook. The notify_url callback isn't
  // reliably delivered (and arrives in a different payload shape when it
  // is), so the redirect's query is the canonical signal here.
  const queryAccountId =
    (query.account_id as string | undefined) ??
    (query.accountId as string | undefined) ??
    null;

  let resultJson: string | null = null;
  if (queryAccountId) {
    resultJson = JSON.stringify({
      accountId: queryAccountId,
      accountType:
        (query.account_type as string | undefined) ??
        (query.provider as string | undefined) ??
        "LINKEDIN",
      receivedAt: Date.now(),
    });
  } else {
    // Fallback: poll for a webhook-delivered result for a few seconds.
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline) {
      resultJson = await storageObj.get(`hosted_auth_result:${state}`);
      if (resultJson) break;
      await new Promise((r) => setTimeout(r, 250));
    }
  }
  if (!resultJson) {
    logger.warn("hosted/success: no account_id in query and webhook result not received", {
      state,
      query_keys: Object.keys(query),
    });
    return htmlBridgeResponse({
      bridgeUri,
      state,
      error: "Connection timed out. Please try again.",
    });
  }

  const result = JSON.parse(resultJson) as {
    accountId: string;
    accountType: string | null;
    receivedAt: number;
  };

  // Fetch the connected user's PROVIDER-SIDE profile (LinkedIn member name,
  // email, URN) — not the Unipile account label, which is just "Personal" or
  // similar. The connector's onAuth uses `providerData.fullName` to label the
  // connection in the integrations modal, so we want the real name.
  let fullName: string | null = null;
  let email: string | null = null;
  let userId: string = result.accountId;
  try {
    const client = new UnipileClient(c.env);
    const profile = await client.getOwnProfile({ accountId: result.accountId });
    fullName = profile.display_name && profile.display_name.trim() ? profile.display_name : null;
    // v2 returns the member's email under the top-level `emails` array (LinkedIn,
    // etc.), not `specifics.email`. The email is what lets onAuth's buildActor
    // resolve the connecting user's existing contact — without it the token is
    // stored under a fresh contact that the channel's enabledBy never matches,
    // and every sync fails with "has no stored credentials — reconnect".
    email = profile.specifics?.email ?? profile.emails?.[0] ?? null;
    userId = profile.id ?? result.accountId;
  } catch (e) {
    // Non-fatal: fall back to whatever the account record says. The label can
    // be updated by the connector's later getAccountName() override.
    logger.warn("hosted/success: getOwnProfile failed", {
      error: e instanceof Error ? e.message : String(e),
      account_id: result.accountId,
    });
    try {
      const client = new UnipileClient(c.env);
      const account = await client.getAccount(result.accountId);
      fullName = account.name ?? null;
      userId = account.user_id ?? result.accountId;
    } catch {
      // Both calls failed — accept the placeholder.
    }
  }

  const providerData: HostedAccountProviderData = {
    accountId: result.accountId,
    accountType: result.accountType,
    userId,
    fullName,
    email,
  };

  // Build a StoredTokenData-shaped object. The connector's onAuth receives
  // this as its tokenInfo argument, exactly as the LinkedIn cookie handler does.
  const tokenInfo = {
    access_token: result.accountId,
    refresh_token: null as string | null,
    expires_at: null as number | null,
    scopes: [] as string[],
    client_id: "hosted",
    providerData,
    provider,
  };

  // Invoke the connector's onAuth callback — the same path used by every
  // OAuth provider and the LinkedIn cookie handler.
  try {
    const cbResult = await invokeWebhookCallback(
      c.env,
      c.executionCtx as unknown as { exports: ExecutionContext["exports"] },
      callbackToken,
      tokenInfo
    );
    disposeRpc(cbResult);
    logger.info("hosted/success: onAuth completed", {
      state,
      account_id: result.accountId,
    });
  } catch (error) {
    logger.error(
      "hosted/success: onAuth invocation failed",
      error as Error,
      { state, account_id: result.accountId }
    );
    try {
      c.var.tracker?.captureException(error as Error, {
        state,
        account_id: result.accountId,
        route: "auth/hosted/success",
      });
    } catch {
      // Tracker not available — already logged above.
    }
    // Clean up state even on error so stale keys don't accumulate.
    await Promise.all([
      storageObj.clear(`hosted_auth:${state}`),
      storageObj.clear(`hosted_auth_result:${state}`),
    ]);
    return htmlBridgeResponse({
      bridgeUri,
      state,
      error: "Sign-in failed. Please try again.",
    });
  }

  // Clean up state keys.
  await Promise.all([
    storageObj.clear(`hosted_auth:${state}`),
    storageObj.clear(`hosted_auth_result:${state}`),
  ]);

  // Best-effort: a fresh connect for a LinkedIn identity means any OTHER
  // Unipile account for that same identity is a stale orphan (older connects,
  // or accounts stranded by a dev DB reset). Sweep them in the background so
  // the redirect isn't delayed. `userId` is the LinkedIn member id
  // (profile.provider_id) resolved above.
  if (
    provider &&
    PROVIDER_CONFIGS[provider as keyof typeof PROVIDER_CONFIGS]?.authMode ===
      "hosted"
  ) {
    const newAccountId = result.accountId;
    const identityId = userId;
    const env = c.env;
    const tracker = c.var.tracker;
    c.executionCtx.waitUntil(
      (async () => {
        const db = createDb(env);
        try {
          await sweepOrphanAccountsForIdentity(
            env,
            db,
            { newAccountId, identityId },
            { tracker }
          );
        } finally {
          await db.destroy();
        }
      })()
    );
  }

  return htmlBridgeResponse({ bridgeUri, state });
});

// GET /auth/hosted/failure - Unipile hosted-auth failure redirect.
// Renders a failure page and deep-links back to the client's redirectUri.
authBridgeRoutes.get("/auth/hosted/failure", async (c) => {
  const logger = createLogger({ route: "auth/hosted/failure" });
  const state = c.req.query("state");

  // Best-effort: recover bridgeUri so we can deep-link back to the app.
  let bridgeUri: string | null = null;
  if (state) {
    try {
      const storageObj = c.env.STORAGE.get(c.env.STORAGE.idFromName("auth"));
      const raw = await storageObj.get(`hosted_auth:${state}`);
      if (raw) {
        const parsed = superjson.parse<{ redirectUri?: string }>(raw);
        bridgeUri = parsed.redirectUri ?? null;
      }
      // Clean up — the user will need to restart the flow.
      await storageObj.clear(`hosted_auth:${state}`);
    } catch (e) {
      logger.warn("hosted/failure: error reading stored state", {
        error: e instanceof Error ? e.message : String(e),
      });
    }
  }

  logger.info("hosted/failure: auth did not complete", { state });
  return htmlBridgeResponse({
    bridgeUri,
    state,
    error: "LinkedIn sign-in was not completed. Please try again.",
  });
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
