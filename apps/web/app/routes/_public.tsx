import {
  Anchor,
  AppShell,
  Button,
  Group,
  Text,
  Title,
  UnstyledButton,
  useMantineColorScheme,
} from "@mantine/core";
import {
  Link,
  Outlet,
  useLocation,
  useMatches,
  useOutletContext,
} from "@remix-run/react";
import type { ReactNode } from "react";

import { APP_NAME, DEFAULT_PATH } from "../config";
import type { ContextType } from "../root";

function AppHeader({ menu }: { menu?: ReactNode }) {
  const { colorScheme } = useMantineColorScheme();
  const location = useLocation();
  const { user } = useOutletContext<ContextType>();
  const routes = useMatches();
  const isPublic = routes.some((r) => r.id === "routes/_public");
  const headerControl = routes
    .filter((r) => r.handle?.headerControl)?.[0]
    ?.handle?.headerControl?.();

  return (
    <AppShell.Header p="xs">
      <Group
        mih={50}
        gap="md"
        justify="space-between"
        align="flex-start"
        wrap="wrap"
      >
        <Group>
          {menu}
          <UnstyledButton component={Link} to="/">
            <Title
              order={1}
              size="h2"
              color={colorScheme === "light" ? "violet.9" : "violet.3"}
            >
              {APP_NAME}
            </Title>
          </UnstyledButton>
        </Group>
        <Group>{headerControl}</Group>
        <Group>
          {user && isPublic && (
            <Button component={Link} to={DEFAULT_PATH}>
              Go to app
            </Button>
          )}
          {!user && location.pathname !== "/login" && (
            <Button component={Link} to="/login">
              Sign in
            </Button>
          )}
        </Group>
      </Group>
    </AppShell.Header>
  );
}

function AppFooter() {
  return (
    <AppShell.Footer p="md">
      <Group gap="md" justify="space-between">
        <Group>
          <Anchor component={Link} to={`/terms`}>
            Terms of Service
          </Anchor>
          <Anchor component={Link} to={`/privacy`}>
            Privacy Policy
          </Anchor>
        </Group>
        <Group>
          <Anchor href="mailto:team@plot.day">Contact Us</Anchor>
        </Group>
      </Group>
    </AppShell.Footer>
  );
}

export default function Index() {
  const ctx = useOutletContext<ContextType>();
  return (
    <AppShell
      header={{ height: 60 }}
      footer={{ height: 60 }}
      styles={{
        main: {
          minHeight: "unset",
          paddingLeft: 0,
          paddingRight: 0,
          paddingBottom: 60,
        },
      }}
    >
      <AppHeader />
      <AppShell.Main>
        <Outlet context={ctx} />
      </AppShell.Main>
      <AppFooter />
    </AppShell>
  );
}
