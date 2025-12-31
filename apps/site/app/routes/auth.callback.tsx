import { Container, Loader, Stack, Text } from "@mantine/core";

import { redirect } from "react-router";

import { createSupabaseServerClient } from "../lib/supabase.server";
import type { Route } from "./+types/auth.callback";

export async function loader({ request, context }: Route.LoaderArgs) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const error_code = url.searchParams.get("error");
  const error_description = url.searchParams.get("error_description");
  const encodedReturnTo = url.searchParams.get("returnTo") || "/";
  const returnTo = encodedReturnTo === "/" ? "/" : decodeURIComponent(encodedReturnTo);

  console.log("Auth callback - URL:", request.url);
  console.log("Auth callback - error:", error_code, error_description);
  console.log("Auth callback - code:", code ? "present" : "missing");
  console.log("Auth callback - returnTo:", returnTo);

  // Handle OAuth errors
  if (error_code) {
    console.error("OAuth error:", error_code, error_description);
    return { error: error_description || "Authentication failed" };
  }

  // Create Supabase client with cookie storage (for PKCE code_verifier and session)
  const { supabase, headers } = createSupabaseServerClient(
    request,
    context.cloudflare.env,
  );

  // If we have a code, exchange it for a session
  if (code) {
    console.log("Exchanging OAuth code for session");
    const { error: authError } = await supabase.auth.exchangeCodeForSession(code);

    if (authError) {
      console.error("Authentication error:", authError.message, authError);
      return { error: `Failed to complete authentication: ${authError.message}` };
    }

    console.log("Successfully authenticated, redirecting to:", returnTo);

    // Redirect with session cookies set by the Supabase client
    return redirect(returnTo, { headers });
  }

  // If no code, check if we have an existing session
  const { data, error: sessionError } = await supabase.auth.getSession();

  if (sessionError || !data.session) {
    console.error("No code and no existing session");
    return { error: "Failed to complete authentication: No session available" };
  }

  console.log("Using existing session, redirecting to:", returnTo);
  return redirect(returnTo, { headers });
}

export default function AuthCallback({ loaderData }: Route.ComponentProps) {
  // If we got here with an error, show it
  if (loaderData && "error" in loaderData) {
    return (
      <Container size="xs" mt="xl">
        <Stack align="center" gap="md">
          <Text c="red">{loaderData.error}</Text>
          <Text size="sm" c="dimmed">
            <a href="/signin">Return to sign in</a>
          </Text>
        </Stack>
      </Container>
    );
  }

  // Otherwise, show loading (shouldn't normally be seen as loader redirects)
  return (
    <Container size="xs" mt="xl">
      <Stack align="center" gap="md">
        <Loader />
        <Text>Completing sign in...</Text>
      </Stack>
    </Container>
  );
}
