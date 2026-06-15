import { AppShell, Anchor, Group } from "@mantine/core";
import { Link, Outlet } from "react-router";

export default function InternalLayout() {
  return (
    <AppShell header={{ height: 56 }}>
      <AppShell.Header p="xs">
        <Group justify="space-between" h="100%" px="sm">
          <Group gap="lg">
            <Anchor component={Link} to="/internal" fw={600}>
              Plot Internal
            </Anchor>
            <Anchor component={Link} to="/internal/features">
              Features
            </Anchor>
            <Anchor component={Link} to="/internal/updates">
              Updates
            </Anchor>
            <Anchor component={Link} to="/internal/store-listings">
              Store listings
            </Anchor>
          </Group>
          <Anchor component={Link} to="/signout">
            Sign out
          </Anchor>
        </Group>
      </AppShell.Header>
      <AppShell.Main>
        <Outlet />
      </AppShell.Main>
    </AppShell>
  );
}
