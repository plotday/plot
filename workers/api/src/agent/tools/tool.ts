import { RpcTarget } from "cloudflare:workers";

export class Tool extends RpcTarget {
  constructor() {
    super();
  }

  call(name: string, args: any, context: any): Promise<any> {
    const fn = (this as any)[name];
    if (typeof fn !== "function") {
      return Promise.reject(`Callback function '${name}' not found on tool.`);
    }
    return fn.call(this, args, context);
  }
}
