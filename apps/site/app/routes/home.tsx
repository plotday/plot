import { useState } from "react";

import {
  Box,
  Button,
  Container,
  Flex,
  List,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import {
  IconCalendarBolt,
  IconScaleOutline,
  IconShieldCheckered,
} from "@tabler/icons-react";
import { Link } from "react-router";

import { Balance } from "../components/balance";
import type { Route } from "./+types/home";
import classes from "./home.module.css";

export function meta({}: Route.MetaArgs) {
  return [
    {
      title: `Plot | Traction on Your Priorities`,
    },
    {
      name: "description",
      content:
        "Plot is a workspace that pulls in everything from all your apps, chats, and agents, and organizes them around your roles and goals. When you choose a focus, everything you need is in one place so you make steady progress on what matters to you.",
    },
    {
      "og:image": "https://plot.day/assets/p.png",
    },
    {
      "twitter:title": "Plot",
    },
    {
      "twitter:description": "Traction on Your Priorities",
    },
    {
      "twitter:image": "https://plot.day/assets/p.png",
    },
  ];
}

export default function Home({ loaderData }: Route.ComponentProps) {
  const [target, setTarget] = useState(16);

  return (
    <Stack gap={0}>
      <Box pt={44} pb={60} className={classes.heroSection}>
        <Container size="xs">
          <Stack gap="xl">
            <Title order={2} className={classes.title}>
              <Text span inherit variant="gradient">
                Better than busy
              </Text>
            </Title>

            <Text fz={18}>
              Plot is a focused workspace that{" "}
              <Text span variant="gradient" fw={600} fz={18}>
                drives progress on your priorities
              </Text>{" "}
              while keeping you on top of everything else.
            </Text>
          </Stack>
        </Container>
      </Box>
      <Box pt="xl" pb="xl" className={classes.graySection}>
        <Container size="xl">
          <Stack gap="md">
            <Title order={3} size="h1">
              Where do you want to{" "}
              <Text span inherit variant="gradient">
                invest your time
              </Text>
              ?
            </Title>
            <Balance target={target} onChange={setTarget} />
          </Stack>
        </Container>
      </Box>
      <Box pt="xl" pb="xl" className={classes.punchSection}>
        <Container size="xs">
          <Stack gap="md">
            <Title order={3} size="h1">
              Productivity that works for you
            </Title>
            <Stack gap="xs">
              <List center spacing="sm">
                <List.Item
                  lh={1.2}
                  icon={
                    <Flex c="secondary">
                      <IconCalendarBolt />
                    </Flex>
                  }
                >
                  Clarity on the next most important activity, even on days that
                  don't unfold as planned
                </List.Item>
                <List.Item
                  lh={1.2}
                  icon={
                    <Flex c="secondary">
                      <IconScaleOutline />
                    </Flex>
                  }
                >
                  Put time-consuming activities like meetings and email on a
                  diet
                </List.Item>
                <List.Item
                  lh={1.2}
                  icon={
                    <Flex c="secondary">
                      <IconShieldCheckered />
                    </Flex>
                  }
                >
                  Protect your focus while being confident nothing will get
                  dropped
                </List.Item>
              </List>
            </Stack>
            <Box mt="lg" mb="lg">
              <Button variant="gradient" component={Link} to="/start" w="100%">
                Get Started
              </Button>
            </Box>
          </Stack>
        </Container>
      </Box>
    </Stack>
  );
}
