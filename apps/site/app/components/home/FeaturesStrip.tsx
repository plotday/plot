import { Box, Container, Stack, Text, Title } from "@mantine/core";

import {
  IconCloudOff,
  IconDevices,
  IconSparkles,
  IconUsers,
} from "@tabler/icons-react";

import classes from "./FeaturesStrip.module.css";

const FEATURES = [
  {
    icon: IconDevices,
    label: "Everywhere you work",
    description:
      "Mac, Windows, iOS, Android, and web. Sometimes the best way to clear your head is to put important thoughts where you know you'll see them later.",
  },
  {
    icon: IconCloudOff,
    label: "Even when you're offline",
    description:
      "Everything's available whether or not you've got (or want) coverage. Full sync when you're back online.",
  },
  {
    icon: IconUsers,
    label: "Made for high-agency teams",
    description:
      "Share priorities. No per-seat fees holding back collaboration. Plot is the coordination layer that empowers everyone to do their best work.",
  },
  {
    icon: IconSparkles,
    label: "AI that minds its business",
    description:
      "Chat with Claude, ChatGPT, and Gemini right where your work lives — with full context. BYOK, set a budget, or turn AI off entirely. It's your call.",
  },
];

export function FeaturesStrip() {
  return (
    <Box className={classes.strip} pt={80} pb={80}>
      <Container size="lg">
        <Title
          order={2}
          size="h2"
          className={classes.headline}
          ta="center"
          mb="xl"
        >
          Also true
        </Title>
        <div className={classes.grid}>
          {FEATURES.map((feature) => (
            <Stack key={feature.label} gap="xs">
              <feature.icon size={24} className={classes.icon} />
              <Text fw={600}>{feature.label}</Text>
              <Text size="sm" c="dimmed">
                {feature.description}
              </Text>
            </Stack>
          ))}
        </div>
      </Container>
    </Box>
  );
}
