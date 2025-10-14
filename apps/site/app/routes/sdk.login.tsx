import {
  Alert,
  Anchor,
  Button,
  Card,
  Code,
  Container,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import { IconInfoCircle } from "@tabler/icons-react";
import { Form, Link, useActionData, useNavigation } from "react-router";

import { getUser } from "../lib/supabase.server";
import type { Route } from "./+types/sdk.login";

export function meta(_: Route.MetaArgs) {
  return [
    {
      title: "Authorize CLI | Plot",
    },
  ];
}

export async function loader({ request, context }: Route.LoaderArgs) {
  const { user } = await getUser(request, context.cloudflare.env);
  const url = new URL(request.url);
  const sessionId = url.searchParams.get("session");

  return {
    user,
    sessionId,
    apiUrl: context.cloudflare.env.API_ROOT || "https://api.plot.day",
  };
}

export async function action({ request, context }: Route.ActionArgs) {
  const { user } = await getUser(request, context.cloudflare.env);

  if (!user) {
    return { error: "No active session" };
  }

  const formData = await request.formData();
  const sessionId = formData.get("sessionId") as string;

  const apiUrl = context.cloudflare.env.API_ROOT || "https://api.plot.day";

  // Get access token from cookies
  const cookieHeader = request.headers.get("Cookie") ?? "";
  const cookies = cookieHeader.split(";").reduce(
    (acc, cookie) => {
      const [name, ...rest] = cookie.trim().split("=");
      if (name && rest.length > 0) {
        acc[name] = rest.join("=");
      }
      return acc;
    },
    {} as Record<string, string>,
  );

  const accessToken = cookies["sb-access-token"];

  if (!accessToken) {
    return { error: "No access token found" };
  }

  try {
    const response = await fetch(`${apiUrl}/v1/session/authorize`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify({
        sessionId,
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      return { error: errorText || "Authorization failed" };
    }

    return { success: true };
  } catch (err) {
    return {
      error: err instanceof Error ? err.message : "Authorization failed",
    };
  }
}

export default function SdkLogin({ loaderData }: Route.ComponentProps) {
  const actionData = useActionData<typeof action>();
  const navigation = useNavigation();
  const isSubmitting = navigation.state === "submitting";

  const { user, sessionId } = loaderData;

  // Check if authorization was successful
  const success = actionData?.success === true;

  // If not authenticated, redirect to auth with return URL
  if (!user) {
    const returnUrl = `/sdk/login?session=${sessionId}`;
    return (
      <Container size="xs" mt="xl">
        <Stack gap="md">
          <Alert
            icon={<IconInfoCircle />}
            title="Authentication Required"
            color="blue"
          >
            Please sign in to authorize the Plot CLI.
          </Alert>
          <Button
            component={Link}
            to={`/signin?returnTo=${encodeURIComponent(returnUrl)}`}
            variant="gradient"
            size="lg"
            w="100%"
          >
            Sign In
          </Button>
        </Stack>
      </Container>
    );
  }

  if (!sessionId) {
    return (
      <Container size="xs" mt="xl">
        <Alert icon={<IconInfoCircle />} title="Invalid Request" color="red">
          Missing session ID. Please run <Code>plot login</Code> again.
        </Alert>
      </Container>
    );
  }

  if (success) {
    return (
      <Container size="xs" mt="xl">
        <Stack gap="md">
          <Title order={2}>Authorization Successful!</Title>
          <Text>
            Your Plot CLI has been authorized. You can now close this window and
            return to your terminal.
          </Text>
          <Alert icon={<IconInfoCircle />} color="green">
            The CLI should automatically detect the authorization and continue.
          </Alert>
        </Stack>
      </Container>
    );
  }

  return (
    <Container size="xs" mt="xl">
      <Stack gap="md">
        <Title order={2}>Authorize Plot CLI</Title>

        <Text>
          The Plot CLI is requesting access to your account. This will allow you
          to deploy and manage agents from your terminal.
        </Text>

        {actionData?.error && (
          <Alert icon={<IconInfoCircle />} title="Error" color="red">
            {actionData.error}
          </Alert>
        )}

        <Form method="post">
          <input type="hidden" name="sessionId" value={sessionId || ""} />
          <Button
            type="submit"
            variant="gradient"
            size="lg"
            loading={isSubmitting}
            w="100%"
          >
            Authorize
          </Button>
        </Form>

        <Card withBorder padding="md">
          <Stack gap="xs">
            <Text size="sm" c="dimmed">
              Signing in as:
            </Text>
            <Text fw={500}>{user.email}</Text>
            <Anchor
              size="sm"
              href={`/signout?returnTo=${encodeURIComponent(`/sdk/login?session=${sessionId}`)}`}
            >
              Sign in as different user
            </Anchor>
          </Stack>
        </Card>

        <Text size="sm" c="dimmed">
          By authorizing, you&apos;re granting the CLI permission to deploy
          agents and manage your Plot resources.
        </Text>
      </Stack>
    </Container>
  );
}
