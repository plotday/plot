import { useEffect, useMemo } from "react";

import type { LinksFunction, MetaFunction } from "@remix-run/cloudflare";
import { cssBundleHref } from "@remix-run/css-bundle";
import {
  Links,
  LiveReload,
  Meta,
  Outlet,
  Scripts,
  ScrollRestoration,
  useRevalidator,
} from "@remix-run/react";

import { createBrowserClient } from "@supabase/auth-helpers-remix";

import {
  Anchor,
  ColorSchemeScript,
  Container,
  MantineProvider,
  Text,
} from "@mantine/core";
import "@mantine/core/styles.css";

import { typedjson, useTypedLoaderData } from "remix-typedjson";

import type { Database } from "@plotday/db";

import { APP_NAME } from "app/config";
import { getBrowserEnv } from "app/env.server";
import { ErrorPage } from "app/error";
import type { ContextType } from "app/hooks";
import { init as sentryInit } from "app/sentry.client";
import { publicLoader } from "app/util";

import { authCookieOptions } from "./auth";
import { resolver, theme } from "./theme";

export const loader = publicLoader(
  async ({ context, user, waitlistedUser, response, supabase }) => {
    const {
      data: { session },
    } = await supabase.auth.getSession();
    return typedjson(
      {
        env: getBrowserEnv(context),
        session,
        user,
        waitlistedUser,
      },
      {
        headers: response.headers,
      }
    );
  }
);

export const meta: MetaFunction = () => {
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
        <ColorSchemeScript defaultColorScheme="auto" />
      </head>
      <body>
        <MantineProvider
          theme={theme}
          cssVariablesResolver={resolver}
          defaultColorScheme="auto"
        >
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
  return (
    <Page>
      <Container mt="xl">
        <ErrorPage>
          <Text>
            Please <Anchor href="/">give it another try</Anchor>.
          </Text>
        </ErrorPage>
      </Container>
    </Page>
  );
}

export default function App() {
  const { env, user, waitlistedUser, session } =
    useTypedLoaderData<typeof loader>();

  if (sentryInit && env.SENTRY_DSN && user) {
    sentryInit(env.SENTRY_DSN, user);
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
    () => ({
      supabase: supabase ?? undefined,
      user: user ?? undefined,
      waitlistedUser: waitlistedUser ?? undefined,
    }),
    [supabase, user, waitlistedUser]
  );

  return (
    <Page>
      <Outlet context={context} />
    </Page>
  );
}
