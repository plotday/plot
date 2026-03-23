import {
  Button,
  ColorSchemeScript,
  Container,
  MantineProvider,
  Stack,
  Text,
  Title,
  mantineHtmlProps,
  useComputedColorScheme,
} from "@mantine/core";
import "@mantine/core/styles.css";

import { ClerkProvider } from "@clerk/react-router";
import { rootAuthLoader } from "@clerk/react-router/ssr.server";
import { dark } from "@clerk/themes";

import {
  Link,
  Links,
  Meta,
  Outlet,
  Scripts,
  ScrollRestoration,
  isRouteErrorResponse,
  useRouteLoaderData,
} from "react-router";

import notFoundImage from "./assets/404.png";

import type { Route } from "./+types/root";
import stylesheet from "./app.css?url";
import { PostHogIdentify } from "./components/posthog-identify";
import { clerkAppearance, clerkDarkAppearance, resolver, theme } from "./theme";

export async function loader(args: Route.LoaderArgs) {
  return rootAuthLoader(args, ({ context }) => {
    return {
      posthogApiKey: (context.cloudflare.env as Record<string, string>).POSTHOG_API_KEY || "",
      posthogProxy: (context.cloudflare.env as Record<string, string>).POSTHOG_PROXY || "",
    };
  });
}

export const links: Route.LinksFunction = () => [
  { rel: "preconnect", href: "https://fonts.googleapis.com" },
  {
    rel: "preconnect",
    href: "https://fonts.gstatic.com",
    crossOrigin: "anonymous",
  },
  {
    rel: "stylesheet",
    href: "https://fonts.googleapis.com/css2?family=Instrument+Sans:ital,wght@0,400..700;1,400..700&display=swap",
  },
  { rel: "stylesheet", href: stylesheet },
];

export function meta(_: Route.MetaArgs) {
  return [
    {
      title: "Plot",
    },
  ];
}

export function Layout({ children }: { children: React.ReactNode }) {
  const data = useRouteLoaderData<typeof loader>("root");
  const posthogApiKey = data?.posthogApiKey || "";
  const posthogProxy = data?.posthogProxy || "";

  return (
    <html lang="en" {...mantineHtmlProps}>
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />

        <link
          rel="icon"
          type="image/png"
          href="/assets/favicon-96x96.png?v=20250908"
          sizes="96x96"
        />
        <link
          rel="icon"
          type="image/svg+xml"
          href="/assets/favicon.svg?v=20250908"
        />
        <link rel="shortcut icon" href="/assets/favicon.ico?v=20250908" />
        <link
          rel="apple-touch-icon"
          sizes="180x180"
          href="/assets/apple-touch-icon.png?v=20250908"
        />
        <meta name="apple-mobile-web-app-title" content="Plot" />
        <link rel="manifest" href="/site.webmanifest" />

        <Meta />
        <Links />
        <ColorSchemeScript defaultColorScheme="auto" />
        {posthogApiKey && posthogProxy && (
          <script
            dangerouslySetInnerHTML={{
              __html: `!function(t,e){var o,n,p,r;e.__SV||(window.posthog=e,e._i=[],e.init=function(i,s,a){function g(t,e){var o=e.split(".");2==o.length&&(t=t[o[0]],e=o[1]),t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}}(p=t.createElement("script")).type="text/javascript",p.async=!0,p.src=s.api_host.replace(".i.posthog.com","-assets.i.posthog.com")+"/static/array.js",(r=t.getElementsByTagName("script")[0]).parentNode.insertBefore(p,r);var u=e;for(void 0!==a?u=e[a]=[]:a="posthog",u.people=u.people||[],u.toString=function(t){var e="posthog";return"posthog"!==a&&(e+="."+a),t||(e+=" (stub)"),e},u.people.toString=function(){return u.toString(1)+".people (stub)"},o="init capture register register_once register_for_session unregister unregister_for_session getFeatureFlag getFeatureFlagPayload isFeatureEnabled reloadFeatureFlags updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures on onFeatureFlags onSessionId getSurveys getActiveMatchingSurveys renderSurvey canRenderSurvey getNextSurveyStep identify setPersonProperties group resetGroups setPersonPropertiesForFlags resetPersonPropertiesForFlags setGroupPropertiesForFlags resetGroupPropertiesForFlags reset get_distinct_id getGroups get_session_id get_session_replay_url alias set_config startSessionRecording stopSessionRecording sessionRecordingStarted captureException loadToolbar get_property getSessionProperty createPersonProfile opt_in_capturing opt_out_capturing has_opted_in_capturing has_opted_out_capturing clear_opt_in_out_capturing debug".split(" "),n=0;n<o.length;n++)g(u,o[n]);e._i.push([i,s,a])},e.__SV=1)}(document,window.posthog||[]);
              posthog.init('${posthogApiKey}',{
                api_host:'${posthogProxy}',
                person_profiles:'identified_only',
                capture_pageview:true,
                capture_pageleave:true
              })`,
            }}
          />
        )}
      </head>
      <body>
        <MantineProvider
          theme={theme}
          cssVariablesResolver={resolver}
          defaultColorScheme="auto"
        >
          {children}
        </MantineProvider>
        <ScrollRestoration />
        <Scripts />
      </body>
    </html>
  );
}

export default function App({ loaderData }: Route.ComponentProps) {
  const colorScheme = useComputedColorScheme("light");
  const isDark = colorScheme === "dark";

  return (
    <ClerkProvider
      loaderData={loaderData}
      appearance={{
        ...(isDark ? { baseTheme: dark } : {}),
        ...(isDark ? clerkDarkAppearance : clerkAppearance),
      }}
    >
      <Outlet />
      <PostHogIdentify />
    </ClerkProvider>
  );
}

export function ErrorBoundary({ error }: Route.ErrorBoundaryProps) {
  if (isRouteErrorResponse(error) && error.status === 404) {
    return (
      <Container size="xs" style={{ minHeight: "100dvh", display: "flex", alignItems: "center" }}>
        <Stack align="center" gap="xl" style={{ width: "100%" }}>
          <img
            src={notFoundImage}
            alt=""
            style={{ maxWidth: 300, width: "100%" }}
          />
          <Title order={1} ta="center" c="violet">
            Looks like we lost the plot!
          </Title>
          <Text ta="center" c="dimmed" fs="italic" size="lg">
            &ldquo;Not all those who wander are lost.&rdquo; &mdash; Tolkien
          </Text>
          <Button component={Link} to="/" size="md" variant="filled">
            Back to Plot
          </Button>
        </Stack>
      </Container>
    );
  }

  let message = "Oops!";
  let details = "An unexpected error occurred.";
  let stack: string | undefined;

  if (isRouteErrorResponse(error)) {
    message = "Error";
    details = error.statusText || details;
  } else if (import.meta.env.DEV && error && error instanceof Error) {
    details = error.message;
    stack = error.stack;
  }

  return (
    <main className="pt-16 p-4 container mx-auto">
      <h1>{message}</h1>
      <p>{details}</p>
      {stack && (
        <pre className="w-full p-4 overflow-x-auto">
          <code>{stack}</code>
        </pre>
      )}
    </main>
  );
}
