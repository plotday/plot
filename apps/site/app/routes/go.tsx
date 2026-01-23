import { useEffect, useState, type ReactNode } from "react";

import {
  Badge,
  Button,
  Card,
  Container,
  Loader,
  SimpleGrid,
  Stack,
  Text,
  Title,
  UnstyledButton,
} from "@mantine/core";
import { IconWorld } from "@tabler/icons-react";

import type { Route } from "./+types/go";
import classes from "./go.module.css";

export function meta(_: Route.MetaArgs) {
  return [
    {
      title: "Get Plot | Plot",
    },
  ];
}

export async function loader({ params }: Route.LoaderArgs) {
  // No auth required - anyone can access
  const path = (params as { "*"?: string })["*"] || "";
  return { path };
}

// Platform icon components
function AppleIcon() {
  return (
    <svg
      width="48"
      height="48"
      viewBox="0 0 24 24"
      fill="currentColor"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path d="M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09l.01-.01zM12.03 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
    </svg>
  );
}

function PlayStoreIcon() {
  return (
    <svg
      width="48"
      height="48"
      viewBox="0 0 24 24"
      fill="currentColor"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path d="M3.609 1.814L13.792 12 3.61 22.186a.996.996 0 0 1-.61-.92V2.734a1 1 0 0 1 .609-.92zm10.89 10.893l2.302 2.302-10.937 6.333 8.635-8.635zm3.199-3.198l2.807 1.626a1 1 0 0 1 0 1.73l-2.808 1.626L15.206 12l2.492-2.491zM5.864 2.658L16.8 9.99l-2.302 2.302-8.634-8.634z" />
    </svg>
  );
}

function WindowsIcon() {
  return (
    <svg
      width="48"
      height="48"
      viewBox="0 0 24 24"
      fill="currentColor"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path d="M3 5.557L10.163 4.6v6.638H3V5.557zm0 12.886l7.163.957v-6.638H3v5.681zM11.075 4.46L21 3v8.238h-9.925V4.46zm0 15.08L21 21v-8.238h-9.925v6.778z" />
    </svg>
  );
}

type Platform = {
  id: string;
  name: string;
  icon: ReactNode;
  url: string | null;
  badge?: string;
};

export default function Go({ loaderData }: Route.ComponentProps) {
  const { path } = loaderData;
  const [showPlatforms, setShowPlatforms] = useState(false);

  // Attempt deep link on mount
  useEffect(() => {
    const deepLinkUrl = `https://app.plot.day/${path}`;

    // Try to open via deep link
    window.location.href = deepLinkUrl;

    // Show fallback after delay (deep link didn't work)
    const timeout = setTimeout(() => {
      setShowPlatforms(true);
    }, 1500);

    return () => clearTimeout(timeout);
  }, [path]);

  // Update web URL to include path
  const webUrl = path ? `https://app.plot.day/${path}` : "https://app.plot.day";

  const platforms: Platform[] = [
    {
      id: "web",
      name: "Web",
      icon: <IconWorld size={48} stroke={1.5} />,
      url: webUrl,
    },
    {
      id: "mac",
      name: "Mac",
      icon: <AppleIcon />,
      url: null,
      badge: "Coming Soon",
    },
    {
      id: "ios",
      name: "iPhone & iPad",
      icon: <AppleIcon />,
      url: null,
      badge: "Coming Soon",
    },
    {
      id: "android",
      name: "Android",
      icon: <PlayStoreIcon />,
      url: null,
      badge: "Coming Soon",
    },
    {
      id: "windows",
      name: "Windows",
      icon: <WindowsIcon />,
      url: null,
      badge: "Coming Soon",
    },
  ];

  // Show loading state while attempting deep link
  if (!showPlatforms) {
    return (
      <Container size="xs" mt="xl">
        <Stack align="center" gap="md" className={classes.loading}>
          <Loader size="lg" />
          <Text size="lg">Opening Plot...</Text>
          <Text size="sm" c="dimmed">
            If the app doesn't open,{" "}
            <UnstyledButton
              onClick={() => setShowPlatforms(true)}
              style={{ textDecoration: "underline", color: "inherit" }}
            >
              click here
            </UnstyledButton>
          </Text>
        </Stack>
      </Container>
    );
  }

  return (
    <Container size="md" mt="xl">
      <Stack gap="xl" align="center">
        <Stack gap="xs" align="center">
          <Title order={1}>Welcome to Plot</Title>
          <Text c="dimmed" size="lg" ta="center">
            Choose how you'd like to access Plot
          </Text>
        </Stack>

        <SimpleGrid cols={{ base: 1, sm: 2, md: 3 }} spacing="lg" w="100%">
          {platforms.map((platform) => {
            const isDisabled = !platform.url;

            return (
              <Card
                key={platform.id}
                component={isDisabled ? "div" : "a"}
                href={platform.url ?? undefined}
                className={isDisabled ? classes.cardDisabled : classes.card}
                padding="xl"
                radius="md"
                withBorder
              >
                <Stack align="center" gap="md">
                  <div className={classes.platformIcon}>{platform.icon}</div>
                  <Text fw={500} size="lg">
                    {platform.name}
                  </Text>
                  {platform.badge && (
                    <Badge color="gray" variant="light" size="sm">
                      {platform.badge}
                    </Badge>
                  )}
                  {!isDisabled && (
                    <Button variant="gradient" size="sm" fullWidth>
                      Open
                    </Button>
                  )}
                </Stack>
              </Card>
            );
          })}
        </SimpleGrid>
      </Stack>
    </Container>
  );
}
