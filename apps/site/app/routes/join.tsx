import { useState } from "react";

import {
  Alert,
  Button,
  Container,
  PasswordInput,
  Stack,
  Text,
  TextInput,
  Title,
  UnstyledButton,
} from "@mantine/core";

import { redirect } from "react-router";

import { createSupabaseBrowserClient } from "../lib/supabase.client";
import { createSupabaseServerClient, getUser } from "../lib/supabase.server";
import type { Route } from "./+types/join";

const INVITE_COOKIE_NAME = "plot_invite";

export function meta(_: Route.MetaArgs) {
  return [
    {
      title: "Accept Invitation | Plot",
    },
  ];
}

function getCookie(request: Request, name: string): string | null {
  const cookies = request.headers.get("Cookie") || "";
  const match = cookies.match(new RegExp(`(?:^|; )${name}=([^;]*)`));
  return match ? decodeURIComponent(match[1]) : null;
}

export async function loader({ request, context }: Route.LoaderArgs) {
  const url = new URL(request.url);
  const inviteFromUrl = url.searchParams.get("invite");
  const inviteFromCookie = getCookie(request, INVITE_COOKIE_NAME);
  const inviteToken = inviteFromUrl || inviteFromCookie;

  const { supabase, headers } = createSupabaseServerClient(
    request,
    context.cloudflare.env,
  );

  const { user } = await getUser(request, context.cloudflare.env);
  const appRoot: string = context.cloudflare.env.APP_ROOT || "/";

  // If user is authenticated and we have a token, redeem it
  if (user && inviteToken) {
    const { data: sessionData } = await supabase.auth.getSession();
    const session = sessionData?.session;

    if (session?.access_token && session?.refresh_token) {
      // Call the redeem API
      const apiUrl = context.cloudflare.env.API_ROOT;
      try {
        const response = await fetch(`${apiUrl}/app/invitation/redeem`, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${session.access_token}/${session.refresh_token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ token: inviteToken }),
        });

        const result = (await response.json()) as {
          success: boolean;
          error?: string;
        };

        // Clear the cookie
        headers.append(
          "Set-Cookie",
          `${INVITE_COOKIE_NAME}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`,
        );

        if (result.success) {
          // Redirect to app on success
          return redirect(appRoot, { headers });
        }

        // On failure, show error
        return {
          supabaseUrl: context.cloudflare.env.SUPABASE_URL,
          supabaseAnonKey: context.cloudflare.env.SUPABASE_ANON_KEY,
          authenticated: true,
          redeemError: result.error || "Failed to accept invitation",
          appRoot,
        };
      } catch (error) {
        // Clear the cookie even on error
        headers.append(
          "Set-Cookie",
          `${INVITE_COOKIE_NAME}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`,
        );

        return {
          supabaseUrl: context.cloudflare.env.SUPABASE_URL,
          supabaseAnonKey: context.cloudflare.env.SUPABASE_ANON_KEY,
          authenticated: true,
          redeemError: "Failed to connect to server",
          appRoot,
        };
      }
    }
  }

  // If authenticated but no token, redirect to app
  if (user && !inviteToken) {
    return redirect(appRoot);
  }

  // Not authenticated - store token in cookie and show signin UI
  if (inviteFromUrl) {
    headers.append(
      "Set-Cookie",
      `${INVITE_COOKIE_NAME}=${encodeURIComponent(inviteFromUrl)}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=3600`,
    );
  }

  // Show error if no token at all
  if (!inviteToken) {
    return {
      supabaseUrl: context.cloudflare.env.SUPABASE_URL,
      supabaseAnonKey: context.cloudflare.env.SUPABASE_ANON_KEY,
      authenticated: false,
      noToken: true,
      appRoot,
    };
  }

  return {
    supabaseUrl: context.cloudflare.env.SUPABASE_URL,
    supabaseAnonKey: context.cloudflare.env.SUPABASE_ANON_KEY,
    authenticated: false,
    appRoot,
  };
}

type SignInMode = "main" | "emailPassword";

