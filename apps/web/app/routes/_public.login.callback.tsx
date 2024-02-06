import { redirect } from "@remix-run/cloudflare";
import { type User } from "@supabase/supabase-js";

import {
  completeSignIn,
  getUser,
  redeemInvitation,
} from "app/auth";
import { publicLoader } from "app/util";

export const loader = publicLoader(
  async ({
    request,
    response,
    supabase,
    supabaseAdmin,
    tracker,
    sentry,
    waitlistedUser,
  }) => {
    const url = new URL(request.url);
    const fromUrl = url.searchParams.get("from") || "/login";
    let toUrl = url.searchParams.get("to");
    try {
      let user: User | null = null;
      if (url.searchParams.has("code") || url.searchParams.has("error")) {
        const session = await completeSignIn(request, supabase);

        // The new session does not apply to the current "supabase" instance, so a
        // combination of passing the session and using supabaseAdmin is required
        // for the rest of this request.

        user = await getUser(supabaseAdmin, tracker, sentry, session);
      } else if (waitlistedUser) {
        user = waitlistedUser;
      } else {
        throw new Error("Please try again");
      }

      const invitation = url.searchParams.get("invitation");
      if (user?.app_metadata?.invitation) {
        // Already in
        toUrl = '/';
      } else if (user && invitation) {
        await redeemInvitation(
          user,
          invitation,
          tracker,
          supabaseAdmin
        );
        toUrl = '/';
      } else {
        toUrl = "/waitlist";
      }

      return redirect(toUrl, {
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
  }
);
