import { Alert, Container, Paper, Stack, Text, Title } from "@mantine/core";
import type { LoaderArgs } from "@remix-run/cloudflare";
import { json } from "@remix-run/cloudflare";
import { useSearchParams } from "@remix-run/react";
import { IconAlertCircle } from "@tabler/icons-react";
import { useEffect, useState } from "react";
import {
  GoogleLoginButton,
  MicrosoftLoginButton,
} from "react-social-login-buttons";

import { getUser, signInWithAzure, signInWithGoogle } from "../auth";
import { saveAuthCookie } from "../cookies.server";
import { createServerClient } from "../db";
import { useSupabase } from "../root";

export async function loader({ request, context }: LoaderArgs) {
  let response: Response | undefined;
  let supabase;
  ({ supabase, response } = createServerClient(request, context));

  let user = await getUser(supabase);
  if (!user) {
    return null;
  }

  saveAuthCookie(request, response);

  return json(null, {
    headers: response.headers,
  });
}

export default function Sync() {
  const supabase = useSupabase();

  const [searchParams, setSearchParams] = useSearchParams();
  const [error] = useState(searchParams.get("error"));
  useEffect(() => {
    if (searchParams.has("error")) {
      searchParams.delete("error");
      setSearchParams(searchParams);
    }
  });

  const googleLogin = async () => {
    if (!supabase) return;
    await signInWithGoogle(supabase, `${location.origin}/sync/callback`, [
      "https://www.googleapis.com/auth/calendar.readonly",
    ]);
  };
  const outlookLogin = async () => {
    if (!supabase) return;
    await signInWithAzure(supabase, `${location.origin}/sync/callback`, [
      "calendars.readwrite",
      "offline_access",
    ]);
  };

  return (
    <Container size="xs" p="sm">
      <Stack mt="lg">
        <Paper>
          <Stack>
            <Title>Add a calendar</Title>
            <GoogleLoginButton onClick={googleLogin}>
              Sign in with Google
            </GoogleLoginButton>
            <MicrosoftLoginButton onClick={outlookLogin}>
              Sign in with Microsoft
            </MicrosoftLoginButton>
          </Stack>
        </Paper>
        {error && (
          <Alert
            icon={<IconAlertCircle size="1rem" />}
            title="Sign in failed"
            color="red"
          >
            <Text mt="md">{error}</Text>
          </Alert>
        )}
      </Stack>
    </Container>
  );
}
