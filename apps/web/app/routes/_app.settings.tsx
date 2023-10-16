import { useCallback } from "react";

import { useFetcher } from "@remix-run/react";

import type { SupabaseClient } from "@supabase/supabase-js";

import {
  Box,
  Button,
  Card,
  Checkbox,
  Container,
  Stack,
  Title,
} from "@mantine/core";

import { typedjson, useTypedLoaderData } from "remix-typedjson";
import { z } from "zod";

import { safeQuery, saveCalendars, saveCredentials } from "@plotday/db";

import { logout } from "app/auth";
import {
  getCalendars as getAccountCalendars,
  getCalendarConfig,
} from "app/cal";
import CalendarSources from "app/components/calendar-sources";
import { saveAuthCookie } from "app/cookies.server";
import type { Environment } from "app/env.server";
import { useSupabase } from "app/hooks";
import type { Sentry } from "app/sentry.server";
import { privateAction, privateLoader } from "app/util";

async function refreshCalendars(
  supabaseAdmin: SupabaseClient,
  env: Environment,
  sentry: Sentry,
  userId: number
) {
  const accounts = safeQuery(
    await supabaseAdmin
      .from("account")
      .select(
        "id,provider,email,credentials,calendars:calendar(name,provider_id)"
      )
      .eq("user_id", userId)
  );
  if (!accounts) return;
  await Promise.all(
    accounts.map(async (account) => {
      try {
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
        await Promise.all([
          saveCredentials(supabaseAdmin, account.id, credentials),
          saveCalendars(supabaseAdmin, account.id, calendars),
        ]);
      } catch (error) {
        console.error(error);
        sentry?.captureException?.(error);
      }
    })
  );
}

async function getCalendars(supabase: SupabaseClient, userId: number) {
  const accounts = safeQuery(
    await supabase
      .from("account")
      .select("id,provider,email,calendars:calendar(id,name,enabled)")
      .eq("user_id", userId)
      .order("id")
      .order("enabled", { foreignTable: "calendar", ascending: false })
  );
  if (!accounts) return [];
  return accounts.map((account) => ({
    email: account.email,
    provider: account.provider,
    calendars: account.calendars.map((calendar) => ({
      id: calendar.id,
      name: calendar.name,
      enabled: calendar.enabled,
    })),
  }));
}

export const loader = privateLoader(
  async ({
    request,
    response,
    supabase,
    supabaseAdmin,
    context,
    env,
    sentry,
    user,
  }) => {
    saveAuthCookie(request, response);
    context.waitUntil(refreshCalendars(supabaseAdmin, env, sentry, user.id));

    return typedjson(
      {
        calendars: await getCalendars(supabase, user.id),
      },
      {
        headers: response.headers,
      }
    );
  }
);

export const action = privateAction(
  async ({ request, supabaseAdmin, env, user, tracker, response }) => {
    switch (request.method) {
      case "PATCH": {
        const schema = z.object({
          calendarId: z.coerce.number(),
          enabled: z.coerce.boolean(),
        });
        const data = schema.parse(Object.fromEntries(await request.formData()));
        safeQuery(
          await supabaseAdmin
            .from("calendar")
            .update({ enabled: data.enabled })
            .eq("id", data.calendarId)
        );
        if (data.enabled) {
          tracker.calendarAdded(user.id.toString());
          await env.SYNC_QUEUE?.send?.({
            calendarId: data.calendarId,
          });
        } else {
          tracker.calendarRemoved(user.id.toString());
        }

        return new Response(null, {
          headers: response.headers,
          status: 200,
        });
      }

      default:
        return new Response("Unsupported method", { status: 405 });
    }
  }
);

export default function Settings() {
  const { calendars } = useTypedLoaderData<typeof loader>();
  const supabase = useSupabase();
  const doLogout = useCallback(() => {
    if (!supabase) return;
    logout(supabase);
  }, [supabase]);
  const fetcher = useFetcher();
  return (
    <Container size="xs" p="sm">
      <Card>
        <Stack gap="xl">
          {calendars && calendars.length > 0 && (
            <fetcher.Form method="post">
              <Stack gap="lg">
                <Title order={2}>Calendars</Title>
                {calendars?.map((account) => (
                  <Box key={account.email}>
                    <Stack>
                      <Title order={3}>{account.email}</Title>
                      {account.calendars.map((calendar) => (
                        <Checkbox
                          key={calendar.id}
                          radius="xl"
                          label={calendar.name}
                          checked={calendar.enabled}
                          onChange={() => {
                            fetcher.submit(
                              {
                                calendarId: calendar.id,
                                enabled: !calendar.enabled,
                              },
                              { method: "PATCH" }
                            );
                          }}
                        />
                      ))}
                    </Stack>
                  </Box>
                ))}
              </Stack>
            </fetcher.Form>
          )}
          <Stack>
            <Title order={2}>Add a calendar</Title>
            <CalendarSources />
          </Stack>
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
