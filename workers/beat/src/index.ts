// Extend CacheStorage to include the default cache
declare const caches: CacheStorage & { default: Cache };

export interface Env {
  readonly POSTHOG_HOST: string;
  readonly POSTHOG_ASSET_HOST: string;
}

async function handleRequest(
  request: Request,
  ctx: ExecutionContext,
  env: Env
): Promise<Response> {
  const url = new URL(request.url);
  const pathname = url.pathname;
  const search = url.search;
  const pathWithParams = pathname + search;

  if (pathname.startsWith("/static/")) {
    return retrieveStatic(request, pathWithParams, ctx, env);
  } else {
    return forwardRequest(request, pathWithParams, env);
  }
}

async function retrieveStatic(
  request: Request,
  pathname: string,
  ctx: ExecutionContext,
  env: Env
): Promise<Response> {
  const cache = caches.default;
  let response = await cache.match(request);
  if (!response) {
    response = await fetch(`${env.POSTHOG_ASSET_HOST}${pathname}`);
    ctx.waitUntil(cache.put(request, response.clone()));
  }
  return response;
}

async function forwardRequest(
  request: Request,
  pathWithSearch: string,
  env: Env
): Promise<Response> {
  // Create a new request with the PostHog host URL
  const newUrl = `${env.POSTHOG_HOST}${pathWithSearch}`;
  const proxyRequest = new Request(newUrl, request);

  // Remove cookie header to avoid leaking user cookies to PostHog
  proxyRequest.headers.delete("cookie");

  return await fetch(proxyRequest);
}

export default {
  async fetch(request, env, ctx) {
    return handleRequest(request, ctx, env);
  },
} satisfies ExportedHandler<Env>;
