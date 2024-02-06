import type { ReactNode } from "react";

import {
  Link,
  Outlet,
  useLocation,
  useMatches,
  useOutletContext,
} from "@remix-run/react";

import {
  Anchor,
  AppShell,
  Box,
  Button,
  Group,
  UnstyledButton,
} from "@mantine/core";

import { IconBrandLinkedin, IconMail } from "@tabler/icons-react";
import classes from "css/_public.module.css";
import { typedjson, useTypedLoaderData } from "remix-typedjson";

import { pathToUrl } from "@plotday/db";

import type { ContextType } from "app/hooks";
import { publicLoader } from "app/util";

import Logo from "../components/logo";

export const loader = publicLoader(async ({ user, response }) => {
  return typedjson({ user }, { headers: response.headers });
});

function AppHeader({ menu }: { menu?: ReactNode }) {
  const { user } = useTypedLoaderData<typeof loader>();
  const location = useLocation();
  const routes = useMatches();
  const isPublic = routes.some((r) => r.id === "routes/_public");
  const isSync = routes.some((r) => r.pathname === "/sync");
  const activated = user?.app_metadata.invitation;

  console.log("USER", JSON.stringify(user));
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
            <Logo />
          </UnstyledButton>
        </Group>
        <Group>
          {!activated && location.pathname !== "/login" && (
            <Button variant="outline" component={Link} to="/login">
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
      <Group justify="space-between" align="normal">
        <Group gap="lg" align="normal">
          <Anchor href="mailto:team@plot.day" title="Email">
            <IconMail />
          </Anchor>
          <Anchor
            href="https://linkedin.com/company/plot-tech/"
            title="LinkedIn"
          >
            <IconBrandLinkedin />
          </Anchor>
        </Group>
        <Group gap="lg" align="normal">
          <Anchor component={Link} to={`/terms`}>
            Terms of Service
          </Anchor>
          <Anchor component={Link} to={`/privacy`}>
            Privacy Policy
          </Anchor>
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
        <Box h={64} />
        <AppFooter />
      </AppShell.Main>
    </AppShell>
  );
}
