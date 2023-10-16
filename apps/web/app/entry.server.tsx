import type {
  AppLoadContext,
  DataFunctionArgs,
  EntryContext,
} from "@remix-run/cloudflare";
import { RemixServer } from "@remix-run/react";

import isbot from "isbot";
import { renderToReadableStream } from "react-dom/server";

import type { Sentry } from "app/sentry.server";

export default async function handleRequest(
  request: Request,
  responseStatusCode: number,
  responseHeaders: Headers,
  remixContext: EntryContext,
  _context: AppLoadContext
) {
  const body = await renderToReadableStream(
    <RemixServer context={remixContext} url={request.url} />,
    {
      signal: request.signal,
      onError(error: unknown) {
        // Log streaming rendering errors from inside the shell
        console.error(error);
        responseStatusCode = 500;
      },
    }
  );

  if (isbot(request.headers.get("user-agent"))) {
    await body.allReady;
  }

  responseHeaders.set("Content-Type", "text/html");
  return new Response(body, {
    headers: responseHeaders,
    status: responseStatusCode,
  });
}

export function handleError(
  error: unknown,
  { request, context }: DataFunctionArgs
): void {
  console.error(error);
  // if (isRouteErrorResponse(error)) {
  //   console.error(`${error.status} ${error.statusText}`);
  if (!request.signal.aborted && error instanceof Error) {
    // TODO: Once Sentry supports Cloudflare Workers (replacing Toucan):
    // Sentry.captureRemixServerException(error, "remix.server", request);
    (context.sentry as Sentry)?.captureException?.(error);
  }
}
