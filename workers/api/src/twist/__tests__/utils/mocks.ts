/**
 * Mock DurableObject Storage
 */
export function createMockStorage(): DurableObjectStorage {
  const store = new Map<string, any>();

  return {
    get: (key: string) => Promise.resolve(store.get(key)),
    put: (key: string, value: any) => {
      store.set(key, value);
      return Promise.resolve();
    },
    delete: (key: string) => {
      const existed = store.has(key);
      store.delete(key);
      return Promise.resolve(existed);
    },
    list: () => Promise.resolve(store),
    deleteAll: () => {
      store.clear();
      return Promise.resolve();
    },
  } as any;
}

/**
 * Mock DurableObject stub for CallbacksState
 */
export function createMockCallbacksStub(): DurableObjectStub {
  const storage = createMockStorage();

  return {
    id: { toString: () => "mock-callbacks-id" } as any,
    fetch: async (request: Request) => {
      const url = new URL(request.url);
      const method = request.method;

      if (method === "POST" && url.pathname === "/create") {
        const body = await request.json();
        const token = `cb_${Math.random().toString(36).slice(2)}`;
        await storage.put(token, body);
        return new Response(JSON.stringify({ token }), { status: 200 });
      }

      if (method === "POST" && url.pathname === "/call") {
        const _body = await request.json();
        return new Response(JSON.stringify({ result: "success" }), { status: 200 });
      }

      if (method === "DELETE") {
        const token = url.searchParams.get("token");
        if (token) {
          await storage.delete(token);
        }
        return new Response(null, { status: 204 });
      }

      return new Response("Not found", { status: 404 });
    },
  } as any;
}

/**
 * Mock DurableObject stub for LogSubscriptions
 */
export function createMockLogSubscriptionsStub(): DurableObjectStub {
  return {
    id: { toString: () => "mock-logs-id" } as any,
    fetch: async () => new Response(JSON.stringify({ logs: [] }), { status: 200 }),
  } as any;
}

/**
 * Mock R2 bucket with twist modules
 */
export function createMockR2Bucket(modules: Record<string, string> = {}): R2Bucket {
  return {
    get: async (key: string) => {
      const content = modules[key];
      if (!content) return null;

      return {
        body: new ReadableStream({
          start(controller) {
            controller.enqueue(new TextEncoder().encode(content));
            controller.close();
          },
        }),
        arrayBuffer: async () => new TextEncoder().encode(content).buffer,
        text: async () => content,
        json: async () => JSON.parse(content),
      } as any;
    },
    put: async () => null as any,
    delete: async () => {},
    list: async () => ({ objects: [], truncated: false, cursor: "" }) as any,
  } as any;
}

/**
 * Mock ExecutionContext for Cloudflare Workers
 */
export function createMockExecutionContext(): ExecutionContext {
  const waitUntilPromises: Promise<any>[] = [];

  return {
    waitUntil: (promise: Promise<any>) => {
      waitUntilPromises.push(promise);
    },
    passThroughOnException: () => {},
    abort: () => {},
  } as any;
}

/**
 * Mock HTTP Response for Network tool
 */
export function createMockResponse(
  body: any,
  options?: { status?: number; headers?: Record<string, string> }
): Response {
  return new Response(JSON.stringify(body), {
    status: options?.status ?? 200,
    headers: {
      "Content-Type": "application/json",
      ...options?.headers,
    },
  });
}

/**
 * Mock fetch function
 */
export function createMockFetch(
  responses: Record<string, Response | ((request: Request) => Response | Promise<Response>)>
): typeof fetch {
  return async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;

    const response = responses[url];
    if (!response) {
      return new Response("Not found", { status: 404 });
    }

    if (typeof response === "function") {
      const request = new Request(input, init);
      return response(request);
    }

    return response;
  };
}

/**
 * Mock DurableObjectNamespace
 */
export function createMockDurableObjectNamespace(
  stubFactory: () => DurableObjectStub
): DurableObjectNamespace<any> {
  return {
    idFromName: (name: string) => ({ toString: () => name }) as any,
    get: (_id: DurableObjectId) => stubFactory(),
    idFromString: (id: string) => ({ toString: () => id }) as any,
    newUniqueId: () => ({ toString: () => `unique-${Math.random()}` }) as any,
  } as any;
}

/**
 * Mock Cloudflare environment bindings
 */
export function createMockEnv(overrides?: Partial<Env>): Env {
  return {
    TWIST_MODULES: createMockR2Bucket(),
    CALLBACKS_STATE: createMockDurableObjectNamespace(createMockCallbacksStub),
    STORAGE: createMockDurableObjectNamespace(() => ({
      id: { toString: () => "mock-storage-id" } as any,
      fetch: async () => new Response("OK"),
      get: async (_key: string) => null,
      set: async () => {},
      clear: async () => {},
      clearAll: async () => {},
    }) as any),
    CALLBACKS: createMockDurableObjectNamespace(createMockCallbacksStub),
    LOG_SUBSCRIPTIONS: createMockDurableObjectNamespace(createMockLogSubscriptionsStub),
    USAGE: createMockDurableObjectNamespace(() => ({
      id: { toString: () => "mock-usage-id", name: "mock-priority-twist-id" } as any,
      fetch: async () => new Response("OK"),
      init: (_priorityTwistId: string) => Promise.resolve(),
      spend: () => {},
    }) as any),
    TWIST_LOGS_QUEUE: { send: () => Promise.resolve() } as any,
    TWIST_TASKS_QUEUE: { send: () => Promise.resolve() } as any,
    RUN_QUEUE: { send: () => Promise.resolve() } as any,
    TWIST_CONFIG: {
      get: async () => null,
      put: async () => {},
    } as any,
    LOADER: {
      get: async (_moduleId: string, loader: () => Promise<any>) => {
        const result = await loader();
        // Return a Worker instance with getEntrypoint method
        return {
          getEntrypoint: () => result,
        };
      },
    } as any,
    TWIST_MODULES_BUCKET: createMockR2Bucket(),
    ...overrides,
  } as Env;
}
