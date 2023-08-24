import React, { useCallback, useState } from "react";

import {
  Anchor,
  Badge,
  Box,
  Button,
  Card,
  Chip,
  Group,
  Paper,
  Stack,
  Text,
  Title,
  Tooltip,
} from "@mantine/core";

import { IconExternalLink } from "@tabler/icons-react";

import type { EventResponse } from "@plotday/cal";
import type { Event } from "@plotday/db";
import { formatDay, formatTimes, isSameDay } from "@plotday/tz";

import { useEventWatch } from "app/event";
import { useEventResponder } from "app/routes/api.response";

export function EventList({ events }: { events: Event[] }) {
  useEventWatch();

  let last: Date | undefined;
  return (
    <Stack>
      {events
        .reduce((acc, event) => {
          if (event.isAllDay) {
            if (acc.length === 0 || !Array.isArray(acc[acc.length - 1])) {
              acc.push([]);
            }
            // @ts-ignore
            acc[acc.length - 1].push(event);
          } else {
            acc.push(event);
          }
          return acc;
        }, [] as (Event | Event[])[])
        .map((event) => {
          // @ts-ignore
          let events: Event[] = [];
          if (Array.isArray(event)) {
            events = event;
          }
          const firstEvent: Event = Array.isArray(event) ? event[0] : event;
          const isNewDay =
            !last || !isSameDay(last, firstEvent.start, firstEvent.tz);
          last = firstEvent.start;
          return (
            <React.Fragment key={firstEvent.id}>
              {isNewDay && (
                <Paper style={{ position: "sticky", top: 0, zIndex: 99 }}>
                  <Title order={3}>
                    {formatDay(firstEvent.start, firstEvent.tz)}
                  </Title>
                </Paper>
              )}
              {events.length > 0 && (
                <Text fs="italic">{events.map((e) => e.name).join(", ")}</Text>
              )}
              {!firstEvent.isAllDay && <EventCard event={firstEvent} />}
            </React.Fragment>
          );
        })}
    </Stack>
  );
}

function responseColour(response: EventResponse | null) {
  switch (response) {
    case "accepted":
      return "var(--mantine-color-brand-filled)";
    case "declined":
      return "var(--mantine-color-secondary-filled)";
    default:
      return undefined;
  }
}

export default function EventCard({ event }: { event: Event }) {
  const [response, setResponseState] = useState(event.response || undefined);
  const responder = useEventResponder();
  const setResponse = useCallback(
    (checked: boolean) => {
      const response = checked ? "accepted" : "declined";
      setResponseState(response);
      const email = event.email;
      if (!email) throw new Error("Missing calendar email");
      responder(event.id, response, email, event.isOrganizer);
    },
    [event, responder]
  );
  return (
    <Card withBorder>
      <Stack>
        <Title order={3}>
          {event.name}{" "}
          {event.providerLink && (
            <Anchor target="_blank" href={event.providerLink}>
              <IconExternalLink />
            </Anchor>
          )}
        </Title>
        <Text>{formatTimes(event.start, event.end, event.tz)}</Text>
        <Box>
          <Chip checked={response === "accepted"} onChange={setResponse}>
            Attend
          </Chip>
        </Box>
        {event.invitees.length > 1 && (
          <Group gap="xs">
            {event.invitees.map(
              (invitee) =>
                !invitee.isSelf && (
                  <Badge
                    key={invitee.id}
                    color="gray"
                    tt="unset"
                    style={{ borderColor: responseColour(invitee.response) }}
                  >
                    {invitee.name}
                  </Badge>
                )
            )}
          </Group>
        )}
        {event.description && (
          <Box dangerouslySetInnerHTML={{ __html: event.description }} />
        )}
        {event.conferencingUrl && (
          <Group>
            <Button
              variant="light"
              component="a"
              target="_blank"
              href={event.conferencingUrl}
              fullWidth={false}
            >
              Join
            </Button>
          </Group>
        )}
        {event.labels.length > 0 && (
          <Group gap="xs">
            {event.labels.map((label) => (
              <Tooltip label={label.name ?? label.description} key={label.id}>
                <Badge color="gray" tt="unset">
                  {label.tag}
                </Badge>
              </Tooltip>
            ))}
          </Group>
        )}
      </Stack>
    </Card>
  );
}
