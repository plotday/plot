import { useEffect } from "react";

import {
  Link,
  Outlet,
  useLocation,
  useOutletContext,
  useRevalidator,
} from "@remix-run/react";

import {
  Anchor,
  AppShell,
  Badge,
  Burger,
  Center,
  Container,
  Loader,
  NavLink,
  Stack,
  Text,
} from "@mantine/core";
import { useDisclosure, useMediaQuery } from "@mantine/hooks";

import {
  IconAdjustments,
  IconArrowBigLeftLinesFilled,
  IconArrowBigRightLinesFilled,
  IconCalendar,
  IconInbox,
  IconSettings,
} from "@tabler/icons-react";
import classes from "css/_app.module.css";
import add from "date-fns/add";
import { typedjson, useTypedLoaderData } from "remix-typedjson";
import { promiseHash } from "remix-utils/promise";

import { Event, safeQuery } from "@plotday/db";
import type { Attendance, SupabaseClient } from "@plotday/db";

import Logo from "app/components/logo";
import { DEFAULT_PATH } from "app/config";
import { ErrorPage } from "app/error";
import { EventOptimistProvider, useEventWatch } from "app/event";
import type { ContextType } from "app/hooks";
import { privateLoader } from "app/util";

async function calendarReady(supabase: SupabaseClient, userId: number) {
  return !!safeQuery(
    await supabase
      .from("user")
      .select("accounts(calendars(enabled,full_sync_at))")
      .eq("id", userId)
      .single()
  )?.accounts?.some((account) =>
    account.calendars.some(
      // @ts-ignore
      (calendar) => calendar.enabled && calendar.full_sync_at
    )
  );
}

export const loader = privateLoader(async ({ user, supabase, response }) => {
  return typedjson(
    {
      calendarReady: await calendarReady(supabase, user.id),
      counts: await promiseHash({
        triage: Event.GetCount(
          supabase,
          user.id,
          new Date(),
          add(new Date(), { days: 7 }),
          {
            attendance: [null as Attendance],
            type: ["meeting"],
          }
        ),
        prep: Event.GetCount(
          supabase,
          user.id,
          new Date(),
          add(new Date(), { days: 2 }),
          {
            ready: false,
            type: ["meeting"],
          }
        ),
        review: Event.GetCount(supabase, user.id, "-infinity", new Date(), {
          reviewed: false,
          type: ["meeting"],
        }),
      }),
    },
    { headers: response.headers }
  );
});

export function ErrorBoundary() {
  return (
    <Container mt="xl">
      <ErrorPage>
        <Text>
          Please <Anchor href={DEFAULT_PATH}>give it another try</Anchor>.
        </Text>
      </ErrorPage>
    </Container>
  );
}

function Count({ count }: { count: number }) {
  if (count === 0) return null;
  return <Badge color="secondary">{count > 99 ? "99+" : count}</Badge>;
}

function AppNavbar() {
  const location = useLocation();
  const { counts } = useTypedLoaderData();
  useEventWatch();

  return (
    <AppShell.Navbar>
      <AppShell.Section>
        <NavLink component={Link} label={<Logo />} to="/" />
      </AppShell.Section>
      <AppShell.Section grow>
        <NavLink
          component={Link}
          label="Agenda"
          leftSection={<IconCalendar />}
          to="/agenda"
          active={location.pathname === "/agenda"}
        />
        <NavLink
          component={Link}
          label="Inbox"
          leftSection={<IconInbox />}
          to="/inbox"
          active={location.pathname === "/inbox"}
          rightSection={<Count count={counts.triage} />}
        />
        <NavLink
          component={Link}
          label="Prep"
          leftSection={<IconArrowBigRightLinesFilled />}
          to="/prep"
          active={location.pathname === "/prep"}
          rightSection={<Count count={counts.prep} />}
        />
        <NavLink
          component={Link}
          label="Review"
          leftSection={<IconArrowBigLeftLinesFilled />}
          to="/review"
          active={location.pathname === "/review"}
          rightSection={<Count count={counts.review} />}
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
  const { calendarReady } = useTypedLoaderData();
  const ctx = useOutletContext<ContextType>();
  const [opened, { toggle, close }] = useDisclosure();
  const mobile = useMediaQuery("(width < 48em)");
  const { revalidate } = useRevalidator();

  const location = useLocation();
  useEffect(() => {
    close();
  }, [location, close]);

  useEffect(() => {
    if (!calendarReady) {
      const interval = setInterval(() => {
        revalidate();
      }, 2_000);
      return () => {
        clearInterval(interval);
      };
    }
  }, [calendarReady, revalidate]);

  if (!calendarReady) {
    return (
      <Center h="100%">
        <Stack align="center">
          <Loader type="bars" />
          <Text>Loading calendar events</Text>
        </Stack>
      </Center>
    );
  }

  return (
    <EventOptimistProvider>
      <AppShell
        layout="alt"
        navbar={{
          width: 170,
          breakpoint: "sm",
          collapsed: { mobile: !opened },
        }}
        footer={{ height: 32, collapsed: !mobile }}
        padding="md"
      >
        <AppShell.Footer>
          <Center>
            <Burger
              opened={opened}
              onClick={toggle}
              hiddenFrom="sm"
              size="sm"
            />
          </Center>
        </AppShell.Footer>

        <AppNavbar />

        <AppShell.Main className={classes.main}>
          <Outlet context={ctx} />
        </AppShell.Main>
      </AppShell>
    </EventOptimistProvider>
  );
}
