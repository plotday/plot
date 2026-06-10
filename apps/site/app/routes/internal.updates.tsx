import { Container, TypographyStylesProvider } from "@mantine/core";

import type { Route } from "./+types/internal.updates";
import { requireTeamMember } from "../lib/internal-auth.server";
import { renderUpdates } from "../lib/internal-docs.server";

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Updates | Plot Internal" },
    { name: "robots", content: "noindex" },
  ];
}

export async function loader(args: Route.LoaderArgs) {
  await requireTeamMember(args);
  return { html: renderUpdates() };
}

export default function InternalUpdates({ loaderData }: Route.ComponentProps) {
  return (
    <Container mt="lg" size="md">
      <TypographyStylesProvider>
        <div dangerouslySetInnerHTML={{ __html: loaderData.html }} />
      </TypographyStylesProvider>
    </Container>
  );
}
