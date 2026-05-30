import {
  Box,
  Button,
  Container,
  Flex,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import { IconCheck } from "@tabler/icons-react";
import { Link } from "react-router";
import { BenefitSection } from "~/components/home/BenefitSection";
import { FeaturesStrip } from "~/components/home/FeaturesStrip";
import { PlatformCallout } from "~/components/home/PlatformCallout";
import { useScrollReveal } from "~/hooks/useScrollReveal";
import { mergeMeta } from "~/lib/meta";

import type { Route } from "./+types/home";
import classes from "./home.module.css";

export function meta(_: Route.MetaArgs) {
  return mergeMeta([
    { title: "Plot | Your best work every day" },
    {
      name: "description",
      content:
        "Plot brings together everything you need to know, respond to, and do, organized and prioritized. The best of the day stays yours.",
    },
    { name: "twitter:title", content: "Plot — Your best work every day" },
    {
      name: "twitter:description",
      content:
        "Every conversation in its place. Email, chat, and messages from the tools you use — organized and prioritized.",
    },
  ]);
}

export default function Home() {
  const ctaRevealRef = useScrollReveal<HTMLDivElement>();

  return (
    <Stack gap={0}>
      {/* Hero */}
      <Box className={classes.heroSection} pt={80} pb={80}>
        <div className={classes.heroGlow} />
        <Container size="md">
          <Stack align="center" gap="lg" ta="center">
            <div className={classes.heroBadge}>
              <span className={classes.heroBadgeDot} />
              Now available on all platforms
            </div>
            <Title order={1} className={classes.heroTitle}>
              <Text span inherit variant="gradient">
                Your best work every day
              </Text>
            </Title>
            <Text className={classes.heroSubtext}>
              Every conversation in its place.
              <br />
              The best of the day stays yours.
            </Text>
            <Flex gap="md" wrap="wrap" justify="center">
              <Button
                size="lg"
                component={Link}
                to="/start"
                className={classes.heroCta}
              >
                Try Plot
              </Button>
              <Button
                variant="subtle"
                size="lg"
                component="a"
                href="#benefits"
                onClick={(e: React.MouseEvent<HTMLAnchorElement>) => {
                  e.preventDefault();
                  document
                    .getElementById("benefits")
                    ?.scrollIntoView({ behavior: "smooth" });
                }}
              >
                Learn more &darr;
              </Button>
            </Flex>
          </Stack>
        </Container>
        <Container size="lg" mt={48}>
          <div className={classes.heroScreenshotWrap}>
            <div className={classes.heroScreenshotGlow} />
            <picture>
              <source
                srcSet="/assets/screenshot-d.webp"
                type="image/webp"
                media="(prefers-color-scheme: dark)"
              />
              <source
                srcSet="/assets/screenshot-d.png"
                media="(prefers-color-scheme: dark)"
              />
              <source srcSet="/assets/screenshot.webp" type="image/webp" />
              <img
                src="/assets/screenshot.png"
                alt="Plot interface showing conversations from email and chat organized by project and priority"
                className={classes.heroScreenshot}
              />
            </picture>
          </div>
        </Container>
      </Box>

      <Box id="benefits" />
      <BenefitSection
        label="One place to keep up"
        title="Every conversation, ready when you are"
        body="Email, team chat, and the comment threads in the tools where your real work happens — Plot pulls them into one place. Newsletters, automated messages, and admin noise stay out. What's left is what actually needs you."
        image="/assets/activity.png"
        imageDark="/assets/activity-d.png"
        imageAlt="Plot activity view showing conversations from email, chat, and project tools"
      />
      <BenefitSection
        label="Organized and prioritized"
        title="Know what to pick up next"
        body="Conversations land in the projects, relationships, and areas they belong to — sorted by what's important and what's urgent. You always know where to look, who's waiting on you, and what to move forward next. Nothing slips."
        image="/assets/priorities.png"
        imageDark="/assets/priorities-d.png"
        imageAlt="Plot focuses view showing conversations grouped by project and area"
        reverse
        background="gray"
      />
      <BenefitSection
        label="The best of the day stays yours"
        title="Keep moving on the real work"
        body="Plot bounds your inbox time to deliberate windows, so you can respond and then carry on with the work only you can do. Urgent things still surface; the rest waits its turn. You ship more and end the day on something that mattered."
        image="/assets/agenda.png"
        imageDark="/assets/agenda-d.png"
        imageAlt="Plot agenda view showing a focused window for replies"
        fade
      />
      <FeaturesStrip />
      <PlatformCallout />

      {/* Closing CTA */}
      <Box
        className={`${classes.ctaSection} reveal`}
        pt={80}
        pb={80}
        ref={ctaRevealRef}
      >
        <Container size="sm">
          <Stack gap="lg" align="center" ta="center">
            <Title order={2} size="h2" className={classes.ctaTitle}>
              Make real progress, together.
            </Title>
            <Button variant="white" size="xl" component={Link} to="/start">
              Try Plot
            </Button>
            <Flex gap="lg" wrap="wrap" justify="center">
              <Flex align="center" gap={6}>
                <IconCheck size={14} color="rgba(255,255,255,0.8)" />
                <Text className={classes.trustItem}>
                  Mac, Windows, iOS, Android, and web
                </Text>
              </Flex>
            </Flex>
          </Stack>
        </Container>
      </Box>
    </Stack>
  );
}
