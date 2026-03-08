import { Anchor, Box, Container, Stack, Text, Title } from "@mantine/core";

import {
  IconBrandAndroid,
  IconBrandApple,
  IconBrandWindows,
  IconWorld,
} from "@tabler/icons-react";

import type { Route } from "./+types/start";
import classes from "./start.module.css";

type Platform = "macos" | "windows" | "ios" | "android" | "linux" | "unknown";

interface PlatformInfo {
  key: Platform;
  label: string;
  icon: typeof IconBrandApple;
  available: boolean;
  href: string;
  note?: string;
}

const PLATFORMS: PlatformInfo[] = [
  {
    key: "macos",
    label: "Mac",
    icon: IconBrandApple,
    available: true,
    href: "https://testflight.apple.com/join/WyVQ2GgV",
    note: "TestFlight beta",
  },
  {
    key: "windows",
    label: "Windows",
    icon: IconBrandWindows,
    available: false,
    href: "",
    note: "Coming soon",
  },
  {
    key: "ios",
    label: "iOS",
    icon: IconBrandApple,
    available: true,
    href: "https://testflight.apple.com/join/B9gCus7k",
    note: "TestFlight beta",
  },
  {
    key: "android",
    label: "Android",
    icon: IconBrandAndroid,
    available: true,
    href: "https://play.google.com/store/apps/details?id=day.plot.app",
    note: "Open testing",
  },
  {
    key: "unknown",
    label: "Browser",
    icon: IconWorld,
    available: true,
    href: "https://app.plot.day",
    note: "Continue here",
  },
];

function detectPlatform(userAgent: string): Platform {
  const ua = userAgent.toLowerCase();
  if (ua.includes("iphone") || ua.includes("ipad")) return "ios";
  if (ua.includes("android")) return "android";
  if (ua.includes("macintosh") || ua.includes("mac os")) return "macos";
  if (ua.includes("windows")) return "windows";
  if (ua.includes("linux")) return "linux";
  return "unknown";
}

export function loader({ request }: Route.LoaderArgs) {
  const userAgent = request.headers.get("User-Agent") ?? "";
  return { detectedPlatform: detectPlatform(userAgent) };
}

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Get Plot" },
    {
      name: "description",
      content:
        "Download Plot for your platform. Available for Mac and Windows, with iOS and Android coming soon.",
    },
    { "og:title": "Get Plot" },
    {
      "og:description": "Download Plot for your platform.",
    },
    { "og:image": "https://plot.day/assets/p.png" },
  ];
}

function PlatformCard({
  platform,
  isPrimary,
}: {
  platform: PlatformInfo;
  isPrimary: boolean;
}) {
  const Icon = platform.icon;

  if (!platform.available) {
    return (
      <Stack className={classes.platformCardDisabled} gap="sm" align="center">
        <Box className={classes.platformIcon}>
          <Icon size={40} />
        </Box>
        <Title order={4}>{platform.label}</Title>
        <Text fz="sm" c="dimmed">
          {platform.note}
        </Text>
      </Stack>
    );
  }

  return (
    <Anchor
      href={platform.href}
      className={isPrimary ? classes.primaryCard : classes.platformCard}
      underline="never"
    >
      <Stack gap="sm" align="center">
        <Box className={classes.platformIcon}>
          <Icon size={40} />
        </Box>
        <Title order={4}>{platform.label}</Title>
        {platform.note && (
          <Text fz="sm" c="dimmed">
            {platform.note}
          </Text>
        )}
      </Stack>
    </Anchor>
  );
}

export default function Start({ loaderData }: Route.ComponentProps) {
  const { detectedPlatform } = loaderData;

  const primaryPlatform = PLATFORMS.find(
    (p) => p.key === detectedPlatform && p.available,
  );
  const otherPlatforms = PLATFORMS.filter((p) => p !== primaryPlatform);

  const showPrimaryCard =
    primaryPlatform && !["linux", "unknown"].includes(detectedPlatform);

  return (
    <Stack gap={0}>
      <Box className={classes.heroSection} pt={60} pb={60}>
        <Container size="md">
          <Stack align="center" gap="xl" ta="center">
            <Title order={1} className={classes.heroTitle}>
              <Text span inherit variant="gradient">
                Get Plot
              </Text>
            </Title>
            <Text className={classes.heroSubtext}>
              Download apps for the best experience,
              <br />
              or continue in your browser.
            </Text>

            {showPrimaryCard && (
              <PlatformCard platform={primaryPlatform} isPrimary />
            )}

            <Box className={classes.platformGrid} maw={500}>
              {otherPlatforms.map((platform) => (
                <PlatformCard
                  key={platform.key}
                  platform={platform}
                  isPrimary={false}
                />
              ))}
            </Box>
          </Stack>
        </Container>
      </Box>
    </Stack>
  );
}
