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
  IconPlugConnected,
  IconRefresh,
  IconSparkles,
} from "@tabler/icons-react";
import { Link } from "react-router";

import type { Route } from "./+types/twists";
import classes from "./twists.module.css";

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Twists | Plot" },
    {
      name: "description",
      content:
        "Plot Twists bring your work from every app together, organized and prioritized. Integrations, automations, and custom workflows.",
    },
    { "og:title": "Plot Twists" },
    {
      "og:description":
        "Bring your work from every app together with Plot Twists.",
    },
    { "og:image": "https://plot.day/assets/p.png" },
    { "twitter:title": "Plot Twists" },
    {
      "twitter:description":
        "Bring your work from every app together with Plot Twists.",
    },
    { "twitter:image": "https://plot.day/assets/p.png" },
  ];
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
                Always have what you need to be productive
              </Text>
            </Title>
            <Text className={classes.heroSubtext}>
              Your work doesn't live in one app—it's scattered across email,
              calendars, project tools, documents, and AI assistants. Plot
              Twists automatically bring everything together, organized and
              prioritized exactly where you need it.
            </Text>
            <Button
              variant="gradient"
              size="lg"
              component={Link}
              to="/start"
            >
              Get started free
            </Button>
          </Stack>
        </Container>
      </Box>

      {/* Connections CTA */}
      <Box className={classes.graySection} pt={80} pb={80}>
        <Container size="lg">
          <Stack gap="xl" align="center">
            <Stack gap="md" ta="center" maw={700} mx="auto">
              <Title order={2} size="h2" className={classes.sectionTitle}>
                Connect the apps you already use
              </Title>
              <Text className={classes.sectionBody}>
                Plot Twists integrate with the tools your team relies on every
                day. Your calendar events, emails, tasks, and messages flow into
                Plot automatically—no manual updating required.
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

      {/* How Twists Work */}
      <Box className={classes.whiteSection} pt={80} pb={80}>
        <Container size="lg">
          <Stack gap="xl">
            <Stack gap="md" ta="center" maw={700} mx="auto">
              <Title order={2} size="h2" className={classes.sectionTitle}>
                How Twists work
              </Title>
              <Text className={classes.sectionBody}>
                No more jumping between apps. No more manually updating your
                to-do list. No more wondering if you missed something important.
              </Text>
            </Stack>
            <SimpleGrid cols={{ base: 1, md: 3 }} spacing="lg">
              <Stack className={classes.card} gap="md">
                <Flex c="brand">
                  <IconPlugConnected size={32} />
                </Flex>
                <Title order={3} size="h4">
                  Bring it all together
                </Title>
                <Text className={classes.sectionBody} fz="sm">
                  Enable pre-built integrations for the apps you use. Your
                  calendar events, emails, tasks, and messages sync into Plot
                  automatically.
                </Text>
              </Stack>
              <Stack className={classes.card} gap="md">
                <Flex c="brand">
                  <IconSparkles size={32} />
                </Flex>
                <Title order={3} size="h4">
                  Organized and prioritized
                </Title>
                <Text className={classes.sectionBody} fz="sm">
                  Twists don't just dump data into Plot. They organize and
                  prioritize your work so you always know what matters most and
                  what needs your attention.
                </Text>
              </Stack>
              <Stack className={classes.card} gap="md">
                <Flex c="brand">
                  <IconRefresh size={32} />
                </Flex>
                <Title order={3} size="h4">
                  Two-way sync
                </Title>
                <Text className={classes.sectionBody} fz="sm">
                  Changes flow both ways. Update a task in Plot and it updates
                  in Linear. Reply in Plot and it posts to Slack. Work where you
                  want, stay in sync everywhere.
                </Text>
              </Stack>
            </SimpleGrid>
          </Stack>
        </Container>
      </Box>

      {/* Build Twists */}
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
              Twists are easy to build. Create custom integrations and
              automations that work exactly how your team needs. The Twist
              Creator SDK gives you everything you need to get started.
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
              Stop juggling apps. Start making progress.
            </Title>
            <Text c="rgba(255,255,255,0.85)" fz="lg">
              Plot Twists eliminate the busywork of managing your productivity
              systems so you can focus on actual work.
            </Text>
            <Flex gap="md" wrap="wrap" justify="center">
              <Button
                variant="white"
                size="xl"
                component={Link}
                to="/start"
              >
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
