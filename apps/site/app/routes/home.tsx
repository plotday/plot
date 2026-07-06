import {
  Anchor,
  Box,
  Button,
  Container,
  Flex,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import { Link } from "react-router";
import { BenefitSection } from "~/components/home/BenefitSection";
import { FeaturesStrip } from "~/components/home/FeaturesStrip";
import { PlatformBadges } from "~/components/home/PlatformBadges";
import { TeamChatCallout } from "~/components/home/TeamChatCallout";
import { useScrollReveal } from "~/hooks/useScrollReveal";
import { mergeMeta } from "~/lib/meta";

import type { Route } from "./+types/home";
import classes from "./home.module.css";

export function meta(_: Route.MetaArgs) {
  return mergeMeta([
    { title: "Plot — All your work, ready for action" },
    {
      name: "description",
      content:
        "All your work (messages, collaboration, tasks, and meetings) in one place, organized and prioritized.",
    },
    {
      name: "twitter:title",
      content: "Plot — All your work, ready for action",
    },
    {
      name: "twitter:description",
      content:
        "All your work (messages, collaboration, tasks, and meetings) in one place, organized and prioritized.",
    },
  ]);
}

export default function Home() {
  const securityRevealRef = useScrollReveal<HTMLDivElement>();
  const ctaRevealRef = useScrollReveal<HTMLDivElement>();

  return (
    <Stack gap={0}>
      {/* Hero */}
      <Box className={classes.heroSection} pt={80} pb={80}>
        <div className={classes.heroGlow} />
        <Container size="md">
          <Stack align="center" gap="lg" ta="center">
            {/*
              Announcement badge — hidden until there's a real message to show.
              Restore this <div> (and drop the platform line below the CTAs) when
              we have news worth surfacing at the top of the hero.
              <div className={classes.heroBadge}>
                <span className={classes.heroBadgeDot} />
                {message}
              </div>
            */}
            <Title order={1} className={classes.heroTitle}>
              <Text span inherit variant="gradient">
                All your work, ready for action
              </Text>
            </Title>
            <Text className={classes.heroSubtext}>
              Messages, collaboration, tasks, and meetings
              <br />
              in one place — organized and prioritized.
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
                See how it works &darr;
              </Button>
            </Flex>
            <PlatformBadges />
          </Stack>
        </Container>
        <Container size="lg" mt={48}>
          <div className={classes.heroScreenshotWrap}>
            <div className={classes.heroScreenshotGlow} />
            <picture>
              {/* Phones (≤36em): upright app screenshot — the wide shot is too small */}
              <source
                srcSet="/assets/threads-d.webp"
                type="image/webp"
                media="(max-width: 36em) and (prefers-color-scheme: dark)"
              />
              <source
                srcSet="/assets/threads-d.png"
                media="(max-width: 36em) and (prefers-color-scheme: dark)"
              />
              <source
                srcSet="/assets/threads.webp"
                type="image/webp"
                media="(max-width: 36em)"
              />
              <source srcSet="/assets/threads.png" media="(max-width: 36em)" />
              {/* Larger screens: wide product screenshot */}
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
                alt="Plot showing conversations from email, chat, and app tools organized by focus"
                className={classes.heroScreenshot}
              />
            </picture>
          </div>
        </Container>
      </Box>

      <Box id="benefits" />
      {/* Pillar 1 */}
      <BenefitSection
        label="Stop chasing work across all your apps"
        title="Everything you need to make real progress"
        body="Momentum stalls when work is scattered. Plot pulls every message, note, and task — from email, chat, and the tools you already use — into one place, so you can see what needs you and make your next move. Send emails and Slack messages, create Linear issues, and add private notes and tasks all from the same spot. Find anything no matter where it came from."
        image="/assets/connect.png"
        imageDark="/assets/connect.png"
        imageWebp="/assets/connect.webp"
        imageDarkWebp="/assets/connect.webp"
        imageWidth={760}
        imageHeight={828}
        imageAlt="Plot's connect screen showing Gmail, Slack, Linear, calendars, and other tools ready to link"
        cta="Bring your work together →"
        background="gray"
      />
      {/* Pillar 2 */}
      <BenefitSection
        label="Never drop the ball"
        title="Dependable without the drag"
        body="Track everything that needs action from you, wherever it came from. Reply to email, Slack, and app comments right from Plot. Decide what's for today and schedule the rest. Nothing gets dropped without jumping on every interruption or holding it all in your head."
        image="/assets/thread.png"
        imageDark="/assets/thread-d.png"
        imageWebp="/assets/thread.webp"
        imageDarkWebp="/assets/thread-d.webp"
        imageWidth={760}
        imageHeight={1652}
        imageAlt="A Plot thread showing a conversation with replies you can respond to without leaving Plot"
        cta="See it all in Plot →"
        reverse
      />
      {/* Pillar 3 */}
      <BenefitSection
        label="Work from your priorities, not your inbox"
        title="Choose where to invest your time"
        body="Your most important work doesn't sit at the top of your email inbox or notifications. Plot organizes work around your roles and focuses, so you can give it your best attention. Everything else is captured for when you have time."
        image="/assets/agenda.png"
        imageDark="/assets/agenda-d.png"
        imageWebp="/assets/agenda.webp"
        imageDarkWebp="/assets/agenda-d.webp"
        imageWidth={760}
        imageHeight={1652}
        imageAlt="Plot's agenda showing the day's scheduled work across focuses"
        cta="Focus on what matters →"
        background="gray"
      />
      {/* Pillar 4 */}
      <FeaturesStrip />

      {/* Plot threads — free team chat */}
      <TeamChatCallout />

      {/* Security call-out */}
      <Box
        className={`${classes.securitySection} reveal`}
        pt={56}
        pb={56}
        ref={securityRevealRef}
      >
        <Container size="sm">
          <Stack align="center" ta="center" gap="xs">
            <Anchor
              component={Link}
              to="/security"
              className={classes.inlineLink}
            >
              How we keep your data private and secure →
            </Anchor>
          </Stack>
        </Container>
      </Box>

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
              Get back to your best work with Plot.
            </Title>
            <Button variant="white" size="xl" component={Link} to="/start">
              Try Plot
            </Button>
            <PlatformBadges tone="onDark" />
          </Stack>
        </Container>
      </Box>
    </Stack>
  );
}
