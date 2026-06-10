import { Container, TypographyStylesProvider } from "@mantine/core";

import type { Route } from "./+types/internal.features";
import { requireTeamMember } from "../lib/internal-auth.server";
import { renderFeatures } from "../lib/internal-docs.server";

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Features | Plot Internal" },
    { name: "robots", content: "noindex" },
  ];
}

export async function loader(args: Route.LoaderArgs) {
  await requireTeamMember(args);
  return { html: renderFeatures() };
}

export default function InternalFeatures({ loaderData }: Route.ComponentProps) {
  return (
    <Container mt="lg" size="md">
      <TypographyStylesProvider>
        <div dangerouslySetInnerHTML={{ __html: loaderData.html }} />
      </TypographyStylesProvider>
    </Container>
  );
}
