import type { LoaderArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";

import type { Database } from "@plotday/db";

import { completeSignIn, getUser, getUserMetadata } from "app/auth";
import { DEFAULT_PATH } from "app/config";
import { restoreAuthCookie } from "app/cookies.server";
import { createServerAdminClient, createServerClient, safeQuery } from "app/db";
import { getEnv } from "app/env";
import { Sentry } from "app/sentry.server";

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

export const loader = async ({ context, request }: LoaderArgs) => {
  let userId: number | null = null;
  // Supabase appends an extra query string
  const url = new URL(request.url.replace("&%3F", "&"));
  const fromUrl = url.searchParams.get("from") || "/sync";
  const toUrl = url.searchParams.get("to") || DEFAULT_PATH;
  const email = url.searchParams.get("email");
  let provider = toProvider(url.searchParams.get("provider"));

  const supabaseAdmin = createServerAdminClient(context);

  try {
    const env = getEnv(context);

    let response: Response | undefined;
    let supabase;
    ({ supabase, response } = createServerClient(request, context));
    userId = (await getUser(supabase))?.id || null;

    if (!userId && restoreAuthCookie(request, response)) {
      return redirect(request.url, {
        status: 303,
        headers: response.headers,
      });
    }

    const session = await completeSignIn(request, supabase);

    // Load the user matching the auth user
    if (!userId) {
      userId = (await getUser(supabaseAdmin, session))?.id || null;
    }

    const {
      id: authUserId,
      email,
      name,
      avatar,
      credentials,
      provider: metadataProvider,
    } = await getUserMetadata(session);
    if (!authUserId) {
      throw new Error("Missing user metadata");
    }
    provider = metadataProvider;

    // Or create the user
    if (!userId) {
      const code = url.searchParams.get("invitation");
      if (code) {
        userId = safeQuery(
          await supabaseAdmin.rpc("insert_user", {
            _name: name,
            _email: email,
            _avatar_url: avatar,
            _invitation: code,
          })
        );
      } else {
        userId =
          safeQuery(
            await supabaseAdmin
              .from("user")
              .upsert(
                {
                  name,
                  email,
                  avatar_url: avatar,
                },
                { onConflict: "email" }
              )
              .select("id")
              .maybeSingle()
          )?.id || null;
      }
      if (!userId) {
        throw new Error("Could not create user");
      }
    }

    // Link waitlist to user
    try {
      if (email) {
        safeQuery(
          await supabaseAdmin
            .from("waitlist")
            .upsert(
              { email, provider, user_id: userId, sync_error: null },
              { onConflict: "email" }
            )
        );
      }
    } catch (error) {
      console.error(error);
      Sentry?.captureException?.(error);
    }

    // Create or link a contact for the user
    safeQuery(
      await supabaseAdmin
        .from("contact")
        .upsert(
          { email, name, user_id: userId, contact_user_id: userId },
          { onConflict: "user_id,email" }
        )
    );

    const account = safeQuery(
      await supabaseAdmin
        .from("account")
        .upsert(
          {
            user_id: userId,
            auth_user_id: authUserId,
            email,
            provider,
            credentials,
          },
          { onConflict: "auth_user_id" }
        )
        .select()
        .single()
    );

    if (account) {
      // Start a partial sync plus a full sync
      await env.SYNC_QUEUE?.send?.({
        accountId: account.id,
        syncType: "partial",
      });
      await env.SYNC_QUEUE?.send?.({ accountId: account.id, syncType: "full" });
    }

    return redirect(toUrl, {
      status: 303,
      headers: response.headers,
    });
  } catch (error) {
    // Might be a Remix response (like a redirect) rather than an error
    if (error instanceof Response) throw error;

    console.error(error);

    Sentry?.withScope?.((scope) => {
      const user = userId ?? url.searchParams.get("email");
      scope.setExtra("user", user);
      if (provider) {
        scope.setExtra("provider", provider);
      }
      Sentry?.captureException?.(error);
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

    // Log error to waitlist
    try {
      if (email) {
        safeQuery(
          await supabaseAdmin
            .from("waitlist")
            .upsert({ email, provider, sync_error }, { onConflict: "email" })
        );
      }
    } catch (error) {
      console.error(error);
      Sentry?.captureException?.(error);
    }

    const [fromPath, fromQuery] = fromUrl.split("?");
    const params = new URLSearchParams(fromQuery);
    params.append("error", sync_error);
    return redirect(`${fromPath}?${params.toString()}`, {
      status: 303,
    });
  }
};
