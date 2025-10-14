import { createClient } from "@supabase/supabase-js";

import { Container, Stack, Text, Title, UnstyledButton } from "@mantine/core";

import { redirect, useSearchParams } from "react-router";

import { getUser } from "../lib/supabase.server";
import type { Route } from "./+types/signin";

export function meta(_: Route.MetaArgs) {
  return [
    {
      title: "Sign In | Plot",
    },
  ];
}

export async function loader({ request, context }: Route.LoaderArgs) {
  const { user } = await getUser(request, context.cloudflare.env);

  // If already authenticated, redirect to returnTo or home
  if (user) {
    const url = new URL(request.url);
    const returnTo = url.searchParams.get("returnTo") || "/";
    return redirect(returnTo);
  }

  return {
    supabaseUrl: context.cloudflare.env.SUPABASE_URL,
    supabaseAnonKey: context.cloudflare.env.SUPABASE_ANON_KEY,
  };
}

export default function SignIn({ loaderData }: Route.ComponentProps) {
  const [searchParams] = useSearchParams();
  const returnTo = searchParams.get("returnTo") || "/";

  const handleGoogleSignIn = async () => {
    const supabase = createClient(
      loaderData.supabaseUrl,
      loaderData.supabaseAnonKey,
      {
        auth: {
          flowType: 'pkce',
        },
      },
    );

    // Double-encode returnTo because Supabase will decode it once
    const encodedReturnTo = encodeURIComponent(encodeURIComponent(returnTo));

    const { error } = await supabase.auth.signInWithOAuth({
      provider: "google",
      options: {
        redirectTo: `${window.location.origin}/auth/callback?returnTo=${encodedReturnTo}`,
        queryParams: {
          prompt: 'select_account',
        },
      },
    });

    if (error) {
      console.error("Error signing in with Google:", error);
    }
  };

  return (
    <Container size="xs" mt="xl">
      <Stack gap="md">
        <Title order={2}>Sign In to Plot</Title>

        <UnstyledButton
          onClick={handleGoogleSignIn}
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
            cursor: "pointer",
            transition: "background-color 0.2s, box-shadow 0.2s",
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.backgroundColor = "#f8f9fa";
            e.currentTarget.style.boxShadow =
              "0 1px 2px 0 rgba(60,64,67,.3), 0 1px 3px 1px rgba(60,64,67,.15)";
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

        <Text size="sm" c="dimmed">
          By signing in, you agree to our Terms of Service and Privacy Policy.
        </Text>
      </Stack>
    </Container>
  );
}
