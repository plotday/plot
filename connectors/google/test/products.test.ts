import { describe, it, expect, vi, afterEach } from "vitest";
import type { AuthToken } from "@plotday/twister/tools/integrations";
import {
  GMAIL_MODIFY_SCOPE,
  GMAIL_LINK_TYPES,
} from "../src/mail/channels";
import {
  TASKS_SCOPE,
  TASKS_LINK_TYPES,
} from "../src/tasks/channels";
import { CONTACTS_SCOPES } from "@plotday/google-contacts";
import { mailProduct } from "../src/products";
import { tasksProduct } from "../src/products";
import { contactsProduct } from "../src/products";
import { PRODUCTS_BY_KEY } from "../src/products";
import { composeChannels } from "../src/compose";

function makeToken(scopes: string[]): AuthToken {
  return {
    accessToken: "fake",
    token: "fake-token",
    scopes,
  } as unknown as AuthToken;
}

// ---------------------------------------------------------------------------
// mail product
// ---------------------------------------------------------------------------

describe("mailProduct", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("requiredScopes equals [GMAIL_MODIFY_SCOPE]", () => {
    expect(mailProduct.requiredScopes).toEqual([GMAIL_MODIFY_SCOPE]);
  });

  it("linkTypes equals GMAIL_LINK_TYPES", () => {
    expect(mailProduct.linkTypes).toBe(GMAIL_LINK_TYPES);
  });

  it("linkTypes contains an email type", () => {
    const emailType = mailProduct.linkTypes.find((lt) => lt.type === "email");
    expect(emailType).toBeDefined();
  });

  it("getRawChannels returns mapped channels from gmail labels API", async () => {
    const fakeLabels = {
      labels: [
        { id: "INBOX", name: "Inbox", type: "system" },
        { id: "SENT", name: "Sent", type: "system" },
        { id: "DRAFT", name: "Draft", type: "system" },
        { id: "custom1", name: "My Label", type: "user" },
      ],
    };
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => fakeLabels,
      text: async () => JSON.stringify(fakeLabels),
    }));

    const token = makeToken([GMAIL_MODIFY_SCOPE]);
    const channels = await mailProduct.getRawChannels(token);

    // INBOX + SENT + DRAFT + custom label (IMPORTANT/STARRED filtered out since not in fake data)
    expect(channels.length).toBe(4);
    const inbox = channels.find((c) => c.id === "INBOX");
    expect(inbox).toBeDefined();
    expect(inbox?.enabledByDefault).toBe(true);
    const sent = channels.find((c) => c.id === "SENT");
    expect(sent?.enabledByDefault).toBe(true);
    const draft = channels.find((c) => c.id === "DRAFT");
    expect(draft?.enabledByDefault).toBe(false);
  });

  it("composeChannels namespaces mail channel ids with 'mail:' prefix", async () => {
    const fakeLabels = {
      labels: [{ id: "INBOX", name: "Inbox", type: "system" }],
    };
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => fakeLabels,
      text: async () => JSON.stringify(fakeLabels),
    }));

    const token = makeToken([GMAIL_MODIFY_SCOPE]);
    const channels = await composeChannels(Object.values(PRODUCTS_BY_KEY), token);

    const inbox = channels.find((c) => c.id === "mail:INBOX");
    expect(inbox).toBeDefined();
    expect(inbox?.linkTypes?.some((lt) => lt.type === "email")).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// tasks product
// ---------------------------------------------------------------------------

