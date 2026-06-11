import { afterEach, describe, expect, it, vi } from "vitest";
import {
  enrichLinkContactsFromOutlook,
  lookupOutlookPeople,
  OUTLOOK_PEOPLE_SCOPES,
} from "./enrich";
import type { NewLinkWithNotes } from "@plotday/twister/plot";

afterEach(() => vi.unstubAllGlobals());

function stubFetch(handler: (url: string) => unknown) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: string | URL) => {
      const url = String(input);
      const body = handler(url);
      if (body === null) return new Response("denied", { status: 403 });
      return Response.json(body);
    })
  );
}

describe("lookupOutlookPeople", () => {
  it("resolves names via the People API", async () => {
    stubFetch((url) =>
      url.includes("/me/people")
        ? {
            value: [
              {
                displayName: "Ann Example",
                scoredEmailAddresses: [{ address: "ann@x.com" }],
              },
            ],
          }
        : { value: [] }
    );
    const map = await lookupOutlookPeople("tok", OUTLOOK_PEOPLE_SCOPES, [
      "Ann@X.com",
    ]);
    expect(map["ann@x.com"]).toEqual({ name: "Ann Example" });
  });

  it("falls back to /me/contacts and swallows 403s", async () => {
    stubFetch((url) =>
      url.includes("/me/people")
        ? null // 403 — e.g. consumer account limitation
        : {
            value: [
              {
                displayName: "Bob Contact",
                emailAddresses: [{ address: "bob@y.com" }],
              },
            ],
          }
    );
    const map = await lookupOutlookPeople("tok", OUTLOOK_PEOPLE_SCOPES, [
      "bob@y.com",
    ]);
    expect(map["bob@y.com"]).toEqual({ name: "Bob Contact" });
  });

  it("skips lookups when scopes are missing", async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    const map = await lookupOutlookPeople("tok", [], ["a@b.c"]);
    expect(map).toEqual({});
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});

describe("enrichLinkContactsFromOutlook", () => {
  it("fills missing names in place, preserving existing ones", async () => {
    stubFetch((url) =>
      url.includes("/me/people")
        ? {
            value: [
              {
                displayName: "Ann Example",
                scoredEmailAddresses: [{ address: "ann@x.com" }],
              },
            ],
          }
        : { value: [] }
    );
    const link: NewLinkWithNotes = {
      type: "email",
      title: "t",
      accessContacts: [
        { email: "ann@x.com" },
        { email: "bob@y.com", name: "Keep Me" },
      ],
      notes: [{ author: { email: "ann@x.com" }, content: "x" }],
    };
    await enrichLinkContactsFromOutlook([link], "tok", OUTLOOK_PEOPLE_SCOPES);
    expect((link.accessContacts![0] as { name?: string }).name).toBe(
      "Ann Example"
    );
    expect((link.accessContacts![1] as { name?: string }).name).toBe("Keep Me");
    expect(
      (link.notes![0] as { author: { name?: string } }).author.name
    ).toBe("Ann Example");
  });
});
