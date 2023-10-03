import { redirect } from "@remix-run/cloudflare";

import {
  activateAccount,
  addAccount,
  completeSignIn,
  getAccounts,
  getUser,
} from "app/auth";
import { DEFAULT_PATH } from "app/config";
import { publicLoader } from "app/util";

export const loader = publicLoader(
  async ({ request, response, supabase, supabaseAdmin, env }) => {
    const url = new URL(request.url);
    const fromUrl = url.searchParams.get("from") || "/login";
    let toUrl = url.searchParams.get("to") || DEFAULT_PATH;
    try {
      const session = await completeSignIn(request, supabase);

      // The new session does not apply to the current "supabase" instance, so a
      // combination of passing the session and using supabaseAdmin is required
      // for the rest of this request.

      let user = await getUser(supabaseAdmin, env, session);
      if (!user) {
        ({ user } = await addAccount(user, session, env, supabaseAdmin));
      }

      const invitation = url.searchParams.get("invitation");
      if (invitation) {
        await activateAccount(user, invitation, env, supabaseAdmin);
      }

      const accounts = await getAccounts(supabaseAdmin, user.id);
      if (accounts?.length === 0) {
        toUrl = "/sync";
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
