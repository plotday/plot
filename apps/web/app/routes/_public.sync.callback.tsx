import { redirect } from "@remix-run/cloudflare";

import type { Database } from "@plotday/db";

import type { User } from "app/auth";
import { activateAccount, addAccount, completeSignIn, getUser } from "app/auth";
import { DEFAULT_PATH } from "app/config";
import { restoreAuthCookie } from "app/cookies.server";
import { publicLoader } from "app/util";

function toProvider(
  provider: string | null
): Database["public"]["Enums"]["provider"] {
  switch (provider) {
    default:
    case "google":
      return "google";
    case "outlook":
      return "outlook";
  }
}

export const loader = publicLoader(
  async ({ request, env, supabase, supabaseAdmin, response }) => {
    let user: User | null = null;
    // Supabase appends an extra query string
    const url = new URL(request.url.replace("&%3F", "&"));
    const fromUrl = url.searchParams.get("from") || "/sync";
    const toUrl = url.searchParams.get("to") || DEFAULT_PATH;
    let uid = url.searchParams.get("uid");
    let provider = toProvider(url.searchParams.get("provider"));

    try {
      user = await getUser(supabase, env);
      if (user) uid = user.id.toString();

      // Restart with the previous user
      if (!user && restoreAuthCookie(request, response)) {
        return redirect(request.url, {
          headers: response.headers,
        });
      }

      // Load the user matching the auth user
      const session = await completeSignIn(request, supabase);
      if (!user) {
        user = await getUser(supabaseAdmin, env, session);
        if (user) uid = user.id.toString();
      }

      let account;
      ({ user, account } = await addAccount(user, session, env, supabaseAdmin));
      const invitation = url.searchParams.get("invitation");
      if (invitation) {
        await activateAccount(user, invitation, env, supabaseAdmin);
      }

      // Start a partial sync plus a full sync
      await env.SYNC_QUEUE?.send?.({
        accountId: account.id,
        syncType: "partial",
      });
      await env.SYNC_QUEUE?.send?.({
        accountId: account.id,
        syncType: "full",
      });
      await env.CONTACT_SYNC_QUEUE?.send?.({
        accountId: account.id,
      });

      return redirect(toUrl, {
        headers: response.headers,
      });
    } catch (error) {
      // Might be a Remix response (like a redirect) rather than an error
      if (error instanceof Response) throw error;

      console.error(error);

      env.sentry.withScope?.((scope) => {
        scope.setExtra("user", user?.id ?? url.searchParams.get("email"));
        if (provider) {
          scope.setExtra("provider", provider);
        }
        env.sentry.captureException?.(error);
      });

      let sync_error = "Server error";
      if (error instanceof Error && error.message) {
        sync_error = error.message;
      } else if (
        error instanceof Object &&
        "message" in error &&
        typeof error.message === "string" &&
        error.message
      ) {
        sync_error = error.message;
      }

      // Log error to Amplitude
      if (uid) {
        env.tracker.accountAuthFailed(uid, {
          Error: sync_error,
          ...(provider
            ? {
                Provider: provider,
              }
            : {}),
        });
      }

      const [fromPath, fromQuery] = fromUrl.split("?");
      const params = new URLSearchParams(fromQuery);
      params.append("error", sync_error);
      return redirect(`${fromPath}?${params.toString()}`);
    }
  }
);
