import { redirect } from "@remix-run/cloudflare";

import {
  type Database,
  safeQuery,
  saveCalendars,
  saveCredentials,
} from "@plotday/db";

import type { User } from "app/auth";
import {
  addAccount,
  completeSignIn,
  getUser,
  redeemInvitation,
} from "app/auth";
import { getCalendarConfig, getCalendars } from "app/cal";
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
  async ({
    request,
    env,
    sentry,
    tracker,
    supabase,
    supabaseAdmin,
    response,
  }) => {
    let user: User | null = null;
    // Supabase appends an extra query string
    const url = new URL(request.url.replace("&%3F", "&"));
    const fromUrl = url.searchParams.get("from") || "/sync";
    const toUrl = url.searchParams.get("to") || DEFAULT_PATH;
    let uid = url.searchParams.get("uid");
    let provider = toProvider(url.searchParams.get("provider"));

    try {
      user = await getUser(supabase, tracker, sentry, undefined, null);
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
        user = await getUser(supabaseAdmin, tracker, sentry, session, null);
        if (user) uid = user.id.toString();
      }

      let account: Database["public"]["Tables"]["account"]["Row"];
      ({ user, account } = await addAccount(
        user,
        session,
        tracker,
        supabaseAdmin
      ));
      const invitation = url.searchParams.get("invitation");
      if (invitation) {
        await redeemInvitation(user, invitation, tracker, supabaseAdmin);
      }

      if (
        account.email &&
        account.credentials &&
        typeof account.credentials === "object"
      ) {
        await env.CONTACT_SYNC_QUEUE?.send?.({
          accountId: account.id,
          full: true,
        });

        let calendars;
        let credentials = account.credentials as any;
        ({ calendars, credentials } = await getCalendars(
          getCalendarConfig(env),
          {
            provider: provider,
            email: account.email,
            access_token: credentials.access_token,
            refresh_token: credentials.refresh_token,
            scopes: credentials.scopes,
          }
        ));
        await saveCredentials(supabaseAdmin, user.id, credentials);
        const timezone = calendars[0]?.tz;
        const updateTimezone = !user.timezone && timezone;
        const activate = invitation && !user.activated_at;
        if (updateTimezone || activate) {
          safeQuery(
            await supabaseAdmin
              .from("user")
              .update({
                ...(updateTimezone ? { timezone } : {}),
                ...(activate ? { activated_at: new Date().toISOString() } : {}),
              })
              .eq("id", user.id)
          );
        }
        const dbCalendars = await saveCalendars(
          supabaseAdmin,
          account.id,
          calendars
        );
        if (dbCalendars) {
          for (const calendar of dbCalendars) {
            if (!calendar.enabled) continue;
            // Start a partial sync plus a full sync
            await env.SYNC_QUEUE?.send?.({
              calendarId: calendar.id,
              syncType: "partial",
            });
            await env.SYNC_QUEUE?.send?.({
              calendarId: calendar.id,
              syncType: "full",
            });
          }
        }
      }

      return redirect(toUrl, {
        headers: response.headers,
      });
    } catch (error) {
      // Might be a Remix response (like a redirect) rather than an error
      if (error instanceof Response) throw error;

      console.error(error);

      sentry.withScope?.((scope) => {
        scope.setExtra("user", user?.id ?? url.searchParams.get("email"));
        if (provider) {
          scope.setExtra("provider", provider);
        }
        sentry.captureException?.(error);
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
        tracker.accountAuthFailed(uid, {
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
