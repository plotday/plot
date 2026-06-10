import { redirect } from "react-router";
import type { LoaderFunctionArgs } from "react-router";

import { getAuth } from "@clerk/react-router/ssr.server";
import { createClerkClient } from "@clerk/react-router/api.server";

import { initClerkEnv } from "./clerk.server";

const ALLOWED_DOMAIN = "@plot.day";

/**
 * Server-only gate for the /internal docs. Throws a redirect to /signin when
 * the request is unauthenticated, and a 403 Response when the signed-in user is
 * not on the @plot.day domain. Returns the verified email on success.
 *
 * Call this FIRST in every internal loader, before reading any doc content, so
 * unauthenticated/forbidden requests never receive doc bytes.
 */
export async function requireTeamMember(
  args: LoaderFunctionArgs,
): Promise<{ email: string }> {
  const env = args.context.cloudflare.env as {
    CLERK_SECRET_KEY: string;
    CLERK_PUBLISHABLE_KEY: string;
  };
  initClerkEnv(env);

  const auth = await getAuth(args);
  if (!auth.userId) {
    const pathname = new URL(args.request.url).pathname;
    throw redirect(`/signin?returnTo=${encodeURIComponent(pathname)}`);
  }

  const client = createClerkClient({
    secretKey: env.CLERK_SECRET_KEY,
    publishableKey: env.CLERK_PUBLISHABLE_KEY,
  });
  const user = await client.users.getUser(auth.userId);
  const email = user.primaryEmailAddress?.emailAddress ?? "";

  if (!email.toLowerCase().endsWith(ALLOWED_DOMAIN)) {
    throw new Response("Forbidden", { status: 403 });
  }

  return { email };
}
