import type { Route } from "./+types/internal.voice";
import InternalDoc from "../components/internal-doc";
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
  return renderVoice();
}

export default function InternalVoice({ loaderData }: Route.ComponentProps) {
  return <InternalDoc html={loaderData.html} markdown={loaderData.markdown} />;
}
