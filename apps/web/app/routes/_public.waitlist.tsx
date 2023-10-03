import { useState } from "react";

import { json } from "@remix-run/cloudflare";
import { Form, useSearchParams } from "@remix-run/react";

import {
  Anchor,
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

import { createServerAdminClient, safeQuery } from "app/db";
import { useUser } from "app/hooks";
import { publicAction } from "app/util";

export const action = publicAction(async ({ request, context, env }) => {
  const body = await request.formData();
  const email = body.get("email")?.toString();
  if (!email) return null;

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
    env.tracker.identify(userId.toString(), {
      Email: email,
    });
    env.tracker.accountWaitlisted(userId.toString());
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
  if (user?.activated_at) user = null;
  const email = useTypedActionData()?.email;

  return (
    <Container size="xs" p="sm" mt="xl">
      <Stack gap="xl">
        <Card>
          <Stack>
            <Title>{email ? "Awesome!" : "Hello!"}</Title>
            {!email && <Text>Plot is currently in private, early access.</Text>}
            {email && (
              <Text>
                We're thrilled you're taking this step to own your time.
              </Text>
            )}
            {user && <Text>You've been added to the waitlist.</Text>}
            {!email && !user && <WaitlistForm />}
            {(email || user) && (
              <>
                <Text>We'll be in touch soon.</Text>
                <Text>
                  &mdash;{" "}
                  <Anchor href="https://www.linkedin.com/in/nigelvanderlinden/">
                    Nigel
                  </Anchor>{" "}
                  and{" "}
                  <Anchor href="https://www.linkedin.com/in/krisbraun/">
                    Kris
                  </Anchor>
                </Text>
              </>
            )}
          </Stack>
        </Card>

        <Card>
          <Stack>
            <Text>If you have an invitation code, please enter it here.</Text>
            <Form method="get" action="/sync">
              {searchParams.get("email") && (
                <input
                  type="hidden"
                  name="email"
                  value={searchParams.get("email")!}
                />
              )}
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
