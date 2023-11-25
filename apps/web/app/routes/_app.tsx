import { useMemo } from "react";

import { Link, Outlet, useOutletContext } from "@remix-run/react";

import {
  Anchor,
  AppShell,
  Box,
  Button,
  Container,
  Flex,
  Text,
} from "@mantine/core";

import { IconSettings } from "@tabler/icons-react";
import { typedjson, useTypedLoaderData } from "remix-typedjson";
import { promiseHash } from "remix-utils/promise";

import { getCategories } from "@plotday/db";

import { Navigator } from "app/components/navigator";
import { SelectWeek } from "app/components/select-week";
import { DEFAULT_PATH } from "app/config";
import { ErrorPage } from "app/error";
import type { ContextType } from "app/hooks";
import { privateLoader } from "app/util";

export const loader = privateLoader(async ({ response, user, supabase }) => {
  return typedjson(
    {
      ...(await promiseHash({
        categories: getCategories(supabase, user.id),
      })),
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

function Header() {
  return (
    <AppShell.Header>
      <Flex justify="space-between">
        <Box style={{ flex: 1 }}>
          <Navigator />
        </Box>
        <Box w="fit-content" style={{ flex: 0 }}>
          <SelectWeek />
        </Box>
        <Box ta="right" style={{ flex: 1 }}>
          <Button component={Link} to="/settings" variant="subtle" radius={0}>
            <IconSettings />
          </Button>
        </Box>
      </Flex>
    </AppShell.Header>
  );
}

export default function App() {
  const { categories } = useTypedLoaderData<typeof loader>();
  const parentCtx = useOutletContext<ContextType>();
  const ctx = useMemo(
    () => ({
      ...parentCtx,
      categories,
    }),
    [parentCtx, categories]
  );

  return (
    <AppShell header={{ height: 36 }}>
      <Header />
      <AppShell.Main bg="var(--mantine-color-background)">
        <Outlet context={ctx} />
      </AppShell.Main>
    </AppShell>
  );
}
