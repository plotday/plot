import type { ReactNode } from "react";

import {
  Anchor,
  AppShell,
  Box,
  Button,
  Group,
  UnstyledButton,
} from "@mantine/core";

import { IconBrandLinkedin, IconMail } from "@tabler/icons-react";
import { Link, Outlet, useLocation } from "react-router";

import Logo from "./logo";
import classes from "./public-layout.module.css";

function AppHeader({ menu }: { menu?: ReactNode }) {
  const location = useLocation();

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
          {false && location.pathname !== "/login" && (
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
        <Outlet />
        <Box h={64} />
        <AppFooter />
      </AppShell.Main>
    </AppShell>
  );
}
