import {
  type Action,
  ActionType,
  type Link,
  type NewLinkWithNotes,
  type Note,
  type Thread,
  type ThreadMeta,
} from "@plotday/twister";
import type { NewContact } from "@plotday/twister/plot";
import { Tag } from "@plotday/twister/tag";
import { Connector } from "@plotday/twister/connector";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";

import {
  AirtableAPI,
  type AirtableBase,
  type AirtableComment,
  type AirtableRecord,
  type AirtableTable,
  type AirtableWebhookPayload,
  type AirtableWebhookTableChange,
} from "./airtable-api";

function base64ToArrayBuffer(base64: string): ArrayBuffer {
  const bin = atob(base64);
  const buffer = new ArrayBuffer(bin.length);
  const view = new Uint8Array(buffer);
  for (let i = 0; i < bin.length; i++) view[i] = bin.charCodeAt(i);
  return buffer;
}

const LOGO =
  "https://api.iconify.design/simple-icons/airtable.svg?color=%2318BFFF";
const LOGO_MONO = "https://api.iconify.design/simple-icons/airtable.svg";

const STATUS_TODO = "todo";
const STATUS_DONE = "done";

const DONE_OPTION_MATCHERS = /^(done|complete|completed|resolved|closed|shipped)$/i;
const TODO_OPTION_MATCHERS =
  /^(todo|to.?do|not.?started|open|new|backlog|in.?progress|doing|started|blocked)$/i;
const TASK_NAME_HINTS = /task|to.?do|issue|action|follow.?up|ticket/i;
const NOTES_FIELD_MATCHERS = /notes?|description|details?|summary/i;

// Upserting keeps the original thread title, so we want the richest name we can get.
const DEFAULT_DESCRIPTION_KEY = "description";

type DetectedTable = {
  tableId: string;
  tableName: string;
  primaryFieldId: string;
  primaryFieldName: string;
  assigneeFieldId: string;
  assigneeFieldName: string;
  assigneeFieldType: "singleCollaborator" | "multipleCollaborators";
  dueDateFieldId: string | null;
  dueDateFieldName: string | null;
  /** Either a singleSelect status field or a checkbox field. */
  statusFieldId: string | null;
  statusFieldName: string | null;
  statusFieldType: "singleSelect" | "checkbox" | null;
  /** For singleSelect status fields, the option name used for "done". */
  doneOptionName: string | null;
  /** For singleSelect status fields, the option name used for "todo". */
  todoOptionName: string | null;
  /** Optional long-text / rich-text field to use as description. */
  notesFieldId: string | null;
  notesFieldName: string | null;
};

type ViewerInfo = {
  id: string;
  email: string | null;
};

type SyncState = {
  tableIndex: number;
  offset: string | null;
  initialSync: boolean;
};

type TrackedRecord = {
  tableId: string;
  recordId: string;
};

const RECONCILE_INTERVAL_MS = 30 * 60 * 1000;

export class Airtable extends Connector<Airtable> {
  static readonly PROVIDER = AuthProvider.Airtable;
  static readonly SCOPES = [
    "user.email:read",
    "schema.bases:read",
    "data.records:read",
    "data.records:write",
    "data.recordComments:read",
    "data.recordComments:write",
    "webhook:manage",
  ];
  static readonly handleReplies = true;

  readonly provider = AuthProvider.Airtable;
  readonly scopes = Airtable.SCOPES;
  readonly linkTypes = [
    {
      type: "task",
      label: "Task",
      logo: LOGO,
      logoDark: LOGO,
      logoMono: LOGO_MONO,
      statuses: [
        {
          status: STATUS_TODO,
          label: "To Do",
          todo: true as const,
          createDefault: true as const,
        },
        {
          status: STATUS_DONE,
          label: "Done",
          tag: Tag.Done,
          done: true as const,
        },
      ],
      supportsAssignee: true,
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://api.airtable.com/*"] }),
      tasks: build(Tasks),
    };
  }

  // ---- Account identity ----

