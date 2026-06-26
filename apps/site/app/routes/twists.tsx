import {
  Box,
  Button,
  Container,
  Flex,
  SimpleGrid,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import {
  IconArrowRight,
  IconCode,
  IconFilter,
  IconMessageChatbot,
  IconSparkles,
} from "@tabler/icons-react";
import { Link } from "react-router";

import { mergeMeta } from "~/lib/meta";
import type { Route } from "./+types/twists";
import classes from "./twists.module.css";

export function meta(_: Route.MetaArgs) {
  return mergeMeta([
    { title: "Twists | Plot" },
    {
      name: "description",
      content:
        "Twists are optional extensions for Plot — automations, AI agents, and custom workflows that run securely inside your workspace, with per-permission consent. Install one, or build your own.",
    },
    { property: "og:title", content: "Plot Twists" },
    {
      property: "og:description",
      content:
        "Optional extensions for Plot — automations, AI agents, and custom workflows that run securely inside your workspace.",
    },
    { name: "twitter:title", content: "Plot Twists" },
    {
      name: "twitter:description",
      content:
        "Optional extensions for Plot — automations, AI agents, and custom workflows that run securely inside your workspace.",
    },
  ]);
}

export default function Twists() {
  return (
    <Stack gap={0}>
      {/* Hero */}
      <Box className={classes.heroSection} pt={60} pb={60}>
        <Container size="md">
          <Stack align="center" gap="lg" ta="center">
            <Title order={1} className={classes.heroTitle}>
              <Text span inherit variant="gradient">
                Extend Plot to fit
                <br />
                how you work
              </Text>
            </Title>
            <Text className={classes.heroSubtext}>
              Twists are optional extensions — automations, AI agents, and custom
              workflows — that run securely inside Plot, with per-permission
              consent you grant. Install one built by someone else, or build your
              own. You decide what they can do.
            </Text>
            <Button variant="gradient" size="lg" component={Link} to="/start">
              Get started free
            </Button>
          </Stack>
        </Container>
      </Box>

      {/* Connections callout */}
      <Box className={classes.graySection} pt={80} pb={80}>
        <Container size="lg">
          <Stack gap="xl" align="center">
            <Stack gap="md" ta="center" maw={700} mx="auto">
              <Title order={2} size="h2" className={classes.sectionTitle}>
                Powered by your connections
              </Title>
              <Text className={classes.sectionBody}>
                Twists work with everything you've connected to Plot — email,
                chat, calendars, and the tools where your projects live. They act
                on the conversations you choose, within the permissions you grant.
              </Text>
            </Stack>
            <Button
              variant="outline"
              size="lg"
              component={Link}
              to="/connections"
              rightSection={<IconArrowRight size={18} />}
            >
              See all connections
            </Button>
          </Stack>
        </Container>
      </Box>

      {/* What Twists do */}
      <Box className={classes.whiteSection} pt={80} pb={80}>
        <Container size="lg">
          <Stack gap="xl">
            <Stack gap="md" ta="center" maw={700} mx="auto">
              <Title order={2} size="h2" className={classes.sectionTitle}>
                What Twists do
              </Title>
            </Stack>
            <SimpleGrid cols={{ base: 1, md: 3 }} spacing="lg">
              <Stack className={classes.card} gap="md">
                <Flex c="brand">
                  <IconSparkles size={32} />
                </Flex>
                <Title order={3} size="h4">
                  Workflows & processes
                </Title>
                <Text className={classes.sectionBody} fz="sm">
                  Twists implement the workflows your team relies on — turning
                  incoming emails into tasks, routing threads to the right place,
                  keeping projects in sync. The repetitive parts run themselves,
                  so your time goes to your best work.
                </Text>
              </Stack>
              <Stack className={classes.card} gap="md">
                <Flex c="brand">
                  <IconFilter size={32} />
                </Flex>
                <Title order={3} size="h4">
                  Organize and surface
                </Title>
                <Text className={classes.sectionBody} fz="sm">
                  Not everything deserves your attention. Twists surface what
                  needs you, file the rest where it belongs, and keep newsletters
                  and noise from interrupting your day.
                </Text>
              </Stack>
              <Stack className={classes.card} gap="md">
                <Flex c="brand">
                  <IconMessageChatbot size={32} />
                </Flex>
                <Title order={3} size="h4">
                  AI chat & agents
                </Title>
                <Text className={classes.sectionBody} fz="sm">
                  Twists can bring AI right alongside your work — chat and agents
                  that draw on your threads, focuses, and connections for context.
                  When a twist uses AI, the cost is already included in its
                  capacity — no keys to bring and no models to configure.
                </Text>
              </Stack>
            </SimpleGrid>
          </Stack>
        </Container>
      </Box>

      {/* Build your own */}
      <Box className={classes.graySection} pt={80} pb={80}>
        <Container size="md">
          <Stack
            className={classes.buildSection}
            gap="md"
            align="center"
            ta="center"
          >
            <Flex c="brand">
              <IconCode size={40} />
            </Flex>
            <Title order={2} size="h3" className={classes.sectionTitle}>
              Build your own
            </Title>
            <Text className={classes.sectionBody}>
              The Twist Creator is a fully typed TypeScript SDK with CLI tooling
              and real-time logs — build a twist or connector and publish it to
              the open marketplace. Prefer no code? The visual builder on Pro and
              Team plans lets you assemble a workflow without writing any.
            </Text>
            <Button
              variant="outline"
              size="lg"
              component="a"
              href="https://twist.plot.day/"
              rightSection={<IconArrowRight size={18} />}
            >
              Twist Creator docs
            </Button>
          </Stack>
        </Container>
      </Box>

      {/* Final CTA */}
      <Box className={classes.ctaSection} pt={80} pb={80}>
        <Container size="sm">
          <Stack gap="lg" align="center" ta="center">
            <Title order={2} size="h2" className={classes.ctaTitle}>
              Shape Plot around how you work.
            </Title>
            <Text c="rgba(255,255,255,0.85)" fz="lg">
              Add a twist, or build your own — and decide exactly what it can do.
            </Text>
            <Flex gap="md" wrap="wrap" justify="center">
              <Button variant="white" size="xl" component={Link} to="/start">
                Get started free
              </Button>
              <Button
                variant="outline"
                size="xl"
                color="white"
                component={Link}
                to="/pricing"
              >
                See pricing
              </Button>
            </Flex>
          </Stack>
        </Container>
      </Box>
    </Stack>
  );
}
