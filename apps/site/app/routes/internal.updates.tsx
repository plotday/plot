import type { Route } from "./+types/internal.updates";
import InternalDoc from "../components/internal-doc";
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
  return renderUpdates();
}

export default function InternalUpdates({ loaderData }: Route.ComponentProps) {
  return <InternalDoc html={loaderData.html} markdown={loaderData.markdown} />;
}
