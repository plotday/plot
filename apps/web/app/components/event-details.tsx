import { useCallback, useMemo, useState } from "react";

import { Link } from "@remix-run/react";

import { Button, Card, Chip, Group, Stack, Title } from "@mantine/core";

import {
  IconBrandMicrosoftTeams,
  IconBrandZoom,
  IconChevronLeft,
  IconExternalLink,
  IconVideo,
} from "@tabler/icons-react";
import classes from "css/event.module.css";

import type { Attendance, ConferencingProvider, Event } from "@plotday/db";

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

function ConferencingButton({ event }: { event: Event }) {
  if (!event.conferencing) return null;
  return (
    <Button
      component="a"
      href={event.conferencing.url}
      target="_blank"
      variant="outline"
      fullWidth={false}
      leftSection={<ConferencingIcon provider={event.conferencing.provider} />}
      style={{ alignSelf: "flex-start" }}
    >
      Join {conferencingProviderName(event.conferencing.provider)}
    </Button>
  );
}

export function EventDetails({ event }: { event: Event }) {
  const eventResponder = useEventResponder(event);
  const eventReadyResponder = useEventReadyResponder(event);
  const setAttendance = useCallback(
    (attendance: string | null) => {
      setAttendanceState((oldAttendance) => {
        if (oldAttendance === attendance) {
          attendance = null;
        }
        eventResponder(attendance as Attendance);
        return attendance as Attendance;
      });
    },
    [eventResponder]
  );
  const review = event.start.getTime() < Date.now();

  const ready = review ? event.isReviewed : event.isReady;
  const updateReady = useCallback(
    (ready: boolean) => {
      eventReadyResponder(
        review ? undefined : ready,
        review ? ready : undefined
      );
    },
    [eventReadyResponder, review]
  );

  const [attendance, setAttendanceState] = useState(event.attendance);
  const attendanceOptions = [
    {
      value: "attend",
      label: review ? "Attended" : "Attend",
    },
    { value: "skip", label: review ? "Skipped" : "Skip" },
  ];

  const description = useMemo(() => {
    let description = event.description;
    if (!description) return null;
    if (description.includes("</") || description.includes("/>")) {
      return description;
    }
    description = description.replace(
      /(https?:\/\/[^\s]+)/g,
      '<a href="$1">$1</a>'
    );
    description = description.replace(/\n/g, "<br/>");
    return description;
  }, [event.description]);

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
          <Title order={2}>{event.name}</Title>
          {event.providerLink && (
            <Button
              component="a"
              href={event.providerLink}
              target="_blank"
              variant="subtle"
              pl={0}
              pr={0}
            >
              <IconExternalLink />
            </Button>
          )}
        </Group>
        {event.type === "meeting" && (
          <Group>
            <Chip
              checked={ready}
              onChange={() => updateReady(!ready)}
              size="lg"
              radius="sm"
              variant="light"
            >
              {review ? "Reviewed" : "Ready"}
            </Chip>
            <Button.Group>
              {attendanceOptions.map((item) => (
                <Button
                  key={item.value}
                  variant="light"
                  color={attendance === item.value ? "brand" : "gray"}
                  onClick={() => setAttendance(item.value)}
                >
                  {item.label}
                </Button>
              ))}
            </Button.Group>
          </Group>
        )}
        <ConferencingButton event={event} />
        {description && (
          <div dangerouslySetInnerHTML={{ __html: description }} />
        )}
      </Stack>
    </Card>
  );
}
