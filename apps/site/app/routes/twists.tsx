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
        "Plot Twists are automations and AI agents that work with you, your team, and your connections. Workflows, organization, and AI — built into your work.",
    },
    { "og:title": "Plot Twists" },
    {
      "og:description":
        "Automations and AI agents that work with you, your team, and your connections.",
    },
    { "twitter:title": "Plot Twists" },
    {
      "twitter:description":
        "Automations and AI agents that work with you, your team, and your connections.",
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
                Automations and agents
                <br />
                that work with you
              </Text>
            </Title>
            <Text className={classes.heroSubtext}>
              Twists are the automations and AI agents that work alongside you,
              your team, and everything you've connected to Plot. They implement
              workflows, filter and organize what needs your attention, and
              bring AI into your work.
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
                Twists work with everything you've connected to Plot — your
                calendar, email, project tools, and more. They act on what's
                flowing in, so you don't have to.
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
                  Twists implement the workflows and processes your team relies
                  on. From triaging incoming emails to routing tasks, they
                  handle the repetitive work so you can focus on what matters.
                </Text>
              </Stack>
              <Stack className={classes.card} gap="md">
                <Flex c="brand">
                  <IconFilter size={32} />
                </Flex>
                <Title order={3} size="h4">
                  Filter, organize, prioritize
                </Title>
                <Text className={classes.sectionBody} fz="sm">
                  Not everything needs your attention. Twists surface what's
                  important, organize it where it belongs, and keep noise out of
                  your way.
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
                  Bring AI directly into your work. Twists power chat and agents
                  that understand your priorities, your connections, and your
                  context.
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
              Build your own Twists
            </Title>
            <Text className={classes.sectionBody}>
              Create custom automations that work exactly how your team needs.
              Add twists built by others, or use the Twist Creator SDK to build
              your own.
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
              Your team, your tools, your workflow.
            </Title>
            <Text c="rgba(255,255,255,0.85)" fz="lg">
              Twists bring automation and AI to everything you do in Plot.
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
