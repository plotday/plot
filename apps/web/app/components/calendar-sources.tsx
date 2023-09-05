import { useEffect, useState } from "react";

import { useSearchParams } from "@remix-run/react";

import { Alert, Box, Stack, Text } from "@mantine/core";

import { IconAlertCircle } from "@tabler/icons-react";
import {
  GoogleLoginButton,
  MicrosoftLoginButton,
} from "react-social-login-buttons";

import type { CalendarProvider } from "@plotday/cal";

import { signIn } from "app/auth";
import { useSupabase } from "app/hooks";

export default function CalendarSources({
  redirectTo,
}: {
  redirectTo?: string;
}) {
  const supabase = useSupabase();

  const [searchParams, setSearchParams] = useSearchParams();
  const [error] = useState(searchParams.get("error"));
  useEffect(() => {
    if (searchParams.has("error")) {
      searchParams.delete("error");
      setSearchParams(searchParams);
    }
  });

  const login = async (provider: CalendarProvider) => {
    if (!supabase) return;

    let scopes;
    switch (provider) {
      case "google":
        scopes = ["https://www.googleapis.com/auth/calendar"];
        break;
      case "outlook":
        scopes = ["calendars.readwrite", "offline_access"];
        break;
    }

    let params = {
      provider,
    } as Record<string, string>;
    const email = searchParams.get("email");
    if (email) {
      params.email = email;
    }
    const invitation = searchParams.get("invitation");
    if (invitation) {
      params.invitation = invitation;
    }

    await signIn(
      supabase,
      provider,
      "/sync/callback",
      redirectTo,
      scopes,
      params
    );
  };

  return (
    <Stack>
      {error && (
        <Alert
          icon={<IconAlertCircle size="1rem" />}
          title="Sign in failed"
          color="red"
        >
          <Text mt="md">{error}</Text>
        </Alert>
      )}
      <Box w={280}>
        <GoogleLoginButton onClick={() => login("google")}>
          Sign in with Google
        </GoogleLoginButton>
      </Box>
      <Box w={280}>
        <MicrosoftLoginButton onClick={() => login("outlook")}>
          Sign in with Microsoft
        </MicrosoftLoginButton>
      </Box>
    </Stack>
  );
}