describe("tasksProduct", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("requiredScopes equals [TASKS_SCOPE]", () => {
    expect(tasksProduct.requiredScopes).toEqual([TASKS_SCOPE]);
  });

  it("linkTypes equals TASKS_LINK_TYPES", () => {
    expect(tasksProduct.linkTypes).toBe(TASKS_LINK_TYPES);
  });

  it("linkTypes contains a task type", () => {
    const taskType = tasksProduct.linkTypes.find((lt) => lt.type === "task");
    expect(taskType).toBeDefined();
  });

  it("getRawChannels maps task lists to channels", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        items: [
          { id: "list1", title: "My Tasks", selfLink: "https://tasks.googleapis.com/..." },
          { id: "list2", title: "Shopping", selfLink: "https://tasks.googleapis.com/..." },
        ],
        kind: "tasks#taskLists",
      }),
    }));

    const token = makeToken([TASKS_SCOPE]);
    const channels = await tasksProduct.getRawChannels(token);

    expect(channels).toHaveLength(2);
    expect(channels[0]).toEqual({ id: "list1", title: "My Tasks" });
    expect(channels[1]).toEqual({ id: "list2", title: "Shopping" });
  });

  it("composeChannels namespaces task channel ids with 'tasks:' prefix", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        items: [{ id: "list1", title: "My Tasks", selfLink: "" }],
        kind: "tasks#taskLists",
      }),
    }));

    const token = makeToken([TASKS_SCOPE]);
    const channels = await composeChannels(Object.values(PRODUCTS_BY_KEY), token);

    const taskChannel = channels.find((c) => c.id === "tasks:list1");
    expect(taskChannel).toBeDefined();
    expect(taskChannel?.linkTypes?.some((lt) => lt.type === "task")).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// contacts product
// ---------------------------------------------------------------------------

describe("contactsProduct", () => {
  it("requiredScopes equals CONTACTS_SCOPES", () => {
    expect(contactsProduct.requiredScopes).toEqual(CONTACTS_SCOPES);
  });

  it("linkTypes is empty array", () => {
    expect(contactsProduct.linkTypes).toEqual([]);
  });

  it("channelless is true", () => {
    expect(contactsProduct.channelless).toBe(true);
  });

  it("getRawChannels returns a single contacts channel (no network)", async () => {
    const token = makeToken(CONTACTS_SCOPES);
    const channels = await contactsProduct.getRawChannels(token);

    expect(channels).toHaveLength(1);
    expect(channels[0].id).toBe("contacts");
    expect(channels[0].title).toBe("Contacts");
  });

  it("composeChannels namespaces contacts channel as 'contacts:contacts'", async () => {
    const token = makeToken(CONTACTS_SCOPES);
    const channels = await composeChannels(Object.values(PRODUCTS_BY_KEY), token);

    const contactsChannel = channels.find((c) => c.id === "contacts:contacts");
    expect(contactsChannel).toBeDefined();
    // Contacts has no link types, so linkTypes should be empty
    expect(contactsChannel?.linkTypes).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// PRODUCTS_BY_KEY registry
// ---------------------------------------------------------------------------

describe("PRODUCTS_BY_KEY", () => {
  it("contains all four product keys: mail, calendar, tasks, contacts", () => {
    expect(Object.keys(PRODUCTS_BY_KEY).sort()).toEqual(
      ["calendar", "contacts", "mail", "tasks"].sort()
    );
  });

  it("mail key points to mailProduct", () => {
    expect(PRODUCTS_BY_KEY.mail).toBe(mailProduct);
  });

  it("tasks key points to tasksProduct", () => {
    expect(PRODUCTS_BY_KEY.tasks).toBe(tasksProduct);
  });

  it("contacts key points to contactsProduct", () => {
    expect(PRODUCTS_BY_KEY.contacts).toBe(contactsProduct);
  });
});

// ---------------------------------------------------------------------------
// Per-product source names
//
// The Google connector's display name is "Gmail & Calendar". Each product's
// link types must carry a `sourceName` so the Plot app shows the right
// per-product brand in "{source} {type}" copy (thread type name, compose
// picker) instead of the aggregate connector name.
// ---------------------------------------------------------------------------

describe("product source names", () => {
  it("every mail link type declares sourceName 'Gmail'", () => {
    expect(mailProduct.linkTypes.length).toBeGreaterThan(0);
    for (const lt of mailProduct.linkTypes) {
      expect(lt.sourceName).toBe("Gmail");
    }
  });

  it("every calendar link type declares sourceName 'Google Calendar'", () => {
    expect(PRODUCTS_BY_KEY.calendar.linkTypes.length).toBeGreaterThan(0);
    for (const lt of PRODUCTS_BY_KEY.calendar.linkTypes) {
      expect(lt.sourceName).toBe("Google Calendar");
    }
  });

  it("every task link type declares sourceName 'Google Tasks'", () => {
    expect(tasksProduct.linkTypes.length).toBeGreaterThan(0);
    for (const lt of tasksProduct.linkTypes) {
      expect(lt.sourceName).toBe("Google Tasks");
    }
  });
});
