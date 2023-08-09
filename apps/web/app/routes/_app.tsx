import { AppShell, Burger, UnstyledButton } from "@mantine/core";
import { useDisclosure } from "@mantine/hooks";
import type { LoaderArgs } from "@remix-run/cloudflare";
import { json, redirect } from "@remix-run/cloudflare";
import { Link, Outlet, useLocation, useOutletContext } from "@remix-run/react";
import { useCallback } from "react";

import { getUser, logout } from "../auth";
import Logo from "../components/logo";
import { createServerClient } from "../db";
import type { ContextType } from "../root";
import classes from "./_app.module.css";

export const loader = async ({ context, request }: LoaderArgs) => {
  let response: Response | undefined;
  let supabase;
  ({ supabase, response } = createServerClient(request, context));

  let user = await getUser(supabase);
  if (!user) {
    return redirect("/login");
  }

  return json({}, { headers: response.headers });
};

function NavLink({
  label,
  to,
  active,
  ...props
}: {
  label: string;
  to: string;
  active: boolean;
}) {
  return (
    <UnstyledButton
      component={Link}
      to={to}
      className={classes.control}
      {...props}
    >
      {label}
    </UnstyledButton>
  );
}

function AppNavbar() {
  const location = useLocation();
  const { supabase } = useOutletContext<ContextType>();
  const doLogout = useCallback(() => {
    if (!supabase) return;
    logout(supabase);
  }, [supabase]);

  return (
    <AppShell.Navbar p="md">
      <AppShell.Section>
        <UnstyledButton component={Link} to="/" className={classes.control}>
          <Logo />
        </UnstyledButton>
      </AppShell.Section>
      <AppShell.Section grow>
        <NavLink
          label="Prep"
          to="/prep"
          active={location.pathname === "/prep"}
        />
        <NavLink
          label="Review"
          to="/review"
          active={location.pathname === "/prep"}
        />
      </AppShell.Section>
      <AppShell.Section>
        <NavLink
          label="Settings"
          to="/settings"
          active={location.pathname === "/settings"}
        />
        <UnstyledButton onClick={doLogout} className={classes.control}>
          Sign out
        </UnstyledButton>
      </AppShell.Section>
    </AppShell.Navbar>
  );
}

export default function App() {
  const ctx = useOutletContext<ContextType>();
  const [opened, { toggle }] = useDisclosure();

  return (
    <AppShell
      layout="alt"
      navbar={{ width: 300, breakpoint: "sm", collapsed: { mobile: !opened } }}
      padding="md"
    >
      <AppShell.Header>
        <Burger opened={opened} onClick={toggle} hiddenFrom="sm" size="sm" />
      </AppShell.Header>

      <AppNavbar />

      <AppShell.Main>
        <Outlet context={ctx} />
      </AppShell.Main>
    </AppShell>
  );
}
