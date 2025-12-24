import { Card, Container, Group, Stack, Text, Title } from "@mantine/core";

import { Link } from "react-router";

import type { Route } from "./+types/help";
import classes from "./help.module.css";

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Help Center | Plot" },
    {
      name: "description",
      content:
        "Get help with Plot - Getting started, FAQs, and support resources",
    },
  ];
}

export default function Help() {
  return (
    <Container mt="lg" mb="xl">
      <Stack gap="xl">
        <div>
          <Title order={1}>Help Center</Title>
          <Text c="dimmed" mt="sm">
            Find answers and get support to make the most of Plot.
          </Text>
        </div>

        <Group grow align="stretch">
          <Card
            component={Link}
            to="/help/getting-started"
            padding="lg"
            radius="md"
            withBorder
            className={classes.card}
          >
            <Title order={3} mb="xs">
              Getting Started
            </Title>
            <Text size="sm" c="dimmed">
              Get up and running quickly
            </Text>
          </Card>

          <Card
            component={Link}
            to="/help/faqs"
            padding="lg"
            radius="md"
            withBorder
            className={classes.card}
          >
            <Title order={3} mb="xs">
              FAQs
            </Title>
            <Text size="sm" c="dimmed">
              Common questions and answers about Plot features and functionality
            </Text>
          </Card>

          <Card
            component={Link}
            to="/help/contact"
            padding="lg"
            radius="md"
            withBorder
            className={classes.card}
          >
            <Title order={3} mb="xs">
              Contact Us
            </Title>
            <Text size="sm" c="dimmed">
              Get in touch for personalized assistance
            </Text>
          </Card>
        </Group>
      </Stack>
    </Container>
  );
}
