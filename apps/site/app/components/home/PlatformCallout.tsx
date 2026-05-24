import { Anchor, Box, Container, Stack, Text, Title } from "@mantine/core";
import { Link } from "react-router";

import { useScrollReveal } from "~/hooks/useScrollReveal";
import classes from "./PlatformCallout.module.css";

export function PlatformCallout() {
  const revealRef = useScrollReveal<HTMLDivElement>();

  return (
    <Box className={`${classes.section} reveal`} pt={80} pb={80} ref={revealRef}>
      <Container size="lg">
        <div className={classes.card}>
          <Stack align="center" ta="center" gap="md">
            <Title order={2} size="h2" className={classes.sectionTitle}>
              Plot's Twist platform
            </Title>
            <Text className={classes.sectionBody} maw={560}>
              Twists are extensions that run securely inside your workspace —
              automations, integrations, and AI workflows that route
              conversations, pull in context from your other tools, and help you
              keep things moving. Install twists built by others, or build your
              own with Plot's open SDK.
            </Text>
            <Anchor component={Link} to="/twists" className={classes.link}>
              Explore Twists →
            </Anchor>
          </Stack>
        </div>
      </Container>
    </Box>
  );
}
