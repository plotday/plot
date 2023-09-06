import type { LoaderArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";

import { completeSignIn, getUser, getUserMetadata } from "app/auth";
import { DEFAULT_PATH } from "app/config";
import { createServerAdminClient, createServerClient } from "app/db";

export const loader = async ({ context, request }: LoaderArgs) => {
  let response: Response | undefined;
  const url = new URL(request.url);
  const fromUrl = url.searchParams.get("from") || "/login";
  let toUrl = url.searchParams.get("to") || DEFAULT_PATH;
  try {
    let supabase;
    ({ supabase, response } = createServerClient(request, context));
    const session = await completeSignIn(request, supabase);
    const supabaseAdmin = createServerAdminClient(context);
    let user = await getUser(supabaseAdmin, session);
    if (!user?.invitation) {
      const { email } = await getUserMetadata(session);
      toUrl = "/waitlist?email=" + encodeURIComponent(email);
    }

    return redirect(toUrl, {
      status: 303,
      headers: response.headers,
    });
  } catch (error) {
    // Might be a Remix response (like a redirect) rather than an error
    if (error instanceof Response) throw error;

    console.error(error);
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

    const newUrl = new URL(`${url.protocol}${url.host}${fromUrl}`);
    const params = new URLSearchParams(newUrl.search.substring(1));
    params.append("error", message);
    return redirect(`${newUrl.pathname}?${params.toString()}`, {
      status: 303,
    });
  }
};
