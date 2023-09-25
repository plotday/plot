import type { AppLoadContext, LoaderFunctionArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";

import { Card, Container, Stack, Text, Title } from "@mantine/core";

import { IconPlugConnected } from "@tabler/icons-react";

import CalendarSources from "app/components/calendar-sources";
import Consent from "app/components/consent";
import { DEFAULT_PATH } from "app/config";
import { createServerAdminClient } from "app/db";

async function requireInvitation(request: Request, context: AppLoadContext) {
  const url = new URL(request.url);
  const invitation = url.searchParams.get("invitation");
  if (!invitation) throw redirect("/waitlist");

  const supabaseAdmin = createServerAdminClient(context);
  const match = (
    await supabaseAdmin
      .from("invitation")
      .select()
      .eq("code", invitation)
      .maybeSingle()
      .throwOnError()
  ).data;
  if (!match?.remaining)
    throw redirect(`/waitlist?invitation=${invitation}&error=invalid`);
}

export const loader = async ({ context, request }: LoaderFunctionArgs) => {
  await requireInvitation(request, context);
  return null;
};

export default function Sync() {
  return (
    <Container size="sm" p="sm" mt="xl">
      <Card>
        <Stack>
          <Title>
            <Text c="yellow" span inherit style={{ verticalAlign: "middle" }}>
              <IconPlugConnected size={34} />
            </Text>{" "}
            <Text span inherit>
              Connect your calendar
            </Text>
          </Title>
          <Text>
            Plot works with your existing calendars. Simply sign in with your
            primary calendar provider. You can always add more later.
          </Text>
          <CalendarSources redirectTo={DEFAULT_PATH} />
          <Consent />
        </Stack>
      </Card>
    </Container>
  );
}
