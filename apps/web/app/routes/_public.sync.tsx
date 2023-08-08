import { Card, Container, Stack, Text, Title } from "@mantine/core";
import { IconPlugConnected } from "@tabler/icons-react";

import CalendarSources from "../components/calendar-sources";
import Consent from "../components/consent";

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
