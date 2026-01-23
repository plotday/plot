import { redirect } from "react-router";
import { createSupabaseServerClient } from "../lib/supabase.server";
import type { Route } from "./+types/signout";

/**
 * Validates that a returnTo URL is safe to redirect to.
 * Only allows redirects to plot.day subdomains and relative paths.
 */
function isValidReturnTo(returnTo: string): boolean {
  if (returnTo === "/") return true;
  if (returnTo.startsWith("/") && !returnTo.startsWith("//")) return true;
  if (returnTo.startsWith("https://app.plot.day")) return true;
  if (returnTo.startsWith("https://plot.day")) return true;
  return false;
}

export async function loader({ request, context }: Route.LoaderArgs) {
  const { supabase, headers } = createSupabaseServerClient(
    request,
    context.cloudflare.env,
  );

  // Sign out - this will automatically set cookies to clear the session
  await supabase.auth.signOut();

  // Get and validate returnTo parameter to prevent open redirect vulnerabilities
  const url = new URL(request.url);
  const requestedReturnTo = url.searchParams.get("returnTo") || "/";
  const returnTo = isValidReturnTo(requestedReturnTo) ? requestedReturnTo : "/";

  return redirect(returnTo, { headers });
}
