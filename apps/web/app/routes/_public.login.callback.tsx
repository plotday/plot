import type { LoaderArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";

import { completeSignIn, getUser } from "app/auth";
import { DEFAULT_PATH } from "app/config";
import { createServerAdminClient, createServerClient } from "app/db";

export const loader = async ({ context, request }: LoaderArgs) => {
  let response: Response | undefined;
  try {
    let supabase;
    ({ supabase, response } = createServerClient(request, context));
    const session = await completeSignIn(request, supabase);
    const supabaseAdmin = createServerAdminClient(context);
    let user = await getUser(supabaseAdmin, session);

    if (!user) {
      return redirect("/invitation", {
        headers: response.headers,
      });
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
