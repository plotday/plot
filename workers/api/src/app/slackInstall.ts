import { Hono } from "hono";
import superjson from "superjson";

import type { Bindings } from "../env";
import { authRateLimiter } from "../middleware/rate-limit";

const slackInstallRoutes = new Hono<{ Bindings: Bindings }>();

slackInstallRoutes.use("/slack/install", authRateLimiter);

// GET /slack/install — public entry point for plot.day/slack.
//
// Redirects a Slack workspace admin into Slack's OAuth flow requesting only
// `user_scope=team:read`. The admin's consent screen therefore shows a single
// innocuous read-only permission; completing it registers Plot Sync with the
// workspace (unlocking the install gate for subsequent member connects) and
// the admin's resulting user token is revoked on our end — see
// `/auth/bridge` installOnly branch.
slackInstallRoutes.get("/slack/install", async (c) => {
  const clientId = c.env.AUTH_SLACK_ID;
  if (!clientId) {
    return c.text("Slack client ID not configured", 500);
  }

  const state = crypto.randomUUID();
  const redirectUri = `${c.env.API_ROOT}/auth/bridge`;

  const storageObj = c.env.STORAGE.get(c.env.STORAGE.idFromName("auth"));
  await storageObj.set(
    state,
    superjson.stringify({
      provider: "slack" as const,
      scopes: ["team:read"],
      timestamp: Date.now(),
      clientId,
      redirectUri,
      installOnly: true,
    }),
  );

  const params = new URLSearchParams({
    response_type: "code",
    client_id: clientId,
    redirect_uri: redirectUri,
    user_scope: "team:read",
    state,
  });
  return c.redirect(`https://slack.com/oauth/v2/authorize?${params.toString()}`);
});

export default slackInstallRoutes;

// Completes the Slack install-only flow: exchanges the code for a user token
// (which completes the workspace install), best-effort revokes the token, and
// returns the workspace name for the admin-facing success page. Throws on any
// non-recoverable failure.
export async function completeSlackInstall({
  code,
  state,
  env,
}: {
  code: string;
  state: string;
  env: Bindings;
}): Promise<{ teamName: string | null }> {
  const storageObj = env.STORAGE.get(env.STORAGE.idFromName("auth"));
  // State was consumed by /auth/bridge's peek earlier only if it parsed it;
  // re-reading here is defensive. The installOnly branch in the bridge passes
  // the already-parsed state so this function doesn't need to re-read, but we
  // still clean up here.
  await storageObj.clear(state);

  const clientSecret = env.AUTH_SLACK_SECRET;
  if (!clientSecret) {
    throw new Error("Slack client secret not configured");
  }

  const params = new URLSearchParams({
    client_id: env.AUTH_SLACK_ID,
    client_secret: clientSecret,
    code,
    redirect_uri: `${env.API_ROOT}/auth/bridge`,
    grant_type: "authorization_code",
  });

  const response = await fetch("https://slack.com/api/oauth.v2.access", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });

  if (!response.ok) {
    throw new Error(`Slack token exchange failed: ${response.status}`);
  }

  const body = (await response.json()) as {
    ok: boolean;
    error?: string;
    team?: { id?: string; name?: string };
    authed_user?: { id?: string; access_token?: string };
  };

  if (!body.ok) {
    throw new Error(body.error || "Slack returned ok=false");
  }

  // Revoke the admin's user token — the install is complete on Slack's side
  // regardless of whether the token is retained, and we want zero footprint.
  const userToken = body.authed_user?.access_token;
  if (userToken) {
    try {
      await fetch("https://slack.com/api/auth.revoke", {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          Authorization: `Bearer ${userToken}`,
        },
        body: "",
      });
    } catch {
      // Non-fatal: Slack's install is recorded even if revoke fails.
    }
  }

  return { teamName: body.team?.name ?? null };
}
