import type { LoaderFunctionArgs } from "@remix-run/cloudflare";
import { json } from "@remix-run/cloudflare";
import type { MetaFunction } from "@remix-run/react";

import { Alert, Card, Container, Stack, Text, Title } from "@mantine/core";

import { IconConfetti } from "@tabler/icons-react";
import { useTypedLoaderData } from "remix-typedjson";

import { getUser } from "app/auth";
import CalendarSources from "app/components/calendar-sources";
import Consent from "app/components/consent";
import { APP_NAME } from "app/config";
import { saveAuthCookie } from "app/cookies.server";
import { createServerClient, safeQuery } from "app/db";

export async function loader({ request, context }: LoaderFunctionArgs) {
  let response: Response | undefined;
  let supabase;
  ({ supabase, response } = createServerClient(request, context));

  let user = await getUser(supabase);
  let accounts = null;
  if (user) {
    accounts = safeQuery(
      await supabase.from("account").select("id,provider,email")
    );
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
