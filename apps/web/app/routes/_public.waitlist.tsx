import { useState } from "react";

import type { ActionArgs } from "@remix-run/cloudflare";
import { json } from "@remix-run/cloudflare";
import { Form, useActionData, useSearchParams } from "@remix-run/react";

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

import { createServerAdminClient, safeQuery } from "app/db";

export async function action({ request, context }: ActionArgs) {
  const body = await request.formData();
  const email = body.get("email")?.toString();
  if (!email) return null;

  const supabaseAdmin = createServerAdminClient(context);
  safeQuery(
    await supabaseAdmin
      .from("waitlist")
      .upsert({ email }, { onConflict: "email", ignoreDuplicates: true })
  );

  return json({
    email,
  });
}

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
  const email = useActionData()?.email;

  return (
    <Container size="xs" p="sm" mt="xl">
      <Stack gap="xl">
        {email && (
          <Card>
            <Stack>
              <Title>Awesome!</Title>
              <Text>
                We're thrilled you're taking this step to own your time.
              </Text>
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
            </Stack>
          </Card>
        )}

        {!email && (
          <Card>
            <Stack>
              <Title>Hello!</Title>
              <Text>Plot is currently in private, early access.</Text>
              <WaitlistForm />
            </Stack>
          </Card>
        )}

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
