import React, { useCallback, useState } from "react";

import {
  Anchor,
  Badge,
  Box,
  Card,
  Center,
  Checkbox,
  Group,
  Paper,
  SegmentedControl,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import {
  IconBrandMicrosoftTeams,
  IconBrandZoom,
  IconExternalLink,
  IconPlayerPauseFilled,
  IconPlayerPlayFilled,
  IconPlayerStopFilled,
  IconUser,
  IconUserCheck,
  IconUserX,
  IconVideo,
} from "@tabler/icons-react";

import type { EventResponse } from "@plotday/cal";
import type { ConferencingProvider, Event } from "@plotday/db";
import { formatDay, formatTimes, isSameDay } from "@plotday/tz";

import { useEventWatch } from "app/event";
import { useEventReadyResponder } from "app/routes/api.event.ready";
import { useEventResponder } from "app/routes/api.response";

function conferencingProviderName(provider: ConferencingProvider) {
  switch (provider) {
    case "zoom":
      return "Zoom";
    case "meet":
      return "Google Meet";
    case "teams":
      return "Microsoft Teams";
    default:
      return "Video call";
  }
}

function ConferencingIcon({ provider }: { provider: ConferencingProvider }) {
  switch (provider) {
    case "zoom":
      return <IconBrandZoom size="1em" />;
    case "teams":
      return <IconBrandMicrosoftTeams size="1em" />;
    case "meet":
    default:
      return <IconVideo size="1em" />;
  }
}

function AttendeeIcon({ response }: { response: EventResponse | null }) {
  switch (response) {
    case "accepted":
      return (
        <Text c="brand" lh={0}>
          <IconUserCheck size="1em" />
        </Text>
      );
    case "declined":
      return (
        <Text c="secondary" lh={0}>
          <IconUserX size="1em" />
        </Text>
      );
    default:
      return (
        <Text lh={0}>
          <IconUser size="1em" />
        </Text>
      );
  }
}

export function EventList({
  events,
  review,
}: {
  events: Event[];
  review?: boolean;
}) {
  useEventWatch();

  let last: Date | undefined;
  return (
    <Box display="grid" style={{ gridTemplateColumns: "5.5rem 1fr" }}>
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
                <Paper
                  bg="var(--mantine-color-background)"
                  h="3rem"
                  style={{
                    position: "sticky",
                    top: 0,
                    zIndex: 99,
                    gridColumn: "1 / span 2",
                  }}
                >
                  <Title fw="normal" order={3}>
                    {formatDay(firstEvent.start, firstEvent.tz)}
                  </Title>
                </Paper>
              )}
              {events.length > 0 && (
                <Paper
                  bg="var(--mantine-color-background)"
                  mb="lg"
                  style={{
                    gridColumn: "1 / span 2",
                    zIndex: 98,
                  }}
                >
                  <Text fs="italic">
                    {events.map((e) => e.name).join(", ")}
                  </Text>
                </Paper>
              )}
              {!firstEvent.isAllDay && (
                <>
                  <Paper
                    bg="var(--mantine-color-background)"
                    w="6rem"
                    pr="xs"
                    style={{
                      position: "sticky",
                      top: "3rem",
                      alignSelf: "start",
                      flexGrow: 0,
                    }}
                  >
                    <Text size="sm">
                      {formatTimes(
                        firstEvent.start,
                        firstEvent.end,
                        firstEvent.tz
                      )}
                    </Text>
                  </Paper>
                  <EventCard event={firstEvent} review={review} />
                </>
              )}
            </React.Fragment>
          );
        })}
    </Box>
  );
}

export default function EventCard({
  event,
  review,
}: {
  event: Event;
  review?: boolean;
}) {
  const [response, setResponseState] = useState(event.response || undefined);
  const responder = useEventResponder();
  const setResponse = useCallback(
    (response: EventResponse) => {
      setResponseState(response);
      const email = event.email;
      if (!email) throw new Error("Missing calendar email");
      responder(event.id, response, email, event.isOrganizer);
    },
    [event, responder]
  );
  const [ready, setReady] = useState(review ? event.isReviewed : event.isReady);
  const eventReadyResponder = useEventReadyResponder();
  const updateReady = (ready: boolean) => {
    setReady(ready);
    if (event.providerId) {
      eventReadyResponder(
        event.providerId,
        review ? undefined : ready,
        review ? ready : undefined
      );
    }
  };
  return (
    <Card
      withBorder
      mb="lg"
      display="grid"
      style={{
        flexGrow: 1,
        gridTemplateColumns: "2.2rem repeat(auto-fit, minmax(12rem, 1fr))",
        rowGap: "1rem",
        borderColor: ready
          ? response === "accepted"
            ? "var(--mantine-color-brand-border)"
            : undefined
          : "var(--mantine-color-secondary-border)",
      }}
    >
      <Checkbox
        radius="xl"
        size="md"
        checked={ready}
        color={response === "accepted" ? "brand" : "gray"}
        styles={{
          input: {
            borderColor: ready
              ? undefined
              : "var(--mantine-color-secondary-filled)",
          },
        }}
        onChange={(event) => updateReady(event.currentTarget.checked)}
      />
      <Stack>
        <Title order={4} fw={response === "accepted" ? "bold" : "normal"}>
          {event.name}
        </Title>
        <Box>
          <SegmentedControl
            size="xs"
            data={[
              {
                label: (
                  <Center>
                    <IconPlayerPlayFilled size="1em" />
                    <Box ml={3}>{review ? "Attended" : "Attend"}</Box>
                  </Center>
                ),
                value: "accepted",
              },
              ...(review
                ? []
                : [
                    {
                      label: (
                        <Center>
                          <IconPlayerPauseFilled size="1em" />
                          <Box ml={3}>Only if needed</Box>
                        </Center>
                      ),
                      value: "tentative",
                    },
                  ]),
              {
                label: (
                  <Center>
                    <IconPlayerStopFilled size="1em" />
                    <Box ml={3}>{review ? "Skipped" : "Skip"}</Box>
                  </Center>
                ),
                value: "declined",
              },
            ]}
            value={response}
            onChange={setResponse}
          />
        </Box>
        {event.labels.length > 0 && (
          <Group gap="xs">
            {event.labels.map((label) => (
              <Badge key={label.id} color="gray" fw={500} tt="unset">
                {label.tag} {label.name}
              </Badge>
            ))}
          </Group>
        )}
      </Stack>
      <Stack gap="xs">
        {event.conferencingUrl && (
          <Group gap="xs">
            <ConferencingIcon
              provider={event.conferencingProvider || "other"}
            />
            <Anchor
              variant="light"
              component="a"
              target="_blank"
              href={event.conferencingUrl}
            >
              {conferencingProviderName(event.conferencingProvider || "other")}
            </Anchor>
          </Group>
        )}

        {event.providerLink && (
          <Group gap="xs">
            <IconExternalLink size="1em" />
            <Anchor target="_blank" href={event.providerLink}>
              View on calendar
            </Anchor>
          </Group>
        )}
      </Stack>
      <Stack gap="xs">
        {event.invitees.map(
          (invitee) =>
            !invitee.isSelf && (
              <Group key={invitee.id} wrap="nowrap" gap="xs">
                <AttendeeIcon response={invitee.response} />
                <Text truncate>{invitee.name}</Text>
              </Group>
            )
        )}
      </Stack>
    </Card>
  );
}
