import { useCallback, useEffect } from "react";

import type { LoaderArgs } from "@remix-run/cloudflare";
import { json, redirect } from "@remix-run/cloudflare";
import { Link, Outlet, useLocation, useOutletContext } from "@remix-run/react";

import { AppShell, Burger, Center, UnstyledButton } from "@mantine/core";
import { useDisclosure, useMediaQuery } from "@mantine/hooks";

import { getUser, logout } from "app/auth";
import Logo from "app/components/logo";
import { createServerClient } from "app/db";
import type { ContextType } from "app/root";

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
  children,
  to,
  active,
  ...props
}: {
  children: React.ReactNode;
  to: string;
  active: boolean;
}) {
  return (
    <UnstyledButton
      component={Link}
      to={to}
      className={classes.control}
      c={active ? "brand" : undefined}
      {...props}
    >
      {children}
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
    <AppShell.Navbar>
      <AppShell.Section>
        <UnstyledButton component={Link} to="/" className={classes.control}>
          <Logo />
        </UnstyledButton>
      </AppShell.Section>
      <AppShell.Section grow>
        <NavLink to="/prep" active={location.pathname === "/prep"}>
          Prep
        </NavLink>
        <NavLink to="/review" active={location.pathname === "/review"}>
          Review
        </NavLink>
        <NavLink to="/tune" active={location.pathname === "/tune"}>
          Tune
        </NavLink>
      </AppShell.Section>
      <AppShell.Section>
        <NavLink to="/settings" active={location.pathname === "/settings"}>
          Settings
        </NavLink>
        <UnstyledButton onClick={doLogout} className={classes.control}>
          Sign out
        </UnstyledButton>
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
