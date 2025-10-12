import type { Webhook as IWebhook } from "@plotday/sdk/tools/webhook";

import { Callbacks } from "../../state/callbacks";
import { Tool } from "./tool";

export type WebhookRequest = {
  method: string;
  headers: Record<string, string>;
  params: Record<string, string>;
  body: any;
};

export class Webhook extends Tool implements IWebhook {
  private callbacks: DurableObjectStub<Callbacks>;
  private priorityAgentId: string;
  private baseUrl: string;
  private path: string[]; // path to the tool within the agent

  public static readonly PATH = "/hook/:token";

  private static GetStub(
    callbacks: DurableObjectNamespace<Callbacks>,
    priorityAgentId: string
  ) {
    const callbacksId = callbacks.idFromName(priorityAgentId);
    return callbacks.get(callbacksId);
  }

  static async Handle(
    callbacks: DurableObjectNamespace<Callbacks>,
    token: string,
    request: WebhookRequest
  ) {
    const { shardKey } = Callbacks.parseToken(token);
    const callbacksId = callbacks.idFromName(shardKey);
    const callbacksStub = callbacks.get(callbacksId);
    // @ts-ignore - TypeScript type recursion workaround
    return await callbacksStub.call(token, request);
  }

  constructor({
    callbacks,
    priorityAgentId,
    baseUrl,
    path,
  }: {
    callbacks: DurableObjectNamespace<Callbacks>;
    priorityAgentId: string;
    baseUrl: string;
    path: string[];
  }) {
    super();
    this.callbacks = Webhook.GetStub(callbacks, priorityAgentId);
    this.priorityAgentId = priorityAgentId;
    this.baseUrl = baseUrl;
    // remove final element, which is the ID of this tool
    this.path = path.slice(0, -1);
  }

  async create(callbackName: string, context?: any): Promise<string> {
    const token = await this.callbacks.create({
      priorityAgentId: this.priorityAgentId,
      path: this.path,
      functionName: callbackName,
      context,
    });
    return this.tokenToUrl(token);
  }

  async delete(url: string): Promise<void> {
    const token = this.urlToToken(url);
    if (!token) return;
    await this.callbacks.delete(token);
  }

  private tokenToUrl(token: string): string {
    return `${this.baseUrl}/hook/${token}`;
  }

  private urlToToken(url: string): string | null {
    const webhookPrefix = `${this.baseUrl}/hook/`;
    if (!url.startsWith(webhookPrefix)) {
      return null;
    }
    return url.substring(webhookPrefix.length);
  }
}
