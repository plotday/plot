import type { Channel } from "@plotday/twister/tools/integrations";

import { namespace } from "./product-channel";
import type { AppleProduct } from "./products";

/**
 * Namespace a channel id (and its children) with the product key and attach the
 * product's link types. Title stays un-prefixed.
 */
function prefixChannel(
  productKey: string,
  channel: Channel,
  linkTypes: AppleProduct["linkTypes"]
): Channel {
  return {
    ...channel,
    id: namespace(productKey, channel.id),
    linkTypes,
    ...(channel.children
      ? {
          children: channel.children.map((child) =>
            prefixChannel(productKey, child, linkTypes)
          ),
        }
      : {}),
  };
}

/**
 * Enumerate every product's channels concurrently, then namespace and
 * link-type each. Pure — inject fake products in tests.
 */
export async function composeChannels(
  products: AppleProduct[]
): Promise<Channel[]> {
  const perProduct = await Promise.all(
    products.map((product) => product.getRawChannels())
  );
  const result: Channel[] = [];
  products.forEach((product, i) => {
    for (const raw of perProduct[i]) {
      result.push(prefixChannel(product.key, raw, product.linkTypes));
    }
  });
  return result;
}
