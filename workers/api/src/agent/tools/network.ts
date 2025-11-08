import { type Network as INetwork } from "@plotday/agent/tools/network";

import { type AgentEnvironment } from "../../env";
import { type ToolPermission } from "../permissions";
import { CallbacksState } from "../../state/callbacks";
import { getRpcFunctionName } from "../../utils/rpc";
import { Tool } from "./tool";

export type NetworkOptions = {
  urls?: string[];
  callbacks?: DurableObjectNamespace<CallbacksState>;
  priorityAgentId?: string;
  agentId?: string;
  environment?: AgentEnvironment;
  baseUrl?: string;
  path?: string[];
};

export type WebhookRequest = {
  method: string;
  headers: Record<string, string>;
  params: Record<string, string>;
  body: any;
};

/**
 * Built-in tool for requesting HTTP access permissions and managing webhooks.
 */
export class Network extends Tool implements INetwork {
  private callbacks?: DurableObjectStub<CallbacksState>;
  private priorityAgentId?: string;
  private agentId?: string;
  private environment?: AgentEnvironment;
  private baseUrl?: string;
  private path?: string[];

  public static readonly PATH = "/hook/:token";

  private static GetStub(
    callbacks: DurableObjectNamespace<CallbacksState>,
    priorityAgentId: string
  ) {
    const callbacksId = callbacks.idFromName(priorityAgentId);
    return callbacks.get(callbacksId);
  }

  static async HandleWebhook(
    callbacks: DurableObjectNamespace<CallbacksState>,
    token: string,
    request: WebhookRequest
  ) {
    return await CallbacksState.CallCallback(callbacks, token, request);
  }

  /**
   * Returns permissions required by this Network tool instance.
   * @param options - Network tool options
   * @returns Array of ToolPermissions for the requested URLs
   */
  static Permissions(options?: NetworkOptions): ToolPermission[] {
    const urls = options?.urls || [];
    return urls.map((url) => ({
      domain: "network",
      entity: url,
      flags: ["use"] as const,
    }));
  }

  constructor(options?: NetworkOptions) {
    super();

    // Initialize webhook functionality if options provided
    if (options?.callbacks && options.priorityAgentId) {
      this.callbacks = Network.GetStub(
        options.callbacks,
        options.priorityAgentId
      );
      this.priorityAgentId = options.priorityAgentId;
      this.agentId = options.agentId;
      this.environment = options.environment;
      this.baseUrl = options.baseUrl;
      // Remove final element, which is the ID of this tool
      this.path = options.path?.slice(0, -1);
    }
  }

  async createWebhook<TCallback extends (request: any, ...args: any[]) => any>(
    options: {
      callback: TCallback;
      extraArgs?: TCallback extends (req: any, ...rest: infer R) => any
        ? R
        : [];
      provider?: any;
      authorization?: any;
    }
  ): Promise<string> {
    if (
      !this.callbacks ||
      !this.priorityAgentId ||
      !this.agentId ||
      !this.environment ||
      !this.baseUrl ||
      !this.path
    ) {
      throw new Error("Webhook functionality not initialized");
    }

    // Create callback token from the provided function
    // The callback is to a function on the parent, so use parent path
    const callbackFunctionName = await getRpcFunctionName(options.callback);
    if (!callbackFunctionName) {
      throw new Error(
        "Cannot create callback: function has no name. Use named functions or methods."
      );
    }
    const token = await this.callbacks.create({
      priorityAgentId: this.priorityAgentId,
      agentId: this.agentId,
      environment: this.environment,
      path: this.path.slice(0, -1), // Remove this tool from path to target parent
      functionName: callbackFunctionName,
      extraArgs: options.extraArgs || [],
    });
    return this.tokenToUrl(token);
  }

  async deleteWebhook(url: string): Promise<void> {
    if (!this.callbacks) {
      throw new Error("Webhook functionality not initialized");
    }

    const token = this.urlToToken(url);
    if (!token) return;
    await this.callbacks.delete(token);
  }

  private tokenToUrl(token: string): string {
    return `${this.baseUrl}/hook/${token}`;
  }

  private urlToToken(url: string): string | null {
    if (!this.baseUrl) return null;

    const webhookPrefix = `${this.baseUrl}/hook/`;
    if (!url.startsWith(webhookPrefix)) {
      return null;
    }
    return url.substring(webhookPrefix.length);
  }

}
