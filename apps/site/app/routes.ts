import {
  type RouteConfig,
  index,
  layout,
  route,
} from "@react-router/dev/routes";

export default [
  layout("./components/public-layout.tsx", [
    index("routes/home.tsx"),
    route("twists", "routes/twists.tsx"),
    route("connections", "routes/connections.tsx"),
    route("slack", "routes/slack.tsx"),
    route("pricing", "routes/pricing.tsx"),
    route("start", "routes/start.tsx"),
    route("start-done", "routes/start-done.tsx"),
    route("go", "routes/go.tsx"),
    route("go/thanks", "routes/go.thanks.tsx"),
    route("terms", "routes/terms.tsx"),
    route("privacy", "routes/privacy.tsx"),
    route("security", "routes/security.tsx"),
    route("help", "routes/help.tsx"),
    route("help/getting-started", "routes/help.getting-started.tsx"),
    route("help/faqs", "routes/help.faqs.tsx"),
    route("help/contact", "routes/help.contact.tsx"),
    route("signin/*", "routes/signin.tsx"),
    route("signout", "routes/signout.tsx"),

    route("upgrade/*", "routes/upgrade.tsx"),
    route("team/:id", "routes/team.$id.tsx"),
    route("account/delete", "routes/account.delete.tsx"),
    route("unsubscribe", "routes/unsubscribe.tsx"),
    route("twister/login", "routes/twister.login.tsx"),
  ]),
  layout("./components/internal-layout.tsx", [
    route("internal", "routes/internal._index.tsx"),
    route("internal/features", "routes/internal.features.tsx"),
    route("internal/updates", "routes/internal.updates.tsx"),
    route("internal/voice", "routes/internal.voice.tsx"),
  ]),
] satisfies RouteConfig;
