import { useCallback } from "react";

import type { SupabaseClient } from "@supabase/supabase-js";

import {
  Box,
  Button,
  Card,
  Checkbox,
  Container,
  Group,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import { typedjson, useTypedLoaderData } from "remix-typedjson";

import { safeQuery, saveCredentials } from "@plotday/db";

import { logout } from "app/auth";
import {
  getCalendars as getAccountCalendars,
  getCalendarConfig,
} from "app/cal";
import CalendarSources from "app/components/calendar-sources";
import { saveAuthCookie } from "app/cookies.server";
import type { Environment } from "app/env.server";
import { useSupabase } from "app/hooks";
import { privateLoader } from "app/util";

async function getCalendars(
  supabase: SupabaseClient,
  env: Environment,
  userId: number
) {
  const accounts = safeQuery(
    await supabase
      .from("account")
      .select(
        "id,provider,email,credentials,calendars:calendar(name,provider_id)"
      )
      .eq("user_id", userId)
  );
  if (!accounts) return [];
  const allCalendars = await Promise.all(
    accounts.map(async (account) => {
      const { calendars, credentials } = await getAccountCalendars(
        getCalendarConfig(env),
        {
          provider: account.provider,
          email: account.email,
          access_token: account.credentials.access_token,
          refresh_token: account.credentials.refresh_token,
          scopes: account.credentials.scopes,
        }
      );
      await saveCredentials(supabase, account.id, credentials);
      return calendars;
    })
  );
  return allCalendars.flat();
}

export const loader = privateLoader(
  async ({ request, response, supabase, env, user }) => {
    saveAuthCookie(request, response);

    return typedjson(
      {
        calendars: await getCalendars(supabase, env, user.id),
      },
      {
        headers: response.headers,
      }
    );
  }
);

export default function Settings() {
  const { calendars } = useTypedLoaderData<typeof loader>();
  const supabase = useSupabase();
  const doLogout = useCallback(() => {
    if (!supabase) return;
    logout(supabase);
  }, [supabase]);
  return (
    <Container size="xs" p="sm">
      <Card>
        <Stack>
          {calendars && calendars.length > 0 && (
            <Title order={2}>Calendars</Title>
          )}
          {calendars?.map((calendar) => (
            <Box key={calendar.id}>
              <Card withBorder>
                <Group>
                  <Checkbox readOnly radius="xl" checked={calendar.primary} />
                  <Text>
                    {calendar.name} ({calendar.account})
                  </Text>
                </Group>
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
