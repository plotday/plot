import { useEffect, useState } from "react";

import {
  Box,
  Button,
  Container,
  Group,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import {
  IconCalendarEvent,
  IconCircleCheck,
  IconMail,
} from "@tabler/icons-react";
import { Link, useSearchParams } from "react-router";
import { mergeMeta } from "~/lib/meta";

import type { Route } from "./+types/go.thanks";
import classes from "./go.module.css";

export function meta(_: Route.MetaArgs) {
  return mergeMeta([
    { title: "You're booked — Plot" },
    {
      name: "description",
      content:
        "Thanks for booking your onboarding session with Plot. Install Plot before we meet.",
    },
    { property: "og:title", content: "You're booked — Plot" },
    {
      property: "og:description",
      content:
        "Thanks for booking your onboarding session with Plot. Install Plot before we meet.",
    },
    { name: "robots", content: "noindex" },
  ]);
}

function formatBookingTime(iso: string): string | null {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return new Intl.DateTimeFormat(undefined, {
    weekday: "long",
    month: "long",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short",
  }).format(date);
}

export default function GoThanks() {
  const [searchParams] = useSearchParams();
  const dateParam = searchParams.get("date") ?? searchParams.get("startTime");
  const email = searchParams.get("email");
  const name =
    searchParams.get("name") ?? searchParams.get("attendeeName") ?? null;
  const firstName = name?.split(" ")[0] ?? null;

  // Format the booking time on the client only — server-rendered
  // formatting would use the worker's timezone and mismatch on hydration.
  const [bookingTime, setBookingTime] = useState<string | null>(null);
  useEffect(() => {
    if (dateParam) setBookingTime(formatBookingTime(dateParam));
  }, [dateParam]);

  return (
    <Stack gap={0}>
      <Box className={classes.heroSection} pt={80} pb={80}>
        <div className={classes.heroGlow} />
        <Container size="sm">
          <Stack gap="xl" align="center" ta="center">
            <IconCircleCheck
              size={64}
              stroke={1.5}
              color="var(--mantine-color-brand-6)"
            />
            <Text className={classes.heroEyebrow}>You&rsquo;re booked</Text>
            <Title order={1} className={classes.heroTitle}>
              <Text span inherit variant="gradient">
                {firstName ? `Thanks, ${firstName}!` : "See you soon!"}
              </Text>
            </Title>

            {(bookingTime || email) && (
              <Stack gap="sm" align="center" className={classes.body}>
                {bookingTime && (
                  <Group gap="xs" align="center" justify="center" wrap="nowrap">
                    <IconCalendarEvent
                      size={20}
                      stroke={1.5}
                      color="var(--mantine-color-brand-6)"
                    />
                    <Text fw={600}>{bookingTime}</Text>
                  </Group>
                )}
                {email && (
                  <Group gap="xs" align="center" justify="center" wrap="nowrap">
                    <IconMail
                      size={20}
                      stroke={1.5}
                      color="var(--mantine-color-brand-6)"
                    />
                    <Text>{email}</Text>
                  </Group>
                )}
              </Stack>
            )}

            <Text className={classes.lead}>
              We&rsquo;ve sent a confirmation with a calendar invite
              {email ? " to your inbox" : ""}.
            </Text>

            <div className={classes.divider} />

            <Text className={classes.body}>
              To make the most of our time, install Plot to your devices before
              we meet.
            </Text>
            <Button
              size="xl"
              component={Link}
              to="/start"
              className={classes.bookCta}
            >
              Get Plot
            </Button>
          </Stack>
        </Container>
      </Box>
    </Stack>
  );
}
