import { useState } from "react";

import { json } from "@remix-run/cloudflare";
import { Form, Link, useSearchParams } from "@remix-run/react";

import {
  Alert,
  Button,
  Card,
  Container,
  Group,
  Stack,
  Text,
  TextInput,
  Title,
} from "@mantine/core";

import { IconMail } from "@tabler/icons-react";
import { useTypedActionData } from "remix-typedjson";

import { Turnstile, validateTurnstile } from "app/components/turnstile";
import { createServerAdminClient, safeQuery } from "app/db";
import { useUser } from "app/hooks";
import { publicAction } from "app/util";

export const action = publicAction(async ({ request, context, tracker }) => {
  const body = await request.formData();
  const email = body.get("email")?.toString();
  if (!email) return null;

  if (!(await validateTurnstile(request, body, context.env))) {
    return json({
      email,
      error: "Something went wrong. Please try again.",
    });
  }

  const supabaseAdmin = createServerAdminClient(context);
  const { id: userId } =
    safeQuery(
      await supabaseAdmin
        .from("user")
        .upsert({ email }, { onConflict: "email" })
        .select("id")
        .maybeSingle()
    ) || {};

  if (userId) {
    tracker.identify(userId.toString(), {
      Email: email,
    });
    tracker.accountWaitlisted(userId.toString());
  }

  return json({
    email,
  });
});

export function WaitlistForm() {
  const [searchParams] = useSearchParams();
  const email = searchParams.get("email") || "";
  return (
    <Form method="post" action="/waitlist">
      <Turnstile />
      <Group grow>
        <TextInput
          name="email"
          type="email"
          defaultValue={email}
          placeholder="Your work email"
          required
          leftSection={<IconMail size={16} />}
          maw="unset"
        />
        <Button type="submit" variant="gradient" maw="unset">
          Join the waitlist
        </Button>
      </Group>
    </Form>
  );
}

export default function Waitlist() {
  const [searchParams] = useSearchParams();
  const [hasError, setHasError] = useState(searchParams.has("error"));
  let user = useUser(true);
  const { email, error } = useTypedActionData() ?? {};
  const waitlisted = (user || email) && !error && !user?.invitation;
  const success = email && !error;
  let checkUrl = "/check";
  if (user) {
    checkUrl += `?uid=${user.id}`;
  } else if (email) {
    checkUrl += `?email=${encodeURIComponent(email)}`;
  }

  return (
    <Container size="xs" p="sm" mt="xl">
      <Stack gap="xl">
        <Card>
          <Stack>
            <Title>{email ? "Awesome!" : "Hello!"}</Title>
            <Text>
              {!email && "Plot is currently in private, early access. "}
              {email &&
                "We're thrilled you're taking this step to own your time. "}
              {waitlisted && "You've been added to the waitlist. "}
            </Text>
            {error && <Alert>{error}</Alert>}
            {!success && !waitlisted && <WaitlistForm />}
            {waitlisted && (
              <>
                <Title order={2}>Check your calendar</Title>
                <Text>
                  Some organizations require Plot to be approved before you can
                  sync your calendar. Testing your calendar now helps us start
                  that process.
                </Text>
                <Button component={Link} variant="outline" to={checkUrl}>
                  Check your calendar
                </Button>
              </>
            )}
          </Stack>
        </Card>

        <Card>
          <Stack>
            <Text>If you have an invitation code, please enter it here.</Text>
            <Form
              method="get"
              action={user ? "/sync" : "/login"}
              reloadDocument
            >
              <Turnstile />
              <Group grow align="start">
                <TextInput
                  name="invitation"
                  type="text"
                  defaultValue={searchParams.get("invitation") || ""}
                  placeholder="Invitation code"
                  required
                  maw="unset"
                  onChange={() => {
                    setHasError(false);
                  }}
                  error={
                    hasError ? "That code doesn't seem to exist" : undefined
                  }
                />
                <Button type="submit" variant="outline">
                  Use invitation
                </Button>
              </Group>
            </Form>
          </Stack>
        </Card>
      </Stack>
    </Container>
  );
}