  override async getAccountName(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<string | null> {
    if (!token) return null;
    try {
      const me = await new AirtableAPI(token.token).whoami();
      return me.email ?? me.id;
    } catch {
      return null;
    }
  }

  // ---- Channels ----

  async getChannels(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    if (!token) return [];
    const api = new AirtableAPI(token.token);
    const bases = await api.listBases();
    return bases.map((b: AirtableBase) => ({ id: b.id, title: b.name }));
  }

  async onChannelEnabled(
    channel: Channel,
    _context?: SyncContext
  ): Promise<void> {
    const baseId = channel.id;
    await this.set(`sync_enabled_${baseId}`, true);

    const detectCb = await this.callback(this.detectAndSync, baseId, true);
    await this.runTask(detectCb);

    const webhookCb = await this.callback(this.setupWebhook, baseId);
    await this.runTask(webhookCb);

    const reconcileCb = await this.callback(this.reconcileComments, baseId);
    await this.runTask(reconcileCb, {
      runAt: new Date(Date.now() + RECONCILE_INTERVAL_MS),
    });
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
  }

  private async stopSync(baseId: string): Promise<void> {
    const webhookId = await this.get<string>(`webhook_id_${baseId}`);
    if (webhookId) {
      try {
        const api = await this.getAPI(baseId);
        if (api) await api.deleteWebhook(baseId, webhookId);
      } catch (error) {
        console.warn("Failed to delete Airtable webhook:", error);
      }
    }
    await this.clear(`webhook_id_${baseId}`);
    await this.clear(`webhook_secret_${baseId}`);
    await this.clear(`webhook_cursor_${baseId}`);
    await this.clear(`webhook_url_${baseId}`);
    await this.clear(`sync_state_${baseId}`);
    await this.clear(`task_tables_${baseId}`);
    await this.clear(`viewer_${baseId}`);
    await this.clear(`tracked_records_${baseId}`);
  }

  // ---- Detection + Backfill ----

  async detectAndSync(baseId: string, initialSync: boolean): Promise<void> {
    if (!(await this.get<boolean>(`sync_enabled_${baseId}`))) return;
    const api = await this.getAPI(baseId);
    if (!api) return;
    const me = await api.whoami();
    await this.set<ViewerInfo>(`viewer_${baseId}`, {
      id: me.id,
      email: me.email ?? null,
    });

    const tables = await api.listTables(baseId);
    const detected = tables
      .map((t) => this.scoreTable(t))
      .filter((d): d is DetectedTable => d !== null);

    await this.set(`task_tables_${baseId}`, detected);

    if (detected.length === 0) return;

    await this.set<SyncState>(`sync_state_${baseId}`, {
      tableIndex: 0,
      offset: null,
      initialSync,
    });

    const cb = await this.callback(this.syncBatch, baseId);
    await this.runTask(cb);
  }

  /**
   * Score a table by task-like field presence. Returns a DetectedTable when
   * the score meets the threshold, or null otherwise.
   *
   * - Assignee (collaborator field): +3
   * - Due date (date/dateTime field): +2
   * - Status (singleSelect with task-like options, or checkbox): +2
   * - Name hint (table/primary field name mentions task/todo/issue/etc): +1
   * Threshold: >= 5, AND an assignee field is required (otherwise no filter).
   */
  private scoreTable(table: AirtableTable): DetectedTable | null {
    const primary = table.fields.find((f) => f.id === table.primaryFieldId);
    if (!primary) return null;

    const assignee =
      table.fields.find((f) => f.type === "multipleCollaborators") ??
      table.fields.find((f) => f.type === "singleCollaborator");
    if (!assignee) return null;

    let score = 3;

    const dueDate = table.fields.find(
      (f) => f.type === "date" || f.type === "dateTime"
    );
    if (dueDate) score += 2;

    const statusSelect = table.fields.find((f) => {
      if (f.type !== "singleSelect") return false;
      const choices = f.options?.choices ?? [];
      return choices.some((c) => DONE_OPTION_MATCHERS.test(c.name));
    });
    const checkbox = table.fields.find((f) => f.type === "checkbox");
    const statusField = statusSelect ?? checkbox ?? null;
    if (statusField) score += 2;

    const hinted =
      TASK_NAME_HINTS.test(table.name) || TASK_NAME_HINTS.test(primary.name);
    if (hinted) score += 1;

    if (score < 5) return null;

    let doneOption: string | null = null;
    let todoOption: string | null = null;
    if (statusSelect) {
      const choices = statusSelect.options?.choices ?? [];
      doneOption = choices.find((c) => DONE_OPTION_MATCHERS.test(c.name))?.name ?? null;
      todoOption = choices.find((c) => TODO_OPTION_MATCHERS.test(c.name))?.name ?? null;
    }

    const notesField = table.fields.find(
      (f) =>
        (f.type === "multilineText" || f.type === "richText") &&
        NOTES_FIELD_MATCHERS.test(f.name)
    ) ?? table.fields.find((f) => f.type === "multilineText" || f.type === "richText");

    return {
      tableId: table.id,
      tableName: table.name,
      primaryFieldId: primary.id,
      primaryFieldName: primary.name,
      assigneeFieldId: assignee.id,
      assigneeFieldName: assignee.name,
      assigneeFieldType:
        assignee.type === "multipleCollaborators"
          ? "multipleCollaborators"
          : "singleCollaborator",
      dueDateFieldId: dueDate?.id ?? null,
      dueDateFieldName: dueDate?.name ?? null,
      statusFieldId: statusField?.id ?? null,
      statusFieldName: statusField?.name ?? null,
      statusFieldType: statusSelect
        ? "singleSelect"
        : checkbox
          ? "checkbox"
          : null,
      doneOptionName: doneOption,
      todoOptionName: todoOption,
      notesFieldId: notesField?.id ?? null,
      notesFieldName: notesField?.name ?? null,
    };
  }

  async syncBatch(baseId: string): Promise<void> {
    if (!(await this.get<boolean>(`sync_enabled_${baseId}`))) return;

    const state = await this.get<SyncState>(`sync_state_${baseId}`);
    if (!state) return;

    const detected = (await this.get<DetectedTable[]>(`task_tables_${baseId}`)) ?? [];
    if (state.tableIndex >= detected.length) {
      await this.clear(`sync_state_${baseId}`);
      return;
    }

    const viewer = await this.get<ViewerInfo>(`viewer_${baseId}`);
    if (!viewer) {
      console.warn("Airtable viewer info missing for base", baseId);
      return;
    }

    const table = detected[state.tableIndex];
    const api = await this.getAPI(baseId);
    if (!api) return;
    const page = await api.listRecords(baseId, table.tableId, {
      offset: state.offset,
      pageSize: 50,
    });

    const tracked = (await this.get<TrackedRecord[]>(`tracked_records_${baseId}`)) ?? [];
    for (const record of page.records) {
      if (!this.recordAssignedTo(record, table, viewer)) continue;

      const comments = await api.listComments(baseId, table.tableId, record.id);
      const link = this.recordToLink(record, table, baseId, comments, state.initialSync);
      await this.tools.integrations.saveLink(link);

      if (!tracked.some((t) => t.tableId === table.tableId && t.recordId === record.id)) {
        tracked.push({ tableId: table.tableId, recordId: record.id });
      }
    }
    await this.set(`tracked_records_${baseId}`, tracked);

    if (page.offset) {
      await this.set<SyncState>(`sync_state_${baseId}`, {
        ...state,
        offset: page.offset,
      });
    } else if (state.tableIndex + 1 < detected.length) {
      await this.set<SyncState>(`sync_state_${baseId}`, {
        tableIndex: state.tableIndex + 1,
        offset: null,
        initialSync: state.initialSync,
      });
    } else {
      await this.clear(`sync_state_${baseId}`);
      return;
    }

    const next = await this.callback(this.syncBatch, baseId);
    await this.runTask(next);
  }

  // ---- Record → Link ----

  private recordAssignedTo(
    record: AirtableRecord,
    table: DetectedTable,
    viewer: ViewerInfo
  ): boolean {
    const raw = record.fields[table.assigneeFieldName];
    if (!raw) return false;
    const collaborators = Array.isArray(raw) ? raw : [raw];
    return collaborators.some((c: unknown) => {
      if (!c || typeof c !== "object") return false;
      const obj = c as { id?: string; email?: string };
      if (obj.id && obj.id === viewer.id) return true;
      if (viewer.email && obj.email && obj.email.toLowerCase() === viewer.email.toLowerCase()) {
        return true;
      }
      return false;
    });
  }

  private recordToLink(
    record: AirtableRecord,
    table: DetectedTable,
    baseId: string,
    comments: AirtableComment[],
    initialSync: boolean
  ): NewLinkWithNotes {
    const title = this.stringValue(record.fields[table.primaryFieldName]) ?? "(untitled)";
    const status = this.deriveStatus(record, table);
    const assignee = this.deriveAssignee(record, table);
    const url = `https://airtable.com/${baseId}/${table.tableId}/${record.id}`;
    const actions: Action[] = [
      { type: ActionType.external, title: "Open in Airtable", url },
    ];

    const notes: Array<{
      key: string;
      content: string | null;
      created?: Date;
      author?: NewContact;
    }> = [];

    const description = table.notesFieldName
      ? this.stringValue(record.fields[table.notesFieldName])
      : null;
    notes.push({
      key: DEFAULT_DESCRIPTION_KEY,
      content: description && description.trim().length > 0 ? description : null,
      created: new Date(record.createdTime),
    });

    for (const comment of comments) {
      notes.push({
        key: `comment-${comment.id}`,
        content: this.translateMentionsInbound(comment),
        created: new Date(comment.createdTime),
        author: this.commentAuthor(comment),
      });
    }

    return {
      source: `airtable:${baseId}:record:${record.id}`,
      type: "task",
      title,
      created: new Date(record.createdTime),
      assignee: assignee ?? null,
      status,
      channelId: baseId,
      meta: {
        airtableBaseId: baseId,
        airtableTableId: table.tableId,
        airtableRecordId: record.id,
        airtableAssigneeFieldName: table.assigneeFieldName,
        airtableStatusFieldName: table.statusFieldName,
        airtableStatusFieldType: table.statusFieldType,
        airtableDoneOptionName: table.doneOptionName,
        airtableTodoOptionName: table.todoOptionName,
        syncProvider: "airtable",
        syncableId: baseId,
      },
      actions,
      sourceUrl: url,
      notes,
      preview:
        description && description.trim().length > 0 ? description : null,
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  private deriveStatus(record: AirtableRecord, table: DetectedTable): string {
    if (!table.statusFieldName || !table.statusFieldType) return STATUS_TODO;
    const raw = record.fields[table.statusFieldName];
    if (table.statusFieldType === "checkbox") {
      return raw === true ? STATUS_DONE : STATUS_TODO;
    }
    const value = this.stringValue(raw);
    if (!value) return STATUS_TODO;
    if (DONE_OPTION_MATCHERS.test(value)) return STATUS_DONE;
    return STATUS_TODO;
  }

  private deriveAssignee(
    record: AirtableRecord,
    table: DetectedTable
  ): NewContact | null {
    const raw = record.fields[table.assigneeFieldName];
    if (!raw) return null;
    const collaborators = Array.isArray(raw) ? raw : [raw];
    const first = collaborators[0] as
      | { id?: string; email?: string; name?: string }
      | undefined;
    if (!first) return null;
    return this.collaboratorContact(first);
  }

  private collaboratorContact(c: {
    id?: string;
    email?: string;
    name?: string;
  }): NewContact {
    return {
      ...(c.email ? { email: c.email } : {}),
      name: c.name ?? "",
      ...(c.id
        ? { source: { provider: AuthProvider.Airtable, accountId: c.id } }
        : {}),
    };
  }

  private commentAuthor(comment: AirtableComment): NewContact | undefined {
    if (!comment.author) return undefined;
    return {
      ...(comment.author.email ? { email: comment.author.email } : {}),
      name: comment.author.name ?? comment.author.email ?? "",
      ...(comment.author.id
        ? {
            source: {
              provider: AuthProvider.Airtable,
              accountId: comment.author.id,
            },
          }
        : {}),
    };
  }

  /** Replace `@[usrXXX]` tokens with `@Name` using the mentioned map. */
  private translateMentionsInbound(comment: AirtableComment): string {
    const mentioned = comment.mentioned;
    if (!mentioned) return comment.text;
    return comment.text.replace(/@\[([^\]]+)\]/g, (full, token) => {
      const entry =
        mentioned[token] ||
        Object.values(mentioned).find((m) => m.email === token);
      if (!entry) return full;
      const name = entry.displayName ?? entry.name ?? entry.email ?? token;
      return `@${name}`;
    });
  }

  private stringValue(v: unknown): string | null {
    if (v == null) return null;
    if (typeof v === "string") return v;
    if (typeof v === "number" || typeof v === "boolean") return String(v);
    if (Array.isArray(v)) {
      return v
        .map((x) => (typeof x === "string" ? x : this.stringValue(x)))
        .filter((x): x is string => x !== null)
        .join(", ");
    }
    if (typeof v === "object") {
      const o = v as { name?: string; text?: string; value?: unknown };
      if (typeof o.name === "string") return o.name;
      if (typeof o.text === "string") return o.text;
      if (o.value !== undefined) return this.stringValue(o.value);
    }
    return null;
  }

  // ---- Webhooks ----

  async setupWebhook(baseId: string): Promise<void> {
    if (!(await this.get<boolean>(`sync_enabled_${baseId}`))) return;
    try {
      const webhookUrl = await this.tools.network.createWebhook(
        {},
        this.onWebhook,
        baseId
      );
      await this.set(`webhook_url_${baseId}`, webhookUrl);

      if (
        webhookUrl.includes("localhost") ||
        webhookUrl.includes("127.0.0.1")
      ) {
        return;
      }

      const detected = (await this.get<DetectedTable[]>(`task_tables_${baseId}`)) ?? [];
      const tableIds = detected.map((d) => d.tableId);

      const api = await this.getAPI(baseId);
      if (!api) return;
      // Airtable allows one notification scope per webhook; register one
      // webhook per base covering all detected tables. The
      // recordChangeScope filter only accepts a single table, so when we
      // have multiple task tables we drop the scope (the webhook will fire
      // for the whole base) and filter to our tables inside onWebhook.
      const webhook = await api.createWebhook(baseId, webhookUrl, {
        options: {
          filters: {
            dataTypes: ["tableData"],
            ...(tableIds.length === 1 ? { recordChangeScope: tableIds[0] } : {}),
          },
          includes: {
            includeCellValuesInFieldIds: "all",
          },
        },
      });

      await this.set(`webhook_id_${baseId}`, webhook.id);
      await this.set(`webhook_secret_${baseId}`, webhook.macSecretBase64);
      await this.set<number>(`webhook_cursor_${baseId}`, 1);
    } catch (error) {
      console.error("Failed to set up Airtable webhook:", error);
    }
  }

  async onWebhook(request: WebhookRequest, baseId: string): Promise<void> {
    const secret = await this.get<string>(`webhook_secret_${baseId}`);
    const webhookId = await this.get<string>(`webhook_id_${baseId}`);
    if (!secret || !webhookId || !request.rawBody) return;

    const sigHeader =
      request.headers["x-airtable-content-mac"] ||
      request.headers["X-Airtable-Content-MAC"];
    if (!sigHeader) {
      console.warn("Airtable webhook missing content MAC header");
      return;
    }

    const verified = await this.verifyMAC(secret, request.rawBody, sigHeader);
    if (!verified) {
      console.warn("Airtable webhook signature verification failed");
      return;
    }

    await this.processWebhookPayloads(baseId);
  }

  private async verifyMAC(
    macSecretBase64: string,
    rawBody: string,
    header: string
  ): Promise<boolean> {
    const provided = header.startsWith("hmac-sha256=")
      ? header.slice("hmac-sha256=".length)
      : header;
    const key = await crypto.subtle.importKey(
      "raw",
      base64ToArrayBuffer(macSecretBase64),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"]
    );
    const bodyBuffer = new ArrayBuffer(rawBody.length);
    new Uint8Array(bodyBuffer).set(new TextEncoder().encode(rawBody));
    const sig = await crypto.subtle.sign("HMAC", key, bodyBuffer);
    const hex = Array.from(new Uint8Array(sig))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    return hex === provided;
  }

  private async processWebhookPayloads(baseId: string): Promise<void> {
    const webhookId = await this.get<string>(`webhook_id_${baseId}`);
    if (!webhookId) return;
    const detected = (await this.get<DetectedTable[]>(`task_tables_${baseId}`)) ?? [];
    const viewer = await this.get<ViewerInfo>(`viewer_${baseId}`);
    if (!viewer || detected.length === 0) return;

    const api = await this.getAPI(baseId);
    if (!api) return;
    let cursor = (await this.get<number>(`webhook_cursor_${baseId}`)) ?? 1;
    const tableMap = new Map(detected.map((d) => [d.tableId, d] as const));

    for (let guard = 0; guard < 10; guard++) {
      const payloads = await api.listWebhookPayloads(baseId, webhookId, cursor);

      for (const payload of payloads.payloads) {
        await this.applyPayload(payload, baseId, tableMap, viewer, api);
      }

      cursor = payloads.cursor;
      await this.set<number>(`webhook_cursor_${baseId}`, cursor);

      if (!payloads.mightHaveMore) break;
    }
  }

  private async applyPayload(
    payload: AirtableWebhookPayload,
    baseId: string,
    tableMap: Map<string, DetectedTable>,
    viewer: ViewerInfo,
    api: AirtableAPI
  ): Promise<void> {
    const changedTables = payload.changedTablesById ?? {};
    for (const [tableId, change] of Object.entries(changedTables)) {
      const table = tableMap.get(tableId);
      if (!table) continue;
      await this.applyTableChange(change, table, baseId, viewer, api);
    }
  }

  private async applyTableChange(
    change: AirtableWebhookTableChange,
    table: DetectedTable,
    baseId: string,
    viewer: ViewerInfo,
    api: AirtableAPI
  ): Promise<void> {
    const recordIds = new Set<string>();
    for (const id of Object.keys(change.createdRecordsById ?? {})) recordIds.add(id);
    for (const id of Object.keys(change.changedRecordsById ?? {})) recordIds.add(id);

    for (const recordId of recordIds) {
      try {
        const record = await api.getRecord(baseId, table.tableId, recordId);
        if (!this.recordAssignedTo(record, table, viewer)) continue;
        const comments = await api.listComments(baseId, table.tableId, recordId);
        const link = this.recordToLink(record, table, baseId, comments, false);
        await this.tools.integrations.saveLink(link);
        await this.trackRecord(baseId, { tableId: table.tableId, recordId });
      } catch (error) {
        console.warn("Failed to sync Airtable record from webhook:", error);
      }
    }
  }

  private async trackRecord(baseId: string, rec: TrackedRecord): Promise<void> {
    const tracked = (await this.get<TrackedRecord[]>(`tracked_records_${baseId}`)) ?? [];
    if (tracked.some((t) => t.tableId === rec.tableId && t.recordId === rec.recordId)) {
      return;
    }
    tracked.push(rec);
    await this.set(`tracked_records_${baseId}`, tracked);
  }

  // ---- Reconciliation (catches comment edits/deletes webhooks miss) ----

  async reconcileComments(baseId: string): Promise<void> {
    // Stop the self-scheduling loop once the channel is disabled.
    // Returning without rescheduling lets the recurring task die out,
    // rather than spamming retries after teardown.
    if (!(await this.get<boolean>(`sync_enabled_${baseId}`))) return;

    const api = await this.getAPI(baseId);
    if (api) {
      const tracked = (await this.get<TrackedRecord[]>(`tracked_records_${baseId}`)) ?? [];
      const detected = (await this.get<DetectedTable[]>(`task_tables_${baseId}`)) ?? [];
      const tableMap = new Map(detected.map((d) => [d.tableId, d] as const));

      for (const rec of tracked) {
        const table = tableMap.get(rec.tableId);
        if (!table) continue;
        try {
          const record = await api.getRecord(baseId, rec.tableId, rec.recordId);
          const comments = await api.listComments(baseId, rec.tableId, rec.recordId);
          const link = this.recordToLink(record, table, baseId, comments, false);
          await this.tools.integrations.saveLink(link);
        } catch (error) {
          console.warn("Reconcile failed for record", rec.recordId, error);
        }
      }
    }

    // Reschedule only while the channel is still enabled. Re-check after
    // the reconcile pass in case onChannelDisabled fired during the run.
    if (!(await this.get<boolean>(`sync_enabled_${baseId}`))) return;
    const cb = await this.callback(this.reconcileComments, baseId);
    await this.runTask(cb, {
      runAt: new Date(Date.now() + RECONCILE_INTERVAL_MS),
    });
  }

  // ---- Write-backs ----

  async onLinkUpdated(link: Link): Promise<void> {
    const meta = link.meta ?? {};
    const baseId = meta.airtableBaseId as string | undefined;
    const tableId = meta.airtableTableId as string | undefined;
    const recordId = meta.airtableRecordId as string | undefined;
    const statusFieldName = meta.airtableStatusFieldName as string | null | undefined;
    const statusFieldType = meta.airtableStatusFieldType as
      | "singleSelect"
      | "checkbox"
      | null
      | undefined;
    if (!baseId || !tableId || !recordId || !link.status) return;
    if (!statusFieldName || !statusFieldType) return;

    const done = link.status === STATUS_DONE;
    const update: Record<string, unknown> = {};
    if (statusFieldType === "checkbox") {
      update[statusFieldName] = done;
    } else {
      const doneName = (meta.airtableDoneOptionName as string | null) ?? null;
      const todoName = (meta.airtableTodoOptionName as string | null) ?? null;
      const next = done ? doneName : todoName;
      if (!next) return;
      update[statusFieldName] = next;
    }

    const api = await this.getAPI(baseId);
    if (!api) return;
    try {
      await api.patchRecord(baseId, tableId, recordId, update);
    } catch (error) {
      console.warn("Failed to write Airtable status back:", error);
    }
  }

  async onNoteCreated(note: Note, thread: Thread): Promise<string | void> {
    const meta = (thread.meta ?? {}) as ThreadMeta;
    const baseId = meta.airtableBaseId as string | undefined;
    const tableId = meta.airtableTableId as string | undefined;
    const recordId = meta.airtableRecordId as string | undefined;
    if (!baseId || !tableId || !recordId) return;

    const text = (note.content ?? "").trim();
    if (text.length === 0) return;

    const api = await this.getAPI(baseId);
    if (!api) return;
    try {
      const comment = await api.createComment(baseId, tableId, recordId, {
        text: this.translateMentionsOutbound(text),
      });
      if (comment?.id) return `comment-${comment.id}`;
    } catch (error) {
      console.warn("Failed to post Airtable comment:", error);
    }
  }

  /**
   * Convert `@email@example.com` or `@[email@example.com]` in Plot note
   * content to Airtable's mention syntax `@[email@example.com]`. Airtable
   * accepts user emails directly inside the brackets.
   */
  private translateMentionsOutbound(text: string): string {
    return text.replace(
      /(^|\s)@\[?([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})\]?/g,
      (_m, lead, email) => `${lead}@[${email}]`
    );
  }

  // ---- Helpers ----

  /**
   * Returns an authenticated Airtable API client, or null when the channel
   * has no usable token (disconnected, revoked, or not yet refreshed).
   * Callers must bail silently on null rather than throwing, so scheduled
   * tasks don't retry-spam after the user disables the channel.
   */
  private async getAPI(baseId: string): Promise<AirtableAPI | null> {
    const token = await this.tools.integrations.get(baseId);
    if (!token) return null;
    return new AirtableAPI(token.token);
  }
}

export default Airtable;
