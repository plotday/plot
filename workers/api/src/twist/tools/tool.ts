import { RpcTarget } from "cloudflare:workers";

export class Tool extends RpcTarget {
  constructor() {
    super();
  }

  callCallback(name: string, ...args: any[]): Promise<any> {
    const fn = (this as any)[name];
    if (typeof fn !== "function") {
      throw new Error(`Callback function '${name}' not found on tool.`);
    }
    return fn.call(this, ...args);
  }

  tryCallCallback(name: string, ...args: any[]): Promise<any> {
    const fn = (this as any)[name];
    if (typeof fn !== "function") {
      return Promise.resolve(undefined);
    }
    return fn.call(this, ...args);
  }

  /**
   * Dispatches an event to callbacks configured via tool options.
   * Built-in tools override this to implement event routing.
   *
   * Returns an array of dispatch entries. Each entry uses one of:
   * - `optionPath`: navigates the options object to find a callback (legacy Twist pattern)
   * - `sourceMethod`: calls a method directly on the Source instance (new Source pattern)
   *
   * @returns Array of callbacks to invoke in twist worker (empty array if none)
   */
  async dispatch(
    ..._args: any[]
  ): Promise<Array<{ optionPath?: string[]; sourceMethod?: string; args: any[] }>> {
    // Default no-op - built-in tools override as needed
    return [];
  }
}
