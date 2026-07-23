import { describe, expect, it } from "vitest";

import { Apple } from "./apple";
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

describe("Apple.getAccountIdentity", () => {
  // getAccountIdentity is a matchable-identity hook (unlike getAccountName,
  // display-only) the runtime uses to link the connected Apple ID's email to
  // the signed-in Plot user — see AGENTS.md's runtime owner-identity recon
  // and getAccountIdentity's JSDoc in @plotday/twister/connector.
  function makeSelf(appleId: string | undefined) {
    return { tools: { options: { appleId } } } as unknown as Apple;
  }

  it("returns the configured Apple ID as the identity email", async () => {
    const result = await Apple.prototype.getAccountIdentity.call(
      makeSelf("me@icloud.com")
    );
    expect(result).toEqual({ email: "me@icloud.com" });
  });

  it("returns null when no Apple ID is configured yet", async () => {
    const result = await Apple.prototype.getAccountIdentity.call(makeSelf(""));
    expect(result).toBeNull();
  });

  it("returns null when the Apple ID option is unset", async () => {
    const result = await Apple.prototype.getAccountIdentity.call(
      makeSelf(undefined)
    );
    expect(result).toBeNull();
  });
});
