import type { LoaderArgs } from "@remix-run/cloudflare";
import { json, redirect } from "@remix-run/cloudflare";

import { Card, Container, Stack, Text, Title } from "@mantine/core";

import { IconPlugConnected } from "@tabler/icons-react";

import { getUserId } from "app/auth";
import CalendarSources from "app/components/calendar-sources";
import Consent from "app/components/consent";
import { getCookie } from "app/cookies.server";
import { createServerClient } from "app/db";

export const loader = async ({ context, request }: LoaderArgs) => {
  let response: Response | undefined;
  let supabase;
  ({ supabase, response } = createServerClient(request, context));

  let user = await getUserId(supabase);
  if (!user) {
    return redirect("/login");
  }

  if (!getCookie(request, "invitation")) return redirect("/invitation");

  return json({}, { headers: response.headers });
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
            Plot works with your existing calendars. Simply start by adding your
            main work calendar. You can always add more later.
          </Text>
          <CalendarSources />
          <Consent />
        </Stack>
      </Card>
    </Container>
  );
}
