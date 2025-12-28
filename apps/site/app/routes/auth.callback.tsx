import { useEffect, useRef, useState } from "react";

import { Container, Loader, Stack, Text } from "@mantine/core";

import type { Session } from "@supabase/supabase-js";
import { createClient } from "@supabase/supabase-js";
import { Form, redirect, useSearchParams } from "react-router";

import { setAuthCookies } from "../lib/supabase.server";
import type { Route } from "./+types/auth.callback";

export async function loader({ context }: Route.LoaderArgs) {
  return {
    supabaseUrl: context.cloudflare.env.SUPABASE_URL,
    supabaseAnonKey: context.cloudflare.env.SUPABASE_ANON_KEY,
  };
}

export async function action({ request }: Route.ActionArgs) {
  const formData = await request.formData();
  const access_token = formData.get("access_token") as string;
  const refresh_token = formData.get("refresh_token") as string;
  const returnTo = (formData.get("returnTo") as string) || "/";

  if (!access_token || !refresh_token) {
    return redirect("/signin");
  }

  // Create session object to generate cookies
  const session: Session = {
    access_token,
    refresh_token,
    token_type: "bearer",
    user: null as any,
    expires_in: 3600,
    expires_at: Date.now() / 1000 + 3600,
  };

  const cookies = setAuthCookies(session);

  return redirect(returnTo, {
    headers: cookies.map((cookie) => ["Set-Cookie", cookie]),
  });
}

export default function AuthCallback({ loaderData }: Route.ComponentProps) {
  const [searchParams] = useSearchParams();
  const [error, setError] = useState<string | null>(null);
  const [session, setSession] = useState<{
    access_token: string;
    refresh_token: string;
    returnTo: string;
  } | null>(null);
  const formRef = useRef<HTMLFormElement>(null);

  useEffect(() => {
    const handleCallback = async () => {
      const error_code = searchParams.get("error");
      const error_description = searchParams.get("error_description");
      const code = searchParams.get("code");
      const encodedReturnTo = searchParams.get("returnTo") || "/";
      const returnTo = encodedReturnTo === "/" ? "/" : decodeURIComponent(encodedReturnTo);

      console.log("Integrations callback - URL:", window.location.href);
      console.log("Integrations callback - error:", error_code, error_description);
      console.log("Integrations callback - code:", code ? "present" : "missing");
      console.log("Integrations callback - returnTo:", returnTo);

      if (error_code) {
        console.error("OAuth error:", error_code, error_description);
        setError(error_description || "Authentication failed");
        return;
      }

      const supabase = createClient(loaderData.supabaseUrl, loaderData.supabaseAnonKey, {
        auth: {
          flowType: "pkce",
        },
      });

      let data;
      let authError;

      // If we have a code parameter (OAuth redirect), exchange it for a session
      if (code) {
        console.log("Exchanging OAuth code for session");
        const result = await supabase.auth.exchangeCodeForSession(code);
        data = result.data;
        authError = result.error;
      } else {
        // Otherwise, try to get an existing session
        console.log("Attempting to get existing session");
        const result = await supabase.auth.getSession();
        data = result.data;
        authError = result.error;
      }

      if (authError) {
        console.error("Authentication error:", authError.message, authError);
        setError(`Failed to complete authentication: ${authError.message}`);
        return;
      }

      if (!data.session) {
        console.error("No session returned from Supabase");
        setError("Failed to complete authentication: No session available");
        return;
      }

      console.log("Successfully authenticated");

      // Set session data which will trigger form submission
      setSession({
        access_token: data.session.access_token,
        refresh_token: data.session.refresh_token,
        returnTo,
      });
    };

    handleCallback();
  }, [searchParams, loaderData]);

  // Auto-submit form when session is ready
  useEffect(() => {
    if (session && formRef.current) {
      formRef.current.submit();
    }
  }, [session]);

  if (error) {
    return (
      <Container size="xs" mt="xl">
        <Stack align="center" gap="md">
          <Text c="red">{error}</Text>
          <Text size="sm" c="dimmed">
            <a href="/signin">Return to sign in</a>
          </Text>
        </Stack>
      </Container>
    );
  }

  return (
    <>
      <Container size="xs" mt="xl">
        <Stack align="center" gap="md">
          <Loader />
          <Text>Completing sign in...</Text>
        </Stack>
      </Container>

      {session && (
        <Form method="post" ref={formRef} style={{ display: "none" }}>
          <input type="hidden" name="access_token" value={session.access_token} />
          <input type="hidden" name="refresh_token" value={session.refresh_token} />
          <input type="hidden" name="returnTo" value={session.returnTo} />
        </Form>
      )}
    </>
  );
}
