import { useEffect } from "react";

import type { LoaderArgs } from "@remix-run/cloudflare";
import { json, redirect } from "@remix-run/cloudflare";
import { Link, Outlet, useLocation, useOutletContext } from "@remix-run/react";

import { AppShell, Burger, Center, NavLink } from "@mantine/core";
import { useDisclosure, useMediaQuery } from "@mantine/hooks";

import {
  IconAdjustments,
  IconArrowBigLeftLinesFilled,
  IconArrowBigRightLinesFilled,
  IconSettings,
} from "@tabler/icons-react";
import classes from "css/_app.module.css";

import { isSignedIn } from "app/auth";
import Logo from "app/components/logo";
import { createServerClient } from "app/db";
import type { ContextType } from "app/hooks";

export const loader = async ({ context, request }: LoaderArgs) => {
  let response: Response | undefined;
  let supabase;
  ({ supabase, response } = createServerClient(request, context));

  if (!(await isSignedIn(supabase))) {
    return redirect("/login");
  }

  return json({}, { headers: response.headers });
};

function AppNavbar() {
  const location = useLocation();

  return (
    <AppShell.Navbar>
      <AppShell.Section>
        <NavLink component={Link} label={<Logo />} to="/" />
      </AppShell.Section>
      <AppShell.Section grow>
        <NavLink
          component={Link}
          label="Prep"
          leftSection={<IconArrowBigRightLinesFilled />}
          to="/prep"
          active={location.pathname === "/prep"}
        />
        <NavLink
          component={Link}
          label="Review"
          leftSection={<IconArrowBigLeftLinesFilled />}
          to="/review"
          active={location.pathname === "/review"}
        />
        <NavLink
          component={Link}
          label="Tune"
          leftSection={<IconAdjustments />}
          to="/tune"
          active={location.pathname === "/tune"}
        />
      </AppShell.Section>
      <AppShell.Section>
        <NavLink
          component={Link}
          label="Settings"
          leftSection={<IconSettings />}
          to="/settings"
          active={location.pathname === "/settings"}
        />
      </AppShell.Section>
    </AppShell.Navbar>
  );
}

export default function App() {
  const ctx = useOutletContext<ContextType>();
  const [opened, { toggle, close }] = useDisclosure();
  const mobile = useMediaQuery("(width < 48em)");

  const location = useLocation();
  useEffect(() => {
    close();
  }, [location, close]);

  return (
    <AppShell
      layout="alt"
      navbar={{ width: 150, breakpoint: "sm", collapsed: { mobile: !opened } }}
      footer={{ height: 32, collapsed: !mobile }}
      padding="md"
    >
      <AppShell.Footer>
        <Center>
          <Burger opened={opened} onClick={toggle} hiddenFrom="sm" size="sm" />
        </Center>
      </AppShell.Footer>

      <AppNavbar />

      <AppShell.Main className={classes.main}>
        <Outlet context={ctx} />
      </AppShell.Main>
    </AppShell>
  );
}
