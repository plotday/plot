import { json } from "@remix-run/cloudflare";
import type { MetaFunction } from "@remix-run/react";
import { useLocation } from "@remix-run/react";

import {
  Alert,
  Anchor,
  Card,
  Container,
  Stack,
  Text,
  Title,
} from "@mantine/core";

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
  const location = useLocation();
  return (
    <Container size="sm" p="sm" mt="xl">
      <Card>
        <Stack>
          <Title>Check your calendar</Title>
          {!success && (
            <>
              <Text>
                Plot works with your existing calendars. Simply sign in with
                your primary calendar to test if everything will work smoothly
                when your spot in the waitlist is ready.
              </Text>
              <Text>
                If your organization requires approval, just drop us a line at{" "}
                <Anchor href="mailto:team@plot.day">team@plot.day</Anchor> and
                we'll sort it out!
              </Text>
            </>
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
                    The calendar for <b>{calendar.email}</b> is good to go!
                  </Text>
                </Alert>
              ))}
              <Text>
                Thanks for checking. We look forward to getting you started on
                Plot soon!
              </Text>

              <Title order={2} mt="lg">
                Check another calendar
              </Title>
            </>
          )}
          <CalendarSources
            redirectTo={location.pathname + (location.search ?? "")}
          />
          {!success && <Consent />}
        </Stack>
      </Card>
    </Container>
  );
}
