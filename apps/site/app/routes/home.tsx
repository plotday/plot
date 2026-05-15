import { useEffect, useRef, useState } from "react";

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

const STORY_TABS = [
  {
    label: "Email",
    image: "/assets/email.png",
    title: "A to-do list written by others",
    copy: "Email lets us easily pass work to others. But when inboxes drive our day, we spend it playing the inbox zero game. Once we \"win\", we often realize we haven't started on what's most important.",
    lightVignette: true,
  },
  {
    label: "Team Chat",
    image: "/assets/chat.png",
    title: "Fast coordination, slow resolution",
    copy: "Chat makes coordination nearly free — a question doesn't need to wait for a meeting, and anyone can weigh in. But the loudest threads are often the least important, while the essential ones quietly go unresolved.",
    lightVignette: true,
  },
  {
    label: "Project Management",
    image: "/assets/project.png",
    title: "Clarity that becomes its own overhead",
    copy: "Project management tools bring clarity to work. But when nothing moves without a ticket, the tool becomes the bottleneck. Maintaining it becomes its own job, and planning starts taking longer than the work.",
    lightVignette: true,
  },
  {
    label: "Meetings",
    image: "/assets/meetings.png",
    title: "High bandwidth, high cost",
    copy: "Meetings offer high-bandwidth collaboration that can solve challenges that snarl email threads. But when nothing can happen without a meeting, we live by our calendars and burn our best energy before the work begins.",
    lightVignette: false,
  },
];

export function meta(_: Route.MetaArgs) {
  return mergeMeta([
    { title: "Plot | Your best work, every day" },
    {
      name: "description",
      content:
        "Your work from every tool, organized by what matters. Plot brings together tasks, messages, events, and docs into one prioritized workspace.",
    },
    { name: "twitter:title", content: "Plot" },
    {
      name: "twitter:description",
      content:
        "Your work from every tool, organized by what matters. Plot brings together tasks, messages, events, and docs into one prioritized workspace.",
    },
  ]);
}

export default function Home() {
  const [activeTab, setActiveTab] = useState(0);
  const [entering, setEntering] = useState(false);
  const enteringTimeout = useRef<ReturnType<typeof setTimeout> | undefined>(
    undefined,
  );

  const handleTabChange = (index: number) => {
    if (index === activeTab) return;
    setEntering(true);
    clearTimeout(enteringTimeout.current);
    enteringTimeout.current = setTimeout(() => {
      setActiveTab(index);
      setEntering(false);
    }, 150);
  };

  useEffect(() => {
    return () => clearTimeout(enteringTimeout.current);
  }, []);

  const storyRevealRef = useScrollReveal<HTMLDivElement>();
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
                Your best work, every&nbsp;day
              </Text>
            </Title>
            <Text className={classes.heroSubtext}>
              Everything in one place.
              <br />
              Organized, prioritized, and ready for action.
            </Text>
            <Flex gap="md" wrap="wrap" justify="center">
              <Button
                size="lg"
                component={Link}
                to="/start"
                className={classes.heroCta}
              >
                Get started free
              </Button>
              <Button
                variant="subtle"
                size="lg"
                component="a"
                href="#story"
                onClick={(e: React.MouseEvent<HTMLAnchorElement>) => {
                  e.preventDefault();
                  document
                    .getElementById("story")
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
                alt="Plot interface showing a team conversation transforming into a prioritized action item"
                className={classes.heroScreenshot}
              />
            </picture>
          </div>
        </Container>
      </Box>

      {/* Productivity Story */}
      <Box
        id="story"
        className={classes.storySection}
        pt={80}
        pb={80}
        ref={storyRevealRef}
      >
        <Container size="lg">
          <Stack align="center" gap="xs" mb="xl">
            <Title
              order={2}
              size="h2"
              className={classes.sectionTitle}
              ta="center"
            >
              So what's stopping us?
            </Title>
            <Text className={classes.storySubtitle} ta="center">
              The tools we rely on create their own problems
            </Text>
          </Stack>

          <Stack gap="lg">
            <div className={classes.storyTabs}>
              {STORY_TABS.map((tab, i) => (
                <button
                  key={tab.label}
                  className={`${classes.storyTab} ${
                    i === activeTab ? classes.storyTabActive : ""
                  }`}
                  onClick={() => handleTabChange(i)}
                  type="button"
                >
                  {tab.label}
                </button>
              ))}
            </div>

            <div className={classes.storyCard}>
              <div className={classes.storyCardGlow} />
              <div
                className={`${classes.storyImageWrap} ${
                  STORY_TABS[activeTab].lightVignette
                    ? classes.storyImageLightVignette
                    : ""
                }`}
              >
                <img
                  src={STORY_TABS[activeTab].image}
                  alt={STORY_TABS[activeTab].label}
                  className={classes.storyImage}
                />
              </div>
              <div
                className={`${classes.storyContent} ${
                  entering ? classes.storyContentEntering : ""
                }`}
              >
                <div className={classes.storyCopyTitle}>
                  {STORY_TABS[activeTab].title}
                </div>
                <Text className={classes.storyCopy}>
                  {STORY_TABS[activeTab].copy}
                </Text>
              </div>
            </div>
          </Stack>
        </Container>
        <Container size="md" mt={60}>
          <Text className={classes.hingeText}>
            Each keeps us busy.
            <br />
            What we need is something that moves us forward.
          </Text>
        </Container>
      </Box>

      <Box id="benefits" />
      <BenefitSection
        label="Unified workspace"
        title="Everything in one place"
        body="Your meeting gets a thread. Your task gets a note. Your email gets context. Plot pulls work from Google Calendar, Slack, Linear, Gmail, and more — organized by priority, not arrival time. Related items collect automatically. Smart notifications surface what actually needs your attention. Nothing falls through the cracks."
        image="/assets/activity.png"
        imageDark="/assets/activity-d.png"
        imageAlt="Plot activity view showing unified items from multiple sources"
      />
      <BenefitSection
        label="Daily workflow"
        title="Ready for action"
        body={
          'Your agenda is your day — and Plot makes sure it\'s ready when you are. See everything due today across every tool, in one place. Open an item and find the notes, messages, and context already there. No tab-switching, no hunting for links, no "let me find that thread."'
        }
        image="/assets/agenda.png"
        imageDark="/assets/agenda-d.png"
        imageAlt="Plot agenda view showing today's tasks and events"
        reverse
        background="gray"
      />
      <BenefitSection
        label="Strategic view"
        title="Momentum on what matters"
        body="Most tools break down at the boundary between planning and doing. Plot closes that gap. Zoom out to see your priorities and what's moving. Zoom in to focus on the work in front of you. Everything you need — context, collaborators, next steps — is already in the same place you do the work."
        image="/assets/priorities.png"
        imageDark="/assets/priorities-d.png"
        imageAlt="Plot priorities view showing nested project hierarchy"
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
              Get back to your best work.
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
