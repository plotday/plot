import { useEffect, useState } from "react";

import { useSearchParams } from "@remix-run/react";

import { Alert, Box, Card, Container, Stack, Text, Title } from "@mantine/core";

import { IconAlertCircle, IconSunFilled } from "@tabler/icons-react";
import {
  GoogleLoginButton,
  MicrosoftLoginButton,
} from "react-social-login-buttons";

import Consent from "app/components/consent";
import { useSupabase } from "app/hooks";

import { signIn } from "../auth";
import { DEFAULT_PATH } from "../config";

export default function Login() {
  const supabase = useSupabase();
  const [searchParams, setSearchParams] = useSearchParams();
  const [error] = useState(searchParams.get("error"));

  useEffect(() => {
    if (searchParams.has("error")) {
      searchParams.delete("error");
      setSearchParams(searchParams);
    }
  });

  const invitation = searchParams.get("invitation");
  const googleLogin = async () => {
    if (!supabase) return;
    await signIn(
      supabase,
      "google",
      "/login/callback",
      DEFAULT_PATH,
      undefined,
      invitation ? { invitation } : undefined
    );
  };
  const azureLogin = async () => {
    if (!supabase) return;
    await signIn(
      supabase,
      "outlook",
      "/login/callback",
      DEFAULT_PATH,
      undefined,
      invitation ? { invitation } : undefined
    );
  };

  return (
    <Container size="xs" p="sm" mt="xl">
      <Card>
        <Title>
          <Text c="yellow" span inherit style={{ verticalAlign: "middle" }}>
            <IconSunFilled size={34} />
          </Text>{" "}
          <Text span inherit>
            Good day!
          </Text>
        </Title>
        <Stack>
          <Box m="xl">
            <Stack>
              <GoogleLoginButton onClick={googleLogin}>
                Sign in with Google
              </GoogleLoginButton>
              <MicrosoftLoginButton onClick={azureLogin}>
                Sign in with Microsoft
              </MicrosoftLoginButton>
            </Stack>
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
          <Consent />
        </Stack>
      </Card>
    </Container>
  );
}
