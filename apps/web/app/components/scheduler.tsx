import { Link } from "@remix-run/react";

import { Button, Card, Group, Stack, Title } from "@mantine/core";

import {
  IconBrandGoogle,
  IconBrandOffice,
  IconChevronLeft,
} from "@tabler/icons-react";
import classes from "css/event.module.css";

export function Scheduler() {
  return (
    <Card mih="100vh" style={{ borderRadius: 0 }}>
      <Stack>
        <Group>
          <Button
            component={Link}
            to=".."
            relative="path"
            variant="subtle"
            pl={0}
            pr={0}
            className={classes.mobileNav}
          >
            <IconChevronLeft />
          </Button>
          <Title order={2}>Schedule a new meeting</Title>
        </Group>
        <Button
          component="a"
          href="https://calendar.google.com/calendar/u/0/r/eventedit"
          target="_blank"
          variant="outline"
          fullWidth={false}
          leftSection={<IconBrandGoogle />}
          style={{ alignSelf: "flex-start" }}
        >
          Schedule in Google Calendar
        </Button>
        <Button
          component="a"
          href="https://outlook.office.com/calendar/0/view/month"
          target="_blank"
          variant="outline"
          fullWidth={false}
          leftSection={<IconBrandOffice />}
          style={{ alignSelf: "flex-start" }}
        >
          Schedule in Outlook
        </Button>
      </Stack>
    </Card>
  );
}
