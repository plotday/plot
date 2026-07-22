import { describe, expect, it } from "vitest";

import { composeChannels } from "./compose";
import type { AppleProduct } from "./products";

describe("composeChannels", () => {
  it("namespaces each product's channels and attaches its link types", async () => {
    const fakeProducts: AppleProduct[] = [
      {
        key: "calendar",
        linkTypes: [{ type: "event", label: "Event" }],
        getRawChannels: async () => [{ id: "/cal/home/", title: "Home" }],
      },
      {
        key: "mail",
        linkTypes: [{ type: "email", label: "Email" }],
        getRawChannels: async () => [],
      },
    ];

    const channels = await composeChannels(fakeProducts);

    expect(channels).toHaveLength(1);
    expect(channels[0].id).toBe("calendar:/cal/home/");
    expect(channels[0].title).toBe("Home");
    expect(channels[0].linkTypes).toEqual([{ type: "event", label: "Event" }]);
  });
});
