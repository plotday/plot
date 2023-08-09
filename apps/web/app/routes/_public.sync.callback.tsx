import type { LoaderArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";

import { completeSignIn, getUser, getUserMetadata } from "app/auth";
import { DEFAULT_PATH } from "app/config";
import { restoreAuthCookie } from "app/cookies.server";
import { createServerAdminClient, createServerClient, safeQuery } from "app/db";
import { getEnv } from "app/env";

export const loader = async ({ context, request }: LoaderArgs) => {
  try {
    const env = getEnv(context);

    let response: Response | undefined;
    let supabase;
    ({ supabase, response } = createServerClient(request, context));

    if (restoreAuthCookie(request, response)) {
      return redirect(request.url, {
        status: 303,
        headers: response.headers,
      });
    }

    const session = await completeSignIn(request, supabase);

    // Load the user matching the auth user
    const supabaseAdmin = createServerAdminClient(context);
    let user = await getUser(supabaseAdmin, session);

    const {
      id: userId,
      email,
      name,
      provider,
      avatar,
      credentials,
    } = await getUserMetadata(session);
    if (!userId) {
      throw new Error("Missing user metadata");
    }

    // Or create the user
    if (!user) {
      user = safeQuery(
        await supabaseAdmin
          .from("user")
          .insert({ email, name, avatar_url: avatar })
          .select()
          .maybeSingle()
      );
      if (!user) {
        throw new Error("Could not create new user");
      }
    }

    // Create or link a contact for the user
    safeQuery(
      await supabaseAdmin
        .from("contact")
        .upsert(
          { email, name, user_id: user.id, contact_user_id: user.id },
          { onConflict: "user_id,email" }
        )
    );

    const account = safeQuery(
      await supabaseAdmin
        .from("account")
        .upsert(
          {
            user_id: user.id,
            auth_user_id: userId,
            email,
            provider: provider === "google" ? "google" : "outlook",
            credentials,
          },
          { onConflict: "user_id, auth_user_id, provider" }
        )
        .select()
        .single()
    );

    if (account) {
      // Start a full sync
      await env.SYNC_QUEUE?.send?.({ accountId: account.id, full: true });
    }

    return redirect(DEFAULT_PATH, {
      status: 303,
      headers: response.headers,
    });
  } catch (error) {
    // Might be a Remix response (like a redirect) rather than an error
    if (error instanceof Response) throw error;

    console.error(error);
    // @ts-ignore
    console.error("Message", error?.message);
    const params = new URLSearchParams();
    let message = "Server error";
    if (error instanceof Error && error.message) {
      message = error.message;
    } else if (
      error instanceof Object &&
      "message" in error &&
      typeof error.message === "string" &&
      error.message
    ) {
      message = error.message;
    }

    params.append("error", message);
    return redirect(`/sync?${params.toString()}`, {
      status: 303,
    });
  }
};
