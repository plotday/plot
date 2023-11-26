import React, { memo, useMemo } from "react";

import {
  Avatar,
  Button,
  Card,
  Group,
  Progress,
  Stack,
  Text,
  Tooltip,
} from "@mantine/core";

import {
  IconBrandMicrosoftTeams,
  IconBrandZoom,
  IconCheck,
  IconCircleCheck,
  IconCircleX,
  IconClipboardList,
  IconNote,
  IconVideo,
  IconX,
} from "@tabler/icons-react";

import type {
  ConferencingProvider,
  DbCategories,
  Event,
  Invitee,
} from "@plotday/db";
import { formatDate, formatDuration, formatTime } from "@plotday/tz";

import { Categorizer } from "app/components/categorizer";
import { useEventResponder } from "app/routes/api.event.response";

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

function initials(name: string) {
  let names;
  if (name.includes("@")) {
    names = name.toUpperCase().split("@")[0].split(".");
  } else {
    names = name.toUpperCase().split(" ");
  }
  let initials = names[0][0];
  if (names.length > 1) {
    initials += names[names.length - 1][0];
  }
  return initials;
}

function InviteeAvatar({ invitee }: { invitee: Invitee }) {
  const generatedInitials = useMemo(
    () => initials(invitee?.name || invitee?.email || "?"),
    [invitee]
  );
  const color =
    invitee.response === "accepted"
      ? "var(--mantine-color-brand-filled)"
      : invitee.response === "declined"
      ? "var(--mantine-color-secondary-filled)"
      : "var(--mantine-color-neutral)";
  return (
    <Tooltip
      key={invitee.email}
      label={`${invitee.name || invitee.email} ${
        invitee.response === "accepted"
          ? " ✅"
          : invitee.response === "declined"
          ? " ❌"
          : ""
      }`}
      withArrow
    >
      <Avatar
        src={invitee.avatar || undefined}
        imageProps={{ referrerPolicy: "no-referrer" }}
        alt={invitee.name || undefined}
        style={{
          border: `2px solid ${color}`,
        }}
        color={
          invitee.response === "accepted"
            ? "brand"
            : invitee.response === "declined"
            ? "secondary.7"
            : undefined
        }
      >
        {generatedInitials}
      </Avatar>
    </Tooltip>
  );
}

function KeyPerson({
  invitees,
  organizer,
}: {
  invitees: Invitee[];
  organizer?: Invitee;
}) {
  const p = useMemo(() => {
    return invitees.find((i) => i.email === organizer?.email);
  }, [organizer, invitees]);

  if (!p) {
    return null;
  }
  return <InviteeAvatar invitee={p} />;
}

const InviteeSummary = memo(function InviteeSummary({
  invitees,
  organizer,
}: {
  invitees: Invitee[];
  organizer?: Invitee;
}) {
  const others = useMemo(
    () =>
      invitees
        .filter((i) => !i.isSelf && i.email !== organizer?.email)
        .map((i) => ({ ...i, initials: initials(i.name || i.email || "?") })),
    [invitees, organizer]
  );
  if (others.length === 0) return null;
  return (
    <Tooltip.Group>
      <Avatar.Group>
        {others.map((invitee) => (
          <InviteeAvatar invitee={invitee} key={invitee.email} />
        ))}
      </Avatar.Group>
    </Tooltip.Group>
  );
});

export function EventCard({
  event,
  minimize,
  categories,
  totalTime,
}: {
  event: Event;
  minimize?: boolean;
  categories: DbCategories;
  totalTime?: number;
}) {
  const eventResponder = useEventResponder(event);
  return (
    <Card withBorder maw={800}>
      {!!totalTime && (
        <Card.Section mb="sm">
          <Progress.Root size={18} radius={0}>
            <Progress.Section
              value={(event.duration / totalTime) * 100}
              color={minimize ? "secondary" : "brand"}
            >
              <Progress.Label c="var(--mantine-color-default)" lh="unset">
                {formatDuration(event.duration)}
              </Progress.Label>
            </Progress.Section>
          </Progress.Root>
        </Card.Section>
      )}

      <Group justify="space-between">
        <Group>
          <Button.Group>
            <Button
              size="xs"
              variant={event.response === "accepted" ? "outline" : "subtle"}
              onClick={() => eventResponder("accepted")}
            >
              <IconCheck size={16} />
            </Button>
            <Button
              size="xs"
              variant={event.response === "declined" ? "outline" : "subtle"}
              onClick={() => eventResponder("declined")}
            >
              <IconX size={16} />
            </Button>
          </Button.Group>
          {event.type === "task" ? (
            <Avatar alt="Task">
              <IconClipboardList color="var(--mantine-color-dimmed)" />
            </Avatar>
          ) : event.type === "note" ? (
            <Avatar alt="Note">
              <IconNote color="var(--mantine-color-dimmed)" />
            </Avatar>
          ) : (
            <KeyPerson invitees={event.invitees} organizer={event.organizer} />
          )}
          <Stack gap={0}>
            <Text fw={event.response === "accepted" ? "bold" : "normal"}>
              {event.name}
            </Text>
            <Group>
              <Text size="sm" c="dimmed">
                {formatDate(event.start, event.tz, "cccc, ")}
                {formatTime(event.start, event.tz)}
              </Text>
            </Group>
          </Stack>
          <InviteeSummary
            invitees={event.invitees}
            organizer={event.organizer}
          />
        </Group>
        <Categorizer event={event} categories={categories} />
      </Group>
    </Card>
  );
}
