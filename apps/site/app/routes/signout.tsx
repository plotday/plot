import { redirect } from "react-router";
import { createSupabaseServerClient } from "../lib/supabase.server";
import type { Route } from "./+types/signout";

export async function loader({ request, context }: Route.LoaderArgs) {
  const { supabase, headers } = createSupabaseServerClient(
    request,
    context.cloudflare.env,
  );

  // Sign out - this will automatically set cookies to clear the session
  await supabase.auth.signOut();

  // Get returnTo parameter
  const url = new URL(request.url);
  const returnTo = url.searchParams.get("returnTo") || "/";

  return redirect(returnTo, { headers });
}
