import { Container, TypographyStylesProvider } from "@mantine/core";

import type { Route } from "./+types/internal.voice";
import { requireTeamMember } from "../lib/internal-auth.server";
import { renderVoice } from "../lib/internal-docs.server";

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Voice & Tone | Plot Internal" },
    { name: "robots", content: "noindex" },
  ];
}

export async function loader(args: Route.LoaderArgs) {
  await requireTeamMember(args);
  return { html: renderVoice() };
}

export default function InternalVoice({ loaderData }: Route.ComponentProps) {
  return (
    <Container mt="lg" size="md">
      <TypographyStylesProvider>
        <div className="internal-doc" dangerouslySetInnerHTML={{ __html: loaderData.html }} />
      </TypographyStylesProvider>
    </Container>
  );
}
