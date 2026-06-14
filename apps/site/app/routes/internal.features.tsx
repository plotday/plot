import type { Route } from "./+types/internal.features";
import InternalDoc from "../components/internal-doc";
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
  return renderFeatures();
}

export default function InternalFeatures({ loaderData }: Route.ComponentProps) {
  return <InternalDoc html={loaderData.html} markdown={loaderData.markdown} />;
}
