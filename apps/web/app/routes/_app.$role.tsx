import { Outlet, useOutletContext } from "@remix-run/react";

import { Container } from "@mantine/core";

import { EventOptimistProvider } from "app/event";
import type { ContextType } from "app/hooks";

export default function Main() {
  const ctx = useOutletContext<ContextType>();

  return (
    <EventOptimistProvider>
      <Container fluid p="md">
        <Outlet context={ctx} />
      </Container>
    </EventOptimistProvider>
  );
}
