import {
  type RouteConfig,
  index,
  layout,
  route,
} from "@react-router/dev/routes";

export default [
  layout("./components/public-layout.tsx", [
    index("routes/home.tsx"),
    route("start", "routes/start.tsx"),
    route("start-done", "routes/start-done.tsx"),
    route("terms", "routes/terms.tsx"),
    route("privacy", "routes/privacy.tsx"),
    route("signin", "routes/signin.tsx"),
    route("signout", "routes/signout.tsx"),
    route("auth/callback", "routes/auth.callback.tsx"),
    route("builder/login", "routes/builder.login.tsx"),
  ]),
] satisfies RouteConfig;
