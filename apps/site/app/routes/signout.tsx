import { redirect } from "react-router";

import { createClient } from "@supabase/supabase-js";
import { clearAuthCookies, getUser } from "../lib/supabase.server";
import type { Route } from "./+types/signout";

export async function loader({ request, context }: Route.LoaderArgs) {
  const { user } = await getUser(request, context.cloudflare.env);

  // Sign out from Supabase if user is authenticated
  if (user) {
    const supabase = createClient(context.cloudflare.env.SUPABASE_URL, context.cloudflare.env.SUPABASE_ANON_KEY);
    await supabase.auth.signOut();
  }

  // Clear auth cookies
  const cookies = clearAuthCookies();

  // Get returnTo parameter
  const url = new URL(request.url);
  const returnTo = url.searchParams.get("returnTo") || "/";

  return redirect(returnTo, {
    headers: cookies.map((cookie) => ["Set-Cookie", cookie]),
  });
}
