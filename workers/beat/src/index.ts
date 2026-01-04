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
  try {
    const url = new URL(request.url);
    const pathname = url.pathname;
    const search = url.search;
    const pathWithParams = pathname + search;

    if (pathname.startsWith("/static/")) {
      return await retrieveStatic(request, pathWithParams, ctx, env);
    } else {
      return await forwardRequest(request, pathWithParams, env);
    }
  } catch (error) {
    console.error("[handleRequest]", error);
    return new Response("Internal Server Error", { status: 500 });
  }
}

async function retrieveStatic(
  request: Request,
  pathname: string,
  ctx: ExecutionContext,
  env: Env
): Promise<Response> {
  try {
    const cache = caches.default;
    let response = await cache.match(request);
    if (!response) {
      response = await fetch(`${env.POSTHOG_ASSET_HOST}${pathname}`);
      ctx.waitUntil(cache.put(request, response.clone()));
    }
    return response;
  } catch (error) {
    console.error("[retrieveStatic]", error);
    return new Response("Static asset fetch error", { status: 500 });
  }
}

async function forwardRequest(
  request: Request,
  pathWithSearch: string,
  env: Env
): Promise<Response> {
  try {
    const newUrl = `${env.POSTHOG_HOST}${pathWithSearch}`;
    const proxyRequest = new Request(newUrl, request);

    proxyRequest.headers.delete("cookie");

    return await fetch(proxyRequest);
  } catch (error) {
    console.error("[forwardRequest]", error);
    return new Response("Proxy error", { status: 500 });
  }
}

export default {
  async fetch(request, env, ctx) {
    try {
      return await handleRequest(request, ctx, env);
    } catch (error) {
      console.error("[fetch]", error);
      return new Response("Internal Server Error", { status: 500 });
    }
  },
} satisfies ExportedHandler<Env>;
