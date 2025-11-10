/**
 * Mock for cloudflare:workers module
 * This provides stub implementations for Cloudflare Workers runtime classes
 */

export class WorkerEntrypoint {
  constructor(
    public ctx: any,
    public env: any
  ) {}

  async fetch(_request: Request): Promise<Response> {
    return new Response("OK");
  }
}

export class DurableObject {
  constructor(
    public ctx: any,
    public env: any
  ) {}
}

export class RpcTarget {
  // Base class for RPC targets
}
