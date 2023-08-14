import type { LoaderArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";

import { completeSignIn, getUser, getUserMetadata } from "app/auth";
import { DEFAULT_PATH } from "app/config";
import { getCookie, restoreAuthCookie } from "app/cookies.server";
import { createServerAdminClient, createServerClient, safeQuery } from "app/db";
import { getEnv } from "app/env";

export const loader = async ({ context, request }: LoaderArgs) => {
  let userId = undefined;
  try {
    const env = getEnv(context);

    let response: Response | undefined;
    let supabase;
    ({ supabase, response } = createServerClient(request, context));
    userId = (await getUser(supabase))?.id;

    if (!userId && restoreAuthCookie(request, response)) {
      return redirect(request.url, {
        status: 303,
        headers: response.headers,
      });
    }

    const session = await completeSignIn(request, supabase);

    // Load the user matching the auth user
    const supabaseAdmin = createServerAdminClient(context);
    if (!userId) {
      userId = (await getUser(supabaseAdmin, session))?.id;
    }

    const {
      id: authUserId,
      email,
      name,
      provider,
      avatar,
      credentials,
    } = await getUserMetadata(session);
    if (!authUserId) {
      throw new Error("Missing user metadata");
    }

    // Or create the user
    if (!userId) {
      const code = getCookie(request, "invitation");
      userId = safeQuery(
        await supabaseAdmin.rpc("insert_user", {
          _name: name,
          _email: email,
          _avatar_url: avatar,
          _invitation: code,
        })
      );
      if (!userId) {
        throw new Error("Could not create user");
      }
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
            provider: provider === "google" ? "google" : "outlook",
            credentials,
          },
          { onConflict: "auth_user_id" }
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

    const params = new URLSearchParams();
    params.append("error", message);
    return redirect(`/${userId ? "settings" : "sync"}?${params.toString()}`, {
      status: 303,
    });
  }
};
