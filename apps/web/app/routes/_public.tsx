import type { ReactNode } from "react";

import type { LoaderArgs } from "@remix-run/cloudflare";
import { json } from "@remix-run/cloudflare";
import {
  Link,
  Outlet,
  useLoaderData,
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

import { getUser } from "app/auth";
import { createServerClient } from "app/db";

import Logo from "../components/logo";
import { DEFAULT_PATH } from "../config";
import type { ContextType } from "../root";
import classes from "./_public.module.css";

export const loader = async ({ context, request }: LoaderArgs) => {
  let response: Response | undefined;
  let supabase;
  ({ supabase, response } = createServerClient(request, context));

  let user = await getUser(supabase);
  return json({ user }, { headers: response.headers });
};

function AppHeader({ menu }: { menu?: ReactNode }) {
  const { user } = useLoaderData();
  const location = useLocation();
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
            <Logo />
          </UnstyledButton>
        </Group>
        <Group>
          {user && isPublic && (
            <Button component={Link} to={DEFAULT_PATH}>
              Go to app
            </Button>
          )}
          {!user && location.pathname !== "/login" && (
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
      <Group gap="md" justify="space-between">
        <Group>
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
        <Group>
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
      </AppShell.Main>
      <AppFooter />
    </AppShell>
  );
}
