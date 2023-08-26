import { useCallback } from "react";

import type { LoaderArgs } from "@remix-run/cloudflare";
import { json } from "@remix-run/cloudflare";
import { useLoaderData } from "@remix-run/react";

import { Box, Button, Card, Container, Stack, Title } from "@mantine/core";

import { getUser, logout } from "app/auth";
import CalendarSources from "app/components/calendar-sources";
import { saveAuthCookie } from "app/cookies.server";
import { createServerClient, safeQuery } from "app/db";
import { useSupabase } from "app/hooks";

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
  const supabase = useSupabase();
  const doLogout = useCallback(() => {
    if (!supabase) return;
    logout(supabase);
  }, [supabase]);
  return (
    <Container size="xs" p="sm">
      <Card>
        <Stack>
          {calendars.length > 0 && <Title order={2}>Active calendars</Title>}
          {calendars.map((calendar: any) => (
            <Box key={calendar.id}>
              <Card withBorder>
                {calendar.account.email} - {calendar.provider_id}
              </Card>
            </Box>
          ))}
          <Title order={2}>Add a calendar</Title>
          <CalendarSources />
        </Stack>
      </Card>
      <Box mt="lg">
        <Button onClick={doLogout} variant="outline" color="red">
          Sign out
        </Button>
      </Box>
    </Container>
  );
}
