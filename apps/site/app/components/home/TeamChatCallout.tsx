import { Box, Container, Stack, Text, Title } from "@mantine/core";

import { useScrollReveal } from "~/hooks/useScrollReveal";

import classes from "./TeamChatCallout.module.css";

export function TeamChatCallout() {
  const revealRef = useScrollReveal<HTMLDivElement>();

  return (
    <Box
      className={`${classes.section} reveal`}
      pt={80}
      pb={80}
      ref={revealRef}
    >
      <Container size="lg">
        <div className={classes.card}>
          <Stack align="center" ta="center" gap="md">
            <Title order={2} size="h2" className={classes.sectionTitle}>
              Replace your team chat for free
            </Title>
            <Text className={classes.sectionBody} maw={600}>
              Plot has its own threads, with no external service required. Share
              them with anyone for full-featured team chat with reactions,
              tasks, and assignment. Completely free with no history or sharing
              limits.
            </Text>
          </Stack>
        </div>
      </Container>
    </Box>
  );
}
