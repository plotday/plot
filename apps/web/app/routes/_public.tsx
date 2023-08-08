import {
  Anchor,
  AppShell,
  Box,
  Button,
  Group,
  Image,
  UnstyledButton,
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
import classes from "./_public.module.css";

function AppHeader({ menu }: { menu?: ReactNode }) {
  const location = useLocation();
  const { user } = useOutletContext<ContextType>();
  const routes = useMatches();
  const isPublic = routes.some((r) => r.id === "routes/_public");

  return (
    <AppShell.Header p="xs" className={classes.header}>
      <Group
        mih={50}
        gap="md"
        justify="space-between"
        align="flex-start"
        wrap="wrap"
      >
        <Group>
          {menu}
          <UnstyledButton component={Link} to="/" pt={6} pb={6}>
            <Image
              src="/assets/plot.svg"
              alt={APP_NAME}
              height={24}
              className={classes.logo}
            />
          </UnstyledButton>
        </Group>
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
    <Box p="md" className={classes.footer}>
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
    </Box>
  );
}

export default function Index() {
  const ctx = useOutletContext<ContextType>();
  return (
    <AppShell
      header={{ height: 60 }}
      styles={{
        main: {
          paddingLeft: 0,
          paddingRight: 0,
          paddingBottom: 0,
        },
      }}
    >
      <AppHeader />
      <AppShell.Main className={classes.main}>
        <Outlet context={ctx} />
      </AppShell.Main>
      <AppFooter />
    </AppShell>
  );
}
