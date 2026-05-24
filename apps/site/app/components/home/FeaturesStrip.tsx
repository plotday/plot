import { Box, Container, Stack, Text, Title } from "@mantine/core";

import {
  IconCloudOff,
  IconDevices,
  IconKeyboard,
  IconSparkles,
  IconUsers,
} from "@tabler/icons-react";

import { useScrollReveal } from "~/hooks/useScrollReveal";
import classes from "./FeaturesStrip.module.css";

const FEATURES = [
  {
    icon: IconDevices,
    label: "Everywhere you work",
    description:
      "Mac, Windows, iOS, Android, and web. Wherever the next reply needs to happen.",
  },
  {
    icon: IconCloudOff,
    label: "Even when you're offline",
    description:
      "Read, reply, or jot a note without coverage. Full sync when you're back online.",
  },
  {
    icon: IconUsers,
    label: "Built for teams moving fast together",
    description:
      "No per-seat fees. Bring everyone in without thinking twice — Plot works alongside the chat you already use.",
  },
  {
    icon: IconKeyboard,
    label: "Fast keyboard navigation",
    description:
      "Cmd-K, keyboard shortcuts, and full keyboard navigation. Fly through your work and get where you need to be.",
  },
  {
    icon: IconSparkles,
    label: "AI that minds its business",
    description:
      "Chat with Claude, ChatGPT, and Gemini right where your work lives — with full context. BYOK, set a budget, or turn AI off entirely. It's your call.",
  },
];

export function FeaturesStrip() {
  const revealRef = useScrollReveal<HTMLDivElement>();

  return (
    <Box className={`${classes.strip} reveal`} pt={80} pb={80} ref={revealRef}>
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
          {FEATURES.map((feature, i) => (
            <div
              key={feature.label}
              className={classes.card}
              style={{ transitionDelay: `${i * 50}ms` }}
            >
              <Stack gap="xs">
                <div className={classes.iconWrap}>
                  <feature.icon size={20} className={classes.icon} />
                </div>
                <Text fw={600}>{feature.label}</Text>
                <Text size="sm" className={classes.description}>
                  {feature.description}
                </Text>
              </Stack>
            </div>
          ))}
        </div>
      </Container>
    </Box>
  );
}
