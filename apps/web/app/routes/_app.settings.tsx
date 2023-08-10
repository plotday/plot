import type { LoaderArgs } from "@remix-run/cloudflare";
import { json } from "@remix-run/cloudflare";
import { useLoaderData } from "@remix-run/react";

import { Box, Card, Container, Pill, Stack, Title } from "@mantine/core";

import { getUser } from "app/auth";
import CalendarSources from "app/components/calendar-sources";
import { saveAuthCookie } from "app/cookies.server";
import { createServerClient, safeQuery } from "app/db";

export async function loader({ request, context }: LoaderArgs) {
  let response: Response | undefined;
  let supabase;
  ({ supabase, response } = createServerClient(request, context));

  let user = await getUser(supabase);
  if (!user) {
    return null;
  }

  const calendars = safeQuery(
    await supabase
      .from("calendar")
      .select("id,provider_id,account(provider,email)")
  );

  saveAuthCookie(request, response);

  return json(
    {
      calendars,
    },
    {
      headers: response.headers,
    }
  );
}

export default function Settings() {
  const { calendars } = useLoaderData();
  return (
    <Container size="xs" p="sm">
      <Card>
        <Stack>
          <Title order={2}>Calendars</Title>
          {calendars.map((calendar: any) => (
            <Box key={calendar.id}>
              <Pill size="lg">
                {calendar.account.email} - {calendar.provider_id}
              </Pill>
            </Box>
          ))}
          <CalendarSources />
        </Stack>
      </Card>
    </Container>
  );
}
