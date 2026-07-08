import { describe, it, expect, vi, beforeEach } from "vitest";

import type { Bindings } from "../env";

// The Unipile webhook handlers must ACK the sender immediately by enqueuing the
// connector callback onto WEBHOOK_QUEUE — NOT run the slow connector RPC inline
// (which coupled persistence to Unipile's delivery timeout and got the
// invocation canceled mid-save, stranding trailing messages). So invokeWebhookCallback
// must never be called on the producer path; the queue consumer runs it.
const { createDb } = vi.hoisted(() => ({ createDb: vi.fn() }));
vi.mock("../db", () => ({ createDb }));

const { invokeWebhookCallback } = vi.hoisted(() => ({
  invokeWebhookCallback: vi.fn(),
}));
vi.mock("../twist/invoke-webhook", () => ({ invokeWebhookCallback }));

// notify pulls in sync machinery not exercised here.
vi.mock("./sync/notify", () => ({ notifyUserSyncByEnv: vi.fn() }));

import {
  handleNewMessage,
  handleInvitationReceived,
  handleNewRelation,
} from "./hook-messaging";

const logger = {
  info: vi.fn(),
  warn: vi.fn(),
  error: vi.fn(),
} as any;

function fakeDb(channelRow: { twist_instance_id: string } | undefined) {
  return {
    selectFrom: () => ({
      select: () => ({
        where: () => ({ executeTakeFirst: async () => channelRow }),
      }),
    }),
    destroy: async () => {},
  };
}

function fakeEnv(token: string | null, send: ReturnType<typeof vi.fn>): Bindings {
  return {
    STORAGE: {
      idFromName: () => "storage-id",
      // loadConnectorCallback superjson.parse()s the raw value and falls back to
      // the raw string on parse failure — a plain token string exercises that path.
      get: () => ({ get: async () => token }),
    },
    WEBHOOK_QUEUE: { send },
  } as unknown as Bindings;
}

describe("Unipile webhook handlers enqueue connector callbacks (no inline RPC)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    createDb.mockReturnValue(fakeDb({ twist_instance_id: "ti_1" }));
  });

  it("handleNewMessage enqueues a connector-callback and never invokes inline", async () => {
    const send = vi.fn(async () => {});
    const env = fakeEnv("doid:tok", send);
    await handleNewMessage(
      env,
      {
        type: "message.new",
        account_id: "acc_1",
        payload: { chat_id: "chat_1", message_id: "msg_1" },
      } as any,
      logger
    );

    expect(invokeWebhookCallback).not.toHaveBeenCalled();
    expect(send).toHaveBeenCalledTimes(1);
    expect(send).toHaveBeenCalledWith({
      type: "connector-callback",
      token: "doid:tok",
      args: [{ kind: "message.received", chatId: "chat_1", messageId: "msg_1" }],
    });
  });

  it("handleInvitationReceived enqueues a connector-callback", async () => {
    const send = vi.fn(async () => {});
    const env = fakeEnv("doid:tok", send);
    await handleInvitationReceived(
      env,
      {
        type: "users.invitation.received",
        account_id: "acc_1",
        payload: { invitation_id: "inv_1" },
      } as any,
      logger
    );

    expect(invokeWebhookCallback).not.toHaveBeenCalled();
    expect(send).toHaveBeenCalledWith({
      type: "connector-callback",
      token: "doid:tok",
      args: [{ kind: "invitation.received", invitationId: "inv_1" }],
    });
  });

  it("handleNewRelation enqueues a connector-callback", async () => {
    const send = vi.fn(async () => {});
    const env = fakeEnv("doid:tok", send);
    await handleNewRelation(
      env,
      {
        type: "relation.new",
        account_id: "acc_1",
        payload: { member_id: "prof_1" },
      } as any,
      logger
    );

    expect(invokeWebhookCallback).not.toHaveBeenCalled();
    expect(send).toHaveBeenCalledWith({
      type: "connector-callback",
      token: "doid:tok",
      args: [{ kind: "relation.new", profileId: "prof_1" }],
    });
  });

  it("drops (no enqueue) when the connector callback token is not yet stored", async () => {
    const send = vi.fn(async () => {});
    const env = fakeEnv(null, send);
    await handleNewMessage(
      env,
      {
        type: "message.new",
        account_id: "acc_1",
        payload: { chat_id: "chat_1", message_id: "msg_1" },
      } as any,
      logger
    );

    expect(send).not.toHaveBeenCalled();
    expect(invokeWebhookCallback).not.toHaveBeenCalled();
  });
});
