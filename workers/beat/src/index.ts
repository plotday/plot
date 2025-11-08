// Extend CacheStorage to include the default cache
declare const caches: CacheStorage & { default: Cache };

export interface Env {
  readonly POSTHOG_API_HOST: string;
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
  const originRequest = new Request(request);
  originRequest.headers.delete("cookie");
  return await fetch(`${env.POSTHOG_API_HOST}${pathWithSearch}`, originRequest);
}

export default {
  async fetch(request, env, ctx) {
    return handleRequest(request, ctx, env);
  },
} satisfies ExportedHandler<Env>;
