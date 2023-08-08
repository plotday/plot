import { Alert, Box, Stack, Text } from "@mantine/core";
import { useSearchParams } from "@remix-run/react";
import { IconAlertCircle } from "@tabler/icons-react";
import { useEffect, useState } from "react";
import {
  GoogleLoginButton,
  MicrosoftLoginButton,
} from "react-social-login-buttons";

import { signInWithAzure, signInWithGoogle } from "../auth";
import { useSupabase } from "../root";

export default function CalendarSources() {
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
    <Stack>
      <Box w={280}>
        <GoogleLoginButton onClick={googleLogin}>
          Add a Google calendar
        </GoogleLoginButton>
      </Box>
      <Box w={280}>
        <MicrosoftLoginButton onClick={outlookLogin}>
          Add an Outlook calendar
        </MicrosoftLoginButton>
      </Box>
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
  );
}
