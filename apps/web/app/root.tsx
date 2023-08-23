import { useEffect, useMemo } from "react";

import type {
  LinksFunction,
  LoaderArgs,
  V2_MetaFunction,
} from "@remix-run/cloudflare";
import { json } from "@remix-run/cloudflare";
import { cssBundleHref } from "@remix-run/css-bundle";
import {
  Links,
  LiveReload,
  Meta,
  Outlet,
  Scripts,
  ScrollRestoration,
  isRouteErrorResponse,
  useLoaderData,
  useOutletContext,
  useRevalidator,
  useRouteError,
} from "@remix-run/react";

import type { SupabaseClient } from "@supabase/auth-helpers-remix";
import { createBrowserClient } from "@supabase/auth-helpers-remix";

import {
  ColorSchemeScript,
  Container,
  MantineProvider,
  Text,
  Title,
} from "@mantine/core";
import "@mantine/core/styles.css";

import type { Database } from "@plotday/db";

import { authCookieOptions, getUser } from "./auth";
import { APP_NAME } from "./config";
import { createServerClient } from "./db";
import { getBrowserEnv } from "./env";
import {
  Sentry,
  SentryClientInit,
  SentryServerInit,
  captureRemixErrorBoundaryError,
} from "./sentry";
import { resolver, theme } from "./theme";

export const loader = async ({ context, request }: LoaderArgs) => {
  // Can't use getEnv here since we don't want to fail if missing variables
  const SENTRY_DSN = (context.env as any)?.SENTRY_DSN;
  if (SENTRY_DSN) SentryServerInit(SENTRY_DSN, request);

  const { response, supabase } = createServerClient(request, context);

  const {
    data: { session },
  } = await supabase.auth.getSession();
  const user = await getUser(supabase);
  if (user && Sentry) {
    Sentry.setUser({
      id: user.id.toString(),
      ...(user.email ? { email: user.email } : {}),
    });
  }

  return json(
    {
      env: getBrowserEnv(context),
      session,
      user,
    },
    {
      headers: response.headers,
    }
  );
};

export const meta: V2_MetaFunction = () => {
  return [{ title: APP_NAME }];
};

export const links: LinksFunction = () => [
  ...(cssBundleHref ? [{ rel: "stylesheet", href: cssBundleHref }] : []),
];

function Page({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />

        <link
          rel="icon"
          type="image/png"
          sizes="32x32"
          href="/assets/favicon-32x32.png?v=20230809b"
        />
        <link
          rel="icon"
          type="image/png"
          sizes="16x16"
          href="/assets/favicon-16x16.png?v=20230809b"
        />
        <link rel="icon" type="image/svg+xml" href="/assets/favicon.svg" />
        <link rel="manifest" href="/site.webmanifest" />
        <link
          rel="apple-touch-icon"
          sizes="180x180"
          href="/assets/apple-touch-icon.png?v=20230809b"
        />
        <link
          rel="mask-icon"
          href="/assets/safari-pinned-tab.svg?v=20230809b"
          color="#239870"
        />
        <link rel="shortcut icon" href="/favicon.ico?v=20230809b" />
        <meta name="apple-mobile-web-app-title" content="Plot" />
        <meta name="application-name" content="Plot" />
        <meta name="msapplication-TileColor" content="#239870" />
        <meta name="theme-color" content="#239870" />

        <Meta />
        <Links />
        <ColorSchemeScript />
      </head>
      <body>
        <MantineProvider theme={theme} cssVariablesResolver={resolver}>
          {children}
          <ScrollRestoration />
          <Scripts />
          <LiveReload />
        </MantineProvider>
      </body>
    </html>
  );
}

export function ErrorBoundary() {
  const error = useRouteError();

  let title = "Something went wrong";
  let message;
  if (isRouteErrorResponse(error)) {
    title = "Page not found";
  } else {
    captureRemixErrorBoundaryError(error);
    if (error instanceof Error) {
      console.log("message", error.message);
      console.log("stack", error.stack);
      if (error.stack) {
        message = error.stack;
      } else {
        message = error.message;
      }
    } else if (typeof error === "string") {
      message = error;
    } else if (
      error &&
      typeof error === "object" &&
      "message" in error &&
      typeof error.message === "string"
    ) {
      message = error.message;
    } else {
      message = "Unknown error";
    }
  }
  return (
    <Page>
      <Container mt="xl">
        <Title mb="md">{title}</Title>
        {message?.split?.("\n").map((line, i) => (
          <Text key={i}>{line}</Text>
        ))}
      </Container>
    </Page>
  );
}

type Nullable<T> = { [K in keyof T]: T[K] | null };
export type ContextType = {
  supabase?: SupabaseClient<Database>;
  user?: Nullable<Partial<Database["public"]["Tables"]["user"]["Row"]>>;
};

export default function App() {
  const { env, user, session } = useLoaderData<typeof loader>();

  if (!Sentry && env.SENTRY_DSN) {
    SentryClientInit(env.SENTRY_DSN, user);
  }

  const supabase = useMemo(() => {
    if (typeof document === "undefined") return null;
    try {
      return createBrowserClient<Database, "public">(
        env.SUPABASE_URL,
        env.SUPABASE_ANON_KEY,
        {
          // @ts-ignore
          auth: { flowType: "pkce" },
          cookieOptions: authCookieOptions,
        }
      );
    } catch (error) {
      console.error(error);
      return null;
    }
  }, [env]);

  const { revalidate } = useRevalidator();
  useEffect(() => {
    if (!supabase) return;
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event, _session) => {
      switch (event) {
        case "SIGNED_OUT":
          revalidate();
          break;
      }
    });

    return () => {
      subscription.unsubscribe();
    };
  }, [session?.access_token, supabase, revalidate]);

  const context: ContextType = useMemo(
    () => ({ supabase: supabase || undefined, user: user || undefined }),
    [supabase, user]
  );

  return (
    <Page>
      <Outlet context={context} />
    </Page>
  );
}

export function useSupabase() {
  const { supabase } = useOutletContext<ContextType>();
  return supabase;
}

export function useUser() {
  const { user } = useOutletContext<ContextType>();
  return user;
}

export function useTz() {
  const user = useUser();
  const tz = user?.timezone;
  if (!tz) {
    throw new Error("Missing timezone");
  }
  return tz;
}
