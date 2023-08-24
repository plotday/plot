import sentryPlugin from "@cloudflare/pages-plugin-sentry";

import { SentryServerOptions } from "app/sentry.server";

export const onRequest: PagesFunction<{
  SENTRY_DSN: string;
}> = (context) => {
  // @ts-ignore
  return sentryPlugin({
    dsn: context.env.SENTRY_DSN,
    ...SentryServerOptions,
  })(context);
};
