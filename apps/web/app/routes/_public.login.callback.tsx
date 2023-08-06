import type { LoaderArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";

import { completeSignIn, getUser, getUserMetadata } from "../auth";
import { DEFAULT_PATH } from "../config";
import { createServerAdminClient, createServerClient, safeQuery } from "../db";

export const loader = async ({ context, request }: LoaderArgs) => {
  let response: Response | undefined;
  try {
    let supabase;
    ({ supabase, response } = createServerClient(request, context));

    const session = await completeSignIn(request, supabase);

    const supabaseAdmin = createServerAdminClient(context);

    let user = await getUser(supabaseAdmin, session);

    if (!user) {
      const {
        id: userId,
        email,
        name,
        provider,
        avatar,
      } = await getUserMetadata(session);
      if (!userId) {
        return redirect("/login");
      }

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
      safeQuery(
        await supabaseAdmin.from("account").insert({
          user_id: user.id,
          auth_user_id: userId,
          email,
          provider: provider === "google" ? "google" : "outlook",
        })
      );
    }

    return redirect(DEFAULT_PATH, {
      status: 303,
      headers: response.headers,
    });
  } catch (error) {
    // Might be a Remix response (like a redirect) rather than an error
    if (error instanceof Response) throw error;

    console.error(error);
    const params = new URLSearchParams();
    let message = "Server error";
    if (error instanceof Error) {
      message = error.message;
    } else if (
      error instanceof Object &&
      "message" in error &&
      typeof error.message === "string"
    ) {
      message = error.message;
    }

    params.append("error", message);
    return redirect(`/login?${params.toString()}`, {
      status: 303,
      headers: response?.headers ?? {},
    });
  }
};
