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
    route("pricing", "routes/pricing.tsx"),
    route("start", "routes/start.tsx"),
    route("start-done", "routes/start-done.tsx"),
    route("terms", "routes/terms.tsx"),
    route("privacy", "routes/privacy.tsx"),
    route("help", "routes/help.tsx"),
    route("help/getting-started", "routes/help.getting-started.tsx"),
    route("help/faqs", "routes/help.faqs.tsx"),
    route("help/contact", "routes/help.contact.tsx"),
    route("signin/*", "routes/signin.tsx"),
    route("signout", "routes/signout.tsx"),

    route("account/delete", "routes/account.delete.tsx"),
    route("twister/login", "routes/twister.login.tsx"),
  ]),
] satisfies RouteConfig;
