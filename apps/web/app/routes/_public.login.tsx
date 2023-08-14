import { useEffect, useState } from "react";

import type { LoaderArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";
import { Link, useSearchParams } from "@remix-run/react";

import {
  Alert,
  Anchor,
  Box,
  Card,
  Container,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import { IconAlertCircle, IconSunFilled } from "@tabler/icons-react";
import {
  GoogleLoginButton,
  MicrosoftLoginButton,
} from "react-social-login-buttons";

import { getUser, signInWithAzure, signInWithGoogle } from "../auth";
import { DEFAULT_PATH } from "../config";
import { createServerClient } from "../db";
import { useSupabase } from "../root";

export const loader = async ({ context, request }: LoaderArgs) => {
  try {
    const url = new URL(request.url);
    if (url.searchParams.has("error")) return null;
    const { supabase } = createServerClient(request, context);
    const user = await getUser(supabase);
    if (user) return redirect(DEFAULT_PATH);
  } catch (error) {}
  return null;
};

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

  const googleLogin = async () => {
    if (!supabase) return;
    await signInWithGoogle(supabase, `${location.origin}/login/callback`);
  };
  const azureLogin = async () => {
    if (!supabase) return;
    await signInWithAzure(supabase, `${location.origin}/login/callback`);
  };

  return (
    <Container size="xs" p="sm" mt="xl">
      <Card>
        <Stack>
          <Title>
            <Text c="yellow" span inherit style={{ verticalAlign: "middle" }}>
              <IconSunFilled size={34} />
            </Text>{" "}
            <Text span inherit>
              Good day!
            </Text>
          </Title>
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
          <Text c="dimmed">
            Need an account?{" "}
            <Anchor component={Link} to={`/sync`}>
              Get started here
            </Anchor>
            .
          </Text>
        </Stack>
      </Card>
    </Container>
  );
}
