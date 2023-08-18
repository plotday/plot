import React, { useState } from "react";

import type { V2_MetaFunction } from "@remix-run/react";
import { Form } from "@remix-run/react";

import {
  Box,
  Button,
  Container,
  Group,
  Input,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import {
  IconCalendarCheck,
  IconMail,
  IconScaleOutline,
  IconShieldCheckered,
} from "@tabler/icons-react";

import { Balance } from "app/components/balance";
import { APP_NAME } from "app/config";

import classes from "./_public._index.module.css";

export const meta: V2_MetaFunction = () => {
  return [
    {
      title: `${APP_NAME} | A calendar for those who want to be better than busy`,
    },
    {
      name: "description",
      content:
        "Plot is a calendar that actively reduces your meeting load so you can engage well while making progress on what matters most.",
    },
    {
      "og:image": "https://plot.day/assets/p.png",
    },
    {
      "twitter:title": "Plot",
    },
    {
      "twitter:description":
        "A calendar for those who want to be better than busy",
    },
    {
      "twitter:image": "https://plot.day/assets/p.png",
    },
  ];
};

function Waitlist() {
  return (
    <Form method="post" action="/waitlist">
      <Group grow>
        <Input
          name="email"
          type="email"
          placeholder="Your work email"
          required
          leftSection={<IconMail size={16} />}
          maw="unset"
        />
        <Button type="submit" variant="gradient" maw="unset">
          Join the waitlist
        </Button>
      </Group>
    </Form>
  );
}

function BulletPoint({
  icon,
  children,
}: {
  icon: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <Group gap="sm" wrap="nowrap">
      <Box display="flex" c="secondary">
        {icon}
      </Box>
      <Text>{children}</Text>
    </Group>
  );
}

export default function Index() {
  const [target, setTarget] = useState(16);

  return (
    <Stack gap={0}>
      <Box pt={44} pb={60} className={classes.heroSection}>
        <Container size="xs">
          <Stack gap="xl">
            <Title order={2} className={classes.title}>
              <Text span inherit variant="gradient">
                Better
              </Text>{" "}
              than busy
            </Title>

            <Text>
              Plot is a calendar that{" "}
              <Text span variant="gradient" fw={600}>
                reduces meeting overload
              </Text>{" "}
              so you can engage well while making progress on what moves you
              forward.
            </Text>
            <Stack>
              <Waitlist />
              <Text c="dimmed" fz="xs">
                We're currently onboarding early adopters personally to ensure
                we deliver on the level of transformation we intend.
              </Text>
            </Stack>
          </Stack>
        </Container>
      </Box>
      <Box pt="xl" pb="xl" className={classes.graySection}>
        <Container size="xl">
          <Stack>
            <Title order={3} size="h1">
              What is your{" "}
              <Text span inherit variant="gradient">
                ideal
              </Text>{" "}
              work week?
            </Title>
            <Balance target={target} onChange={setTarget} />
          </Stack>
        </Container>
      </Box>
      <Box pt="xl" pb="xl" className={classes.punchSection}>
        <Container size="xs">
          <Stack>
            <Title order={3} size="h1">
              A calendar that works for you
            </Title>
            <Stack gap="xs">
              <BulletPoint icon={<IconShieldCheckered />}>
                Find and protect time for what matters
              </BulletPoint>
              <BulletPoint icon={<IconCalendarCheck />}>
                Always prepared, with 100% follow-through
              </BulletPoint>
              <BulletPoint icon={<IconScaleOutline />}>
                Put meetings on a diet with clever alternatives
              </BulletPoint>
            </Stack>
            <Box mt="lg" mb="lg">
              <Waitlist />
            </Box>
          </Stack>
        </Container>
      </Box>
    </Stack>
  );
}
