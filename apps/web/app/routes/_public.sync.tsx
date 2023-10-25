import { Anchor, Card, Container, Stack, Text, Title } from "@mantine/core";

import { IconPlugConnected } from "@tabler/icons-react";

import CalendarSources from "app/components/calendar-sources";
import Consent from "app/components/consent";
import { useUser } from "app/hooks";

export default function Sync() {
  const user = useUser(true);
  const testing = !user?.invitation;
  return (
    <Container size="sm" p="sm" mt="xl">
      <Card>
        <Stack>
          <Title>
            <Text c="yellow" span inherit style={{ verticalAlign: "middle" }}>
              <IconPlugConnected size={34} />
            </Text>{" "}
            <Text span inherit>
              {testing ? "Check" : "Connect"} your calendar
            </Text>
          </Title>
          {testing && (
            <Text>
              Plot works with your existing calendars. Simply sign in with your
              primary calendar provider.
            </Text>
          )}
          {!testing && (
            <Text>
              Plot works with your existing calendars. Simply sign in with your
              primary calendar provider. You can always add more later.
            </Text>
          )}
          <Text>
            If your organization requires approval, just drop us a line at{" "}
            <Anchor href="mailto:team@plot.day">team@plot.day</Anchor> and we'll
            sort it out!
          </Text>
          <Text>
            If your organization requires approval, just drop us a line at{" "}
            <Anchor href="mailto:team@plot.day">team@plot.day</Anchor> and we'll
            sort it out!
          </Text>
          <CalendarSources redirectTo="/tune" />
          <Consent />
        </Stack>
      </Card>
    </Container>
  );
}
