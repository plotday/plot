import { Card, Container, Stack, Text, Title } from "@mantine/core";

import { IconPlugConnected } from "@tabler/icons-react";

import CalendarSources from "app/components/calendar-sources";
import Consent from "app/components/consent";

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
          <CalendarSources redirectTo="/tune" />
          <Consent />
        </Stack>
      </Card>
    </Container>
  );
}
