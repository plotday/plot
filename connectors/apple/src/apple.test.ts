import { describe, expect, it } from "vitest";

import { composeChannels } from "./compose";
import { appleProducts } from "./products";
import { parse } from "./product-channel";

describe("Apple composite wiring", () => {
  it("emits namespaced calendar channels and no mail channels (stub)", async () => {
    const products = appleProducts({
      getCalendarChannels: async () => [
        { id: "/1234/calendars/home/", title: "Home" },
      ],
      getMailChannels: async () => [],
    });
    const channels = await composeChannels(products);
    expect(channels.map((c) => c.id)).toEqual(["calendar:/1234/calendars/home/"]);
    expect(parse(channels[0].id).product).toBe("calendar");
  });

  it("parses a namespaced calendar id back to its raw CalDAV href", () => {
    expect(parse("calendar:/1234/calendars/home/").rawId).toBe(
      "/1234/calendars/home/"
    );
  });
});
