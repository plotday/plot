import type { Route } from "./+types/internal.store-listings";
import InternalDoc from "../components/internal-doc";
import { requireTeamMember } from "../lib/internal-auth.server";
import { renderStoreListings } from "../lib/internal-docs.server";

export function meta(_: Route.MetaArgs) {
  return [
    { title: "App Store Listings | Plot Internal" },
    { name: "robots", content: "noindex" },
  ];
}

export async function loader(args: Route.LoaderArgs) {
  await requireTeamMember(args);
  return renderStoreListings();
}

export default function InternalStoreListings({
  loaderData,
}: Route.ComponentProps) {
  return <InternalDoc html={loaderData.html} markdown={loaderData.markdown} />;
}