export default function Join({ loaderData }: Route.ComponentProps) {
  // Always return to /join so we can complete the redemption flow
  const returnTo = "/join";

  const [mode, setMode] = useState<SignInMode>("main");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const getSupabaseClient = () => {
    return createSupabaseBrowserClient(
      loaderData.supabaseUrl,
      loaderData.supabaseAnonKey,
    );
  };

  // Handle redeem error state
  if (loaderData.authenticated && loaderData.redeemError) {
    return (
      <Container size="xs" mt="xl">
        <Stack gap="md" align="center">
          <Title order={2}>Invitation Error</Title>
          <Alert color="red" title="Unable to accept invitation">
            {loaderData.redeemError === "invalid_token" &&
              "This invitation link is invalid or has already been used."}
            {loaderData.redeemError === "contact_linked_to_other_user" &&
              "This invitation was sent to a different account."}
            {loaderData.redeemError !== "invalid_token" &&
              loaderData.redeemError !== "contact_linked_to_other_user" &&
              loaderData.redeemError}
          </Alert>
          <Button component="a" href={loaderData.appRoot}>
            Go to Plot
          </Button>
        </Stack>
      </Container>
    );
  }

  // Handle no token state
  if (loaderData.noToken) {
    return (
      <Container size="xs" mt="xl">
        <Stack gap="md" align="center">
          <Title order={2}>Invalid Invitation Link</Title>
          <Text c="dimmed">
            This invitation link appears to be invalid or incomplete.
          </Text>
          <Button component="a" href="/">
            Go to Home
          </Button>
        </Stack>
      </Container>
    );
  }

  const handlePasswordSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!email.trim()) {
      setError("Please enter your email address");
      return;
    }

    if (!password) {
      setError("Please enter your password");
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      const supabase = getSupabaseClient();
      const { error: signInError } = await supabase.auth.signInWithPassword({
        email: email.trim(),
        password,
      });

      if (signInError) throw signInError;

      // Redirect will be handled by the auth callback
      window.location.href = `/auth/callback?returnTo=${encodeURIComponent(returnTo)}`;
    } catch (err) {
      console.error("Error signing in with password:", err);
      setError(err instanceof Error ? err.message : "Failed to sign in");
      setIsLoading(false);
    }
  };

  const handleGoogleSignIn = async () => {
    const supabase = getSupabaseClient();

    // Double-encode returnTo because Supabase will decode it once
    const encodedReturnTo = encodeURIComponent(encodeURIComponent(returnTo));

    const { error } = await supabase.auth.signInWithOAuth({
      provider: "google",
      options: {
        redirectTo: `${window.location.origin}/auth/callback?returnTo=${encodedReturnTo}`,
        queryParams: {
          prompt: "select_account",
        },
      },
    });

    if (error) {
      console.error("Error signing in with Google:", error);
      setError(error.message);
    }
  };

  const handleAppleSignIn = async () => {
    const supabase = getSupabaseClient();

    // Double-encode returnTo because Supabase will decode it once
    const encodedReturnTo = encodeURIComponent(encodeURIComponent(returnTo));

    const { error } = await supabase.auth.signInWithOAuth({
      provider: "apple",
      options: {
        redirectTo: `${window.location.origin}/auth/callback?returnTo=${encodedReturnTo}`,
      },
    });

    if (error) {
      console.error("Error signing in with Apple:", error);
      setError(error.message);
    }
  };

  return (
    <Container size="xs" mt="xl">
      <Stack gap="md">
        <Title order={2}>You've been invited to collaborate on Plot</Title>
        <Text c="dimmed">
          Sign in or create an account to accept your invitation and start
          collaborating on Plot.
        </Text>

        {mode === "main" ? (
          <>
            {/* OAuth buttons */}
            <UnstyledButton
              onClick={handleGoogleSignIn}
              disabled={isLoading}
              style={{
                width: "100%",
                height: 48,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                gap: 12,
                backgroundColor: "white",
                border: "1px solid #dadce0",
                borderRadius: 8,
                fontFamily: "Roboto, system-ui, -apple-system, sans-serif",
                fontSize: 16,
                fontWeight: 500,
                color: "#3c4043",
                cursor: isLoading ? "not-allowed" : "pointer",
                opacity: isLoading ? 0.6 : 1,
                transition: "background-color 0.2s, box-shadow 0.2s",
              }}
              onMouseEnter={(e) => {
                if (!isLoading) {
                  e.currentTarget.style.backgroundColor = "#f8f9fa";
                  e.currentTarget.style.boxShadow =
                    "0 1px 2px 0 rgba(60,64,67,.3), 0 1px 3px 1px rgba(60,64,67,.15)";
                }
              }}
              onMouseLeave={(e) => {
                e.currentTarget.style.backgroundColor = "white";
                e.currentTarget.style.boxShadow = "none";
              }}
            >
              <svg
                width="18"
                height="18"
                viewBox="0 0 18 18"
                xmlns="http://www.w3.org/2000/svg"
              >
                <g fill="none" fillRule="evenodd">
                  <path
                    d="M17.64 9.205c0-.639-.057-1.252-.164-1.841H9v3.481h4.844a4.14 4.14 0 0 1-1.796 2.716v2.259h2.908c1.702-1.567 2.684-3.875 2.684-6.615Z"
                    fill="#4285F4"
                  />
                  <path
                    d="M9 18c2.43 0 4.467-.806 5.956-2.18l-2.908-2.259c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 0 0 9 18Z"
                    fill="#34A853"
                  />
                  <path
                    d="M3.964 10.71A5.41 5.41 0 0 1 3.682 9c0-.593.102-1.17.282-1.71V4.958H.957A8.996 8.996 0 0 0 0 9c0 1.452.348 2.827.957 4.042l3.007-2.332Z"
                    fill="#FBBC05"
                  />
                  <path
                    d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 0 0 .957 4.958L3.964 7.29C4.672 5.163 6.656 3.58 9 3.58Z"
                    fill="#EA4335"
                  />
                </g>
              </svg>
              Continue with Google
            </UnstyledButton>

            <UnstyledButton
              onClick={handleAppleSignIn}
              disabled={isLoading}
              style={{
                width: "100%",
                height: 48,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                gap: 12,
                backgroundColor: "black",
                border: "1px solid black",
                borderRadius: 8,
                fontFamily: "-apple-system, system-ui, sans-serif",
                fontSize: 16,
                fontWeight: 600,
                color: "white",
                cursor: isLoading ? "not-allowed" : "pointer",
                opacity: isLoading ? 0.6 : 1,
                transition: "background-color 0.2s",
              }}
              onMouseEnter={(e) => {
                if (!isLoading) {
                  e.currentTarget.style.backgroundColor = "#1d1d1f";
                }
              }}
              onMouseLeave={(e) => {
                e.currentTarget.style.backgroundColor = "black";
              }}
            >
              <svg
                width="18"
                height="18"
                viewBox="0 0 24 24"
                xmlns="http://www.w3.org/2000/svg"
                fill="white"
              >
                <path d="M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09l.01-.01zM12.03 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
              </svg>
              Continue with Apple
            </UnstyledButton>

            {/* Continue with email button */}
            <Button
              variant="default"
              fullWidth
              onClick={() => setMode("emailPassword")}
              disabled={isLoading}
            >
              Continue with email
            </Button>

            {error && (
              <Alert color="red" title="Error">
                {error}
              </Alert>
            )}
          </>
        ) : (
          <>
            {/* Email/Password sign-in form */}
            <form onSubmit={handlePasswordSubmit}>
              <Stack gap="md">
                <TextInput
                  label="Email"
                  placeholder="your@email.com"
                  type="email"
                  value={email}
                  onChange={(e) => setEmail(e.currentTarget.value)}
                  required
                  disabled={isLoading}
                />

                <PasswordInput
                  label="Password"
                  placeholder="Enter your password"
                  value={password}
                  onChange={(e) => setPassword(e.currentTarget.value)}
                  required
                  disabled={isLoading}
                />

                <Button type="submit" loading={isLoading} fullWidth>
                  Sign in
                </Button>

                <Button
                  variant="subtle"
                  size="xs"
                  onClick={() => {
                    setMode("main");
                    setPassword("");
                    setError(null);
                  }}
                  disabled={isLoading}
                  style={{ alignSelf: "flex-start" }}
                >
                  ← Back
                </Button>
              </Stack>
            </form>

            {error && (
              <Alert color="red" title="Error">
                {error}
              </Alert>
            )}
          </>
        )}

        <Text size="sm" c="dimmed" ta="center">
          By signing in, you agree to our <a href="/terms">Terms of Service</a>{" "}
          and <a href="/privacy">Privacy Policy</a>.
        </Text>
      </Stack>
    </Container>
  );
}
