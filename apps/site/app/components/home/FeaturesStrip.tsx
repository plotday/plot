import { Anchor, Box, Container, Stack, Text, Title } from "@mantine/core";

import {
  IconCloudOff,
  IconDevices,
  IconKeyboard,
  IconPuzzle,
  IconSparkles,
} from "@tabler/icons-react";
import { Link } from "react-router";
import { useScrollReveal } from "~/hooks/useScrollReveal";

import classes from "./FeaturesStrip.module.css";

interface Feature {
  icon: typeof IconDevices;
  label: string;
  description: string;
  to?: string;
}

const FEATURES: Feature[] = [
  {
    icon: IconDevices,
    label: "Everywhere you work",
    description:
      "Mac, Windows, iOS, Android, and web — one experience, with native touches on each.",
  },
  {
    icon: IconCloudOff,
    label: "Offline and synced",
    description:
      "Read, write, and organize without a connection. Everything syncs the moment you're back online.",
  },
  {
    icon: IconKeyboard,
    label: "Fast and keyboard-driven",
    description:
      "A command modal, keyboard shortcuts, and drag-and-drop everywhere. Move through your work without lifting your hands.",
  },
  {
    icon: IconSparkles,
    label: "AI your way",
    description:
      "Use AI as much or as little as you want. You can bring your own key, point it at your own model, or turn it off entirely.",
  },
  {
    icon: IconPuzzle,
    label: "Customize and extend",
    description:
      "Extend Plot with twists — automations and AI agents that run securely, with permission-based access to your data.",
    to: "/twists",
  },
];

export function FeaturesStrip() {
  const revealRef = useScrollReveal<HTMLDivElement>();

  return (
    <Box className={`${classes.strip} reveal`} pt={80} pb={80} ref={revealRef}>
      <Container size="lg">
        <Stack gap="xs" align="center" ta="center" mb="xl">
          <Title order={2} size="h2" className={classes.headline}>
            Work your way
          </Title>
          <Text className={classes.intro} maw={540}>
            Plot fits around how you actually work.
          </Text>
        </Stack>
        <div className={classes.grid}>
          {FEATURES.map((feature, i) => {
            const inner = (
              <Stack gap="xs">
                <div className={classes.iconWrap}>
                  <feature.icon size={20} className={classes.icon} />
                </div>
                <Text fw={600}>{feature.label}</Text>
                <Text size="sm" className={classes.description}>
                  {feature.description}
                </Text>
              </Stack>
            );

            return feature.to ? (
              <Anchor
                key={feature.label}
                component={Link}
                to={feature.to}
                underline="never"
                className={classes.card}
                style={{ transitionDelay: `${i * 50}ms` }}
              >
                {inner}
              </Anchor>
            ) : (
              <div
                key={feature.label}
                className={classes.card}
                style={{ transitionDelay: `${i * 50}ms` }}
              >
                {inner}
              </div>
            );
          })}
        </div>
      </Container>
    </Box>
  );
}
