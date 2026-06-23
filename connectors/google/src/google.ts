import { Connector } from "@plotday/twister";
import {
  AuthProvider,
  Integrations,
  type Authorization,
  type AuthToken,
  type Channel,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import type { ToolBuilder } from "@plotday/twister";
import { GOOGLE_SCOPES } from "./scopes";
import { composeChannels, resolveProductForChannelId } from "./compose";
import { parse } from "./product-channel";
import { PRODUCTS_BY_KEY } from "./products/product";

export class Google extends Connector<Google> {
  readonly provider = AuthProvider.Google;

  readonly dynamicLinkTypes = true;

  readonly scopes = GOOGLE_SCOPES;

  readonly channelNoun = { singular: "channel", plural: "channels" };

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
    };
  }

  async getChannels(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    if (!token) return [];
    return composeChannels(Object.values(PRODUCTS_BY_KEY), token);
  }

  async onChannelEnabled(
    channel: Channel,
    context?: SyncContext
  ): Promise<void> {
    const product = resolveProductForChannelId(
      Object.values(PRODUCTS_BY_KEY),
      channel.id
    );
    if (!product) return;
    const { rawId } = parse(channel.id);
    await product.onEnable(rawId, context);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    const product = resolveProductForChannelId(
      Object.values(PRODUCTS_BY_KEY),
      channel.id
    );
    if (!product) return;
    const { rawId } = parse(channel.id);
    await product.onDisable(rawId);
  }
}

export default Google;
