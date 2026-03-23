import { useEffect, useState } from "react";
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
  const hideGetStartedPaths = ["/builder"];
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const handleScroll = () => setScrolled(window.scrollY > 10);
    handleScroll();
    window.addEventListener("scroll", handleScroll, { passive: true });
    return () => window.removeEventListener("scroll", handleScroll);
  }, []);

  return (
    <AppShell.Header
      p="xs"
      className={`${classes.header} ${scrolled ? classes.headerScrolled : ""}`}
    >
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
          <Group visibleFrom="sm" gap="xl">
            <Anchor
              component={Link}
              to="/#benefits"
              className={classes.navLink}
            >
              Product
            </Anchor>
            <Anchor component={Link} to="/pricing" className={classes.navLink}>
              Pricing
            </Anchor>
            <Anchor
              component={Link}
              to="/connections"
              className={classes.navLink}
            >
              Connections
            </Anchor>
          </Group>
          {!hideGetStartedPaths.some((path) =>
            location.pathname.startsWith(path),
          ) && (
            <Button variant="outline" component={Link} to="/start">
              Try Plot
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
      <Group justify="space-between">
        <Group gap="lg">
          <Anchor href="mailto:team@plot.day" title="Email" lh="normal">
            <IconMail size={20} />
          </Anchor>
          <Anchor
            href="https://linkedin.com/company/plot-tech/"
            title="LinkedIn"
            lh="normal"
          >
            <IconBrandLinkedin size={20} />
          </Anchor>
        </Group>
        <Group gap="lg" className={classes.footerLinks}>
          <Anchor component={Link} to="/connections">
            Connections
          </Anchor>
          <Anchor component={Link} to="/twists">
            Twists
          </Anchor>
          <Anchor component={Link} to="/pricing">
            Pricing
          </Anchor>
          <Anchor component={Link} to="/terms">
            Terms of Service
          </Anchor>
          <Anchor component={Link} to="/privacy">
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
        <AppFooter />
      </AppShell.Main>
    </AppShell>
  );
}
