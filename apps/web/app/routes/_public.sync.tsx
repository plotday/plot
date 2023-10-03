import { Card, Container, Stack, Text, Title } from "@mantine/core";

import { IconPlugConnected } from "@tabler/icons-react";

import CalendarSources from "app/components/calendar-sources";
import Consent from "app/components/consent";
import { DEFAULT_PATH } from "app/config";
import { privateLoader } from "app/util";

export const loader = privateLoader(async () => {
  return null;
});

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
          <CalendarSources redirectTo={DEFAULT_PATH} />
          <Consent />
        </Stack>
      </Card>
    </Container>
  );
}
