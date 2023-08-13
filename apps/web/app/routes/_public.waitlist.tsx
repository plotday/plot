import type { ActionArgs } from "@remix-run/cloudflare";

import { Anchor, Card, Container, Stack, Text, Title } from "@mantine/core";

import { createServerAdminClient, safeQuery } from "app/db";

export async function action({ request, context }: ActionArgs) {
  const body = await request.formData();
  const email = body.get("email");
  if (!email) return null;

  const supabaseAdmin = createServerAdminClient(context);
  safeQuery(
    await supabaseAdmin
      .from("waitlist")
      .upsert({ email }, { onConflict: "email", ignoreDuplicates: true })
  );

  return null;
}

export default function Waitlist() {
  return (
    <Container size="sm">
      <Card>
        <Stack>
          <Title>Awesome!</Title>
          <Text>We're thrilled you're taking this step to own your time.</Text>
          <Text>We'll be in touch soon.</Text>
          <Text>
            &mdash;{" "}
            <Anchor href="https://www.linkedin.com/in/nigelvanderlinden/">
              Nigel
            </Anchor>{" "}
            and{" "}
            <Anchor href="https://www.linkedin.com/in/krisbraun/">Kris</Anchor>
          </Text>
        </Stack>
      </Card>
    </Container>
  );
}
