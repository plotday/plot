import { json } from "@remix-run/cloudflare";
import type { MetaFunction } from "@remix-run/react";

import { Alert, Card, Container, Stack, Text, Title } from "@mantine/core";

import { IconConfetti } from "@tabler/icons-react";
import { useTypedLoaderData } from "remix-typedjson";

import { getAccounts } from "app/auth";
import CalendarSources from "app/components/calendar-sources";
import Consent from "app/components/consent";
import { APP_NAME } from "app/config";
import { saveAuthCookie } from "app/cookies.server";
import { publicLoader } from "app/util";

export const loader = publicLoader(
  async ({ request, user, waitlistedUser, supabase, response }) => {
    let accounts = null;
    user ??= waitlistedUser;
    if (user) {
      accounts = await getAccounts(supabase, user.id);
    }

    saveAuthCookie(request, response);

    return json(
      {
        accounts,
      },
      {
        headers: response.headers,
      }
    );
  }
);

export const meta: MetaFunction = () => {
  return [
    {
      title: `${APP_NAME} | Calendar check`,
    },
  ];
};

export default function Check() {
  const { accounts } = useTypedLoaderData();
  const success = !!accounts?.length;
  return (
    <Container size="sm" p="sm" mt="xl">
      <Card>
        <Stack>
          <Title>Check your calendar</Title>
          {!success && (
            <Text>
              Plot works with your existing calendars. By testing
              synchronization now, we can be sure everything will work smoothly
              when your spot in the waitlist is ready.
            </Text>
          )}
          {success && (
            <>
              {accounts.map((calendar: any) => (
                <Alert
                  key={calendar.id}
                  icon={<IconConfetti size="1rem" />}
                  title="Success!"
                  color="brand"
                >
                  <Text mt="md">
                    The calendar for <b>{calendar.email}</b> is good to go.
                  </Text>
                </Alert>
              ))}
              <Title order={2} mt="lg">
                Check another calendar
              </Title>
            </>
          )}
          <CalendarSources />
          <Consent />
        </Stack>
      </Card>
    </Container>
  );
}
