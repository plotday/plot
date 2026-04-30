import {
  type Action,
  ActionType,
  type Link,
  type NewLinkWithNotes,
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
  type LinkTypeConfig,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";

import {
  AirtableAPI,
  isAirtableAuthError,
  isAirtableNotFoundError,
  type AirtableBase,
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
const NOTES_FIELD_MATCHERS = /notes?|description|details?|summary/i;

// Upserting keeps the original thread title, so we want the richest name we can get.
const DEFAULT_DESCRIPTION_KEY = "description";

type DetectedTable = {
  tableId: string;
  tableName: string;
  primaryFieldId: string;
  primaryFieldName: string;
  assigneeFieldId: string | null;
  assigneeFieldName: string | null;
  assigneeFieldType: "singleCollaborator" | "multipleCollaborators" | null;
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

type SyncState = {
  tableIndex: number;
  offset: string | null;
  initialSync: boolean;
};

type LinkStatus = NonNullable<LinkTypeConfig["statuses"]>[number];

const POLL_INTERVAL_MS = 6 * 60 * 60 * 1000;
const STALE_AFTER_MS = 14 * 24 * 60 * 60 * 1000;

export class Airtable extends Connector<Airtable> {
  static readonly PROVIDER = AuthProvider.Airtable;
  static readonly SCOPES = [
    "user.email:read",
    "schema.bases:read",
    "data.records:read",
    "data.records:write",
    "webhook:manage",
  ];

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
    return Promise.all(
      bases.map(async (b: AirtableBase): Promise<Channel> => {
        const statuses = await this.baseStatuses(api, b.id);
        return {
          id: b.id,
          title: b.name,
          ...(statuses.length > 0
            ? {
                linkTypes: [
                  {
                    type: "task",
                    label: "Task",
                    logo: LOGO,
                    logoDark: LOGO,
                    logoMono: LOGO_MONO,
                    statuses,
                    supportsAssignee: true,
                  },
                ],
              }
            : {}),
        };
      })
    );
  }

  /**
   * Build a per-channel status list by inspecting detected task tables in the
   * base. Each Airtable singleSelect option becomes its own Plot status so
   * two-way status sync preserves workflow-specific labels ("In Progress",
   * "Fixed", etc.) instead of collapsing everything to To Do / Done.
   * Checkboxes contribute the fallback STATUS_TODO / STATUS_DONE pair.
   */
  private async baseStatuses(
    api: AirtableAPI,
    baseId: string
  ): Promise<LinkStatus[]> {
    let tables: AirtableTable[];
    try {
      tables = await api.listTables(baseId);
    } catch {
      return [];
    }
    const detected = tables
      .map((t) => this.scoreTable(t))
      .filter((d): d is DetectedTable => d !== null);
    if (detected.length === 0) return [];

    const optionNames = new Set<string>();
    let hasCheckbox = false;
    for (const table of detected) {
      if (table.statusFieldType === "checkbox") hasCheckbox = true;
      if (table.statusFieldType === "singleSelect" && table.statusFieldId) {
        const raw = tables.find((x) => x.id === table.tableId);
        const field = raw?.fields.find((x) => x.id === table.statusFieldId);
        for (const choice of field?.options?.choices ?? []) {
          optionNames.add(choice.name);
        }
      }
    }

    const statuses: LinkStatus[] = [];
    let createDefaultAssigned = false;
    const pushStatus = (status: string, label: string) => {
      const isDone = DONE_OPTION_MATCHERS.test(status);
      if (isDone) {
        statuses.push({ status, label, done: true, tag: Tag.Done });
      } else if (!createDefaultAssigned) {
        statuses.push({ status, label, todo: true, createDefault: true });
        createDefaultAssigned = true;
      } else {
        statuses.push({ status, label, todo: true });
      }
    };

    if (hasCheckbox) {
      pushStatus(STATUS_TODO, "To Do");
      pushStatus(STATUS_DONE, "Done");
    }
    for (const name of optionNames) pushStatus(name, name);

    return statuses;
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

    // Schedule the safety-poll chain. Real-time updates flow through the
    // webhook delivery path; this 6-hour cadence catches deliveries that
    // were lost in transit AND keeps the webhook alive (calling /payloads
    // resets Airtable's 7-day inactivity timer, complementing renewWebhook).
    // Set the flag so the reconcileComments migration shim doesn't also
    // bootstrap a duplicate poll chain after upgrade.
    await this.set(`poll_initialized_${baseId}`, true);
    const pollCb = await this.callback(this.pollWebhookPayloads, baseId);
    await this.runTask(pollCb, {
      runAt: new Date(Date.now() + POLL_INTERVAL_MS),
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
    await this.clear(`webhook_expires_at_${baseId}`);
    await this.clear(`last_activity_at_${baseId}`);
    await this.clear(`poll_initialized_${baseId}`);
    await this.clear(`sync_state_${baseId}`);
    await this.clear(`task_tables_${baseId}`);
    await this.clear(`tracked_records_${baseId}`);
    // Legacy key from pre-"sync all records" versions; clear for cleanup.
    await this.clear(`viewer_${baseId}`);
  }

  // ---- Detection + Backfill ----

  async detectAndSync(baseId: string, initialSync: boolean): Promise<void> {
    if (!(await this.get<boolean>(`sync_enabled_${baseId}`))) return;
    const api = await this.getAPI(baseId);
    if (!api) return;

    const detected = await this.refreshTaskTables(baseId, api);

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
   * Re-detect task tables from the live Airtable schema and persist the
   * cached map. Called by detectAndSync at channel-enable time AND by
   * applyPayload when a tableFields webhook event signals that the
   * schema has changed underneath us (status field renamed, new option
   * added, etc.).
   */
  private async refreshTaskTables(
    baseId: string,
    api: AirtableAPI
  ): Promise<DetectedTable[]> {
    const tables = await api.listTables(baseId);
    const detected = tables
      .map((t) => this.scoreTable(t))
      .filter((d): d is DetectedTable => d !== null);
    await this.set(`task_tables_${baseId}`, detected);
    return detected;
  }

  /**
   * Decide whether a table looks like task tracking. Qualifies when either
   * a collaborator assignee or a status field (checkbox, or singleSelect
   * with a done-matching option) is present — both are strong signals of
   * task workflow.
   */
  private scoreTable(table: AirtableTable): DetectedTable | null {
    const primary = table.fields.find((f) => f.id === table.primaryFieldId);
    if (!primary) return null;

    const assignee =
      table.fields.find((f) => f.type === "multipleCollaborators") ??
      table.fields.find((f) => f.type === "singleCollaborator");

    const statusSelect = table.fields.find((f) => {
      if (f.type !== "singleSelect") return false;
      const choices = f.options?.choices ?? [];
      return choices.some((c) => DONE_OPTION_MATCHERS.test(c.name));
    });
    const checkbox = table.fields.find((f) => f.type === "checkbox");
    const statusField = statusSelect ?? checkbox ?? null;

    if (!assignee && !statusField) return null;

    const dueDate = table.fields.find(
      (f) => f.type === "date" || f.type === "dateTime"
    );

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
      assigneeFieldId: assignee?.id ?? null,
      assigneeFieldName: assignee?.name ?? null,
      assigneeFieldType: !assignee
        ? null
        : assignee.type === "multipleCollaborators"
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

    const table = detected[state.tableIndex];
    const api = await this.getAPI(baseId);
    if (!api) return;

    let page;
    try {
      page = await api.listRecords(baseId, table.tableId, {
        offset: state.offset,
        pageSize: 50,
      });
    } catch (error) {
      if (isAirtableAuthError(error)) {
        // Token is revoked/expired — stop the batch so we don't keep hammering
        // the API. The next reconcile will retry once the user reconnects.
        console.warn("Airtable syncBatch: auth failed, stopping", baseId, error);
        await this.clear(`sync_state_${baseId}`);
        return;
      }
      throw error;
    }

    // Per-record try/catch so one bad record doesn't abort the whole batch —
    // a malformed field or a transient saveLink failure is recoverable on
    // the next reconcile pass.
    for (const record of page.records) {
      try {
        const link = this.recordToLink(record, table, baseId, state.initialSync);
        await this.tools.integrations.saveLink(link);
      } catch (error) {
        if (isAirtableAuthError(error)) {
          console.warn("Airtable syncBatch: auth failed, stopping", baseId, error);
          await this.clear(`sync_state_${baseId}`);
          return;
        }
        console.warn("Airtable syncBatch: saveLink failed", record.id, error);
      }
    }

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

  private recordToLink(
    record: AirtableRecord,
    table: DetectedTable,
    baseId: string,
    initialSync: boolean
  ): NewLinkWithNotes {
    const title = this.deriveTitle(record, table);
    const description = this.buildDescription(record, table);
    const preview = this.buildPreview(record, table);
    const status = this.deriveStatus(record, table);
    const assignee = this.deriveAssignee(record, table);
    const url = `https://airtable.com/${baseId}/${table.tableId}/${record.id}`;
    const actions: Action[] = [
      { type: ActionType.external, title: "Open in Airtable", url },
    ];

    const notes = [
      {
        key: DEFAULT_DESCRIPTION_KEY,
        content: description,
        created: new Date(record.createdTime),
      },
    ];

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
      preview,
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  /**
   * Record's primary field if set; otherwise the first non-empty non-system
   * scalar field under 200 chars. Avoids the ugly "(untitled)" fallback
   * whenever a record has ANY usable text.
   */
  private deriveTitle(record: AirtableRecord, table: DetectedTable): string {
    const primary = this.stringValue(record.fields[table.primaryFieldName]);
    if (primary && primary.trim()) return primary.trim();
    for (const [name, value] of Object.entries(record.fields)) {
      if (this.isSystemField(name, table)) continue;
      const str = this.stringValue(value);
      if (str && str.trim() && str.trim().length < 200) return str.trim();
    }
    return "Untitled";
  }

  /**
   * Build a markdown description combining the notes field (if any) with a
   * details list of every other non-empty, non-system field. Gives the user
   * a real-looking note on every synced record, even ones without a
   * designated long-text field (the common case for Bug Tracker-style bases).
   */
  private buildDescription(
    record: AirtableRecord,
    table: DetectedTable
  ): string | null {
    const sections: string[] = [];

    const notes = table.notesFieldName
      ? this.stringValue(record.fields[table.notesFieldName])
      : null;
    if (notes && notes.trim()) sections.push(notes.trim());

    const details: string[] = [];
    for (const [name, value] of Object.entries(record.fields)) {
      if (this.isSystemField(name, table)) continue;
      if (name === table.notesFieldName) continue;
      const str = this.stringValue(value);
      if (!str || !str.trim()) continue;
      details.push(`- **${name}**: ${str.trim()}`);
    }
    if (details.length > 0) sections.push(details.join("\n"));

    return sections.length > 0 ? sections.join("\n\n") : null;
  }

  /** Short plain-text preview for list views — prefer the notes field. */
  private buildPreview(
    record: AirtableRecord,
    table: DetectedTable
  ): string | null {
    const notes = table.notesFieldName
      ? this.stringValue(record.fields[table.notesFieldName])
      : null;
    if (notes && notes.trim()) return notes.trim();
    for (const [name, value] of Object.entries(record.fields)) {
      if (this.isSystemField(name, table)) continue;
      if (name === table.primaryFieldName) continue;
      const str = this.stringValue(value);
      if (str && str.trim()) return str.trim();
    }
    return null;
  }

  private isSystemField(name: string, table: DetectedTable): boolean {
    return (
      name === table.assigneeFieldName ||
      name === table.statusFieldName ||
      name === table.dueDateFieldName
    );
  }

  /**
   * For singleSelect status fields, returns the raw option name so it matches
   * one of the dynamic statuses declared by getChannels. Falls back to the
   * detected todo option when the field is empty so empty-status records
   * still render with a valid status. Checkboxes collapse to STATUS_TODO /
   * STATUS_DONE.
   */
  private deriveStatus(record: AirtableRecord, table: DetectedTable): string {
    if (!table.statusFieldName || !table.statusFieldType) return STATUS_TODO;
    const raw = record.fields[table.statusFieldName];
    if (table.statusFieldType === "checkbox") {
      return raw === true ? STATUS_DONE : STATUS_TODO;
    }
    const value = this.stringValue(raw);
    if (value) return value;
    return table.todoOptionName ?? STATUS_TODO;
  }

  private deriveAssignee(
    record: AirtableRecord,
    table: DetectedTable
  ): NewContact | null {
    const fieldName = table.assigneeFieldName;
    if (!fieldName) return null;
    const raw = record.fields[fieldName];
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

      const api = await this.getAPI(baseId);
      if (!api) return;

      // Airtable limits each OAuth integration to 2 webhooks per base.
      // listWebhooks only returns webhooks our integration created, so any
      // entries here are either the one we're about to replace or orphans
      // from prior setup attempts that never got cleaned up. Delete them
      // all before creating a fresh webhook (we can't reuse an existing
      // one because macSecretBase64 is only returned on create).
      const existingId = await this.get<string>(`webhook_id_${baseId}`);
      try {
        const existing = await api.listWebhooks(baseId);
        for (const hook of existing) {
          try {
            await api.deleteWebhook(baseId, hook.id);
          } catch (error) {
            console.warn(
              `Failed to delete stale Airtable webhook ${hook.id}:`,
              error
            );
          }
        }
      } catch (error) {
        console.warn("Failed to list Airtable webhooks for cleanup:", error);
      }
      if (existingId) {
        await this.clear(`webhook_id_${baseId}`);
        await this.clear(`webhook_secret_${baseId}`);
        await this.clear(`webhook_cursor_${baseId}`);
      }

      // Subscribe to base-wide events (no recordChangeScope). We filter
      // payloads to detected task tables inside applyPayload; this keeps
      // the webhook valid when the set of task tables changes (e.g. a
      // user adds a status field to a previously plain table — the
      // tableFields event triggers re-detection and the now-tracked
      // table starts receiving record updates without webhook recreation).
      //
      // tableFields keeps the cached task_tables map fresh when a status
      // field gains new options, gets renamed, etc.
      const webhook = await api.createWebhook(baseId, webhookUrl, {
        options: {
          filters: {
            dataTypes: ["tableData", "tableFields"],
          },
          includes: {
            includeCellValuesInFieldIds: "all",
          },
        },
      });

      await this.set(`webhook_id_${baseId}`, webhook.id);
      await this.set(`webhook_secret_${baseId}`, webhook.macSecretBase64);
      await this.set<number>(`webhook_cursor_${baseId}`, 1);
      await this.set<string | null>(
        `webhook_expires_at_${baseId}`,
        webhook.expirationTime ?? null
      );
      // Establish the activity baseline. pollWebhookPayloads compares
      // against this to decide whether to trigger Phase 5 recovery; we
      // bump it on every successful webhook setup AND on every payload
      // ingestion in processWebhookPayloads.
      await this.set(`last_activity_at_${baseId}`, new Date().toISOString());
      await this.scheduleNextRenewal(baseId, webhook.expirationTime ?? null);
    } catch (error) {
      console.error("Failed to set up Airtable webhook:", error);
    }
  }

  /**
   * Airtable webhooks expire 7 days after creation/refresh and stop
   * delivering notifications without warning. We schedule a `renewWebhook`
   * task ~24h before each expiration so the hook stays alive indefinitely
   * for as long as the channel is enabled. Clamps to "1 minute from now"
   * minimum to avoid scheduling tasks in the past when the expiration is
   * already inside the renewal window (e.g. clock skew, slow refresh).
   */
  private async scheduleNextRenewal(
    baseId: string,
    expirationTime: string | null
  ): Promise<void> {
    const expiresMs = expirationTime
      ? new Date(expirationTime).getTime()
      : Date.now() + 7 * 24 * 60 * 60 * 1000;
    const renewalMs = expiresMs - 24 * 60 * 60 * 1000;
    const runAt = new Date(Math.max(renewalMs, Date.now() + 60_000));
    const cb = await this.callback(this.renewWebhook, baseId);
    await this.runTask(cb, { runAt });
  }

  /**
   * Periodic webhook keepalive. Calls Airtable's /refresh endpoint to push
   * the expiration out by another 7 days, then schedules the next renewal.
   *
   * Failure handling:
   * - Auth (401): user reconnect required; bail without rescheduling. The
   *   user re-enabling the channel will re-run setupWebhook from scratch.
   * - Not found (404): the webhook has been deleted out from under us
   *   (manually, or aged out before we got here). Recreate via setupWebhook.
   * - Other transient errors: retry in 1h. With the 24h buffer ahead of
   *   expiry, we have ~24 retries before the webhook actually dies — at
   *   which point the next attempt 404s and we recreate.
   */
  async renewWebhook(baseId: string): Promise<void> {
    if (!(await this.get<boolean>(`sync_enabled_${baseId}`))) return;

    const webhookId = await this.get<string>(`webhook_id_${baseId}`);
    if (!webhookId) {
      // Lost the webhook id (e.g. setupWebhook never persisted it). Re-run
      // setup; that will create a fresh hook and reschedule renewal.
      const cb = await this.callback(this.setupWebhook, baseId);
      await this.runTask(cb);
      return;
    }

    const api = await this.getAPI(baseId);
    if (!api) return;

    try {
      const result = await api.refreshWebhook(baseId, webhookId);
      await this.set<string | null>(
        `webhook_expires_at_${baseId}`,
        result.expirationTime
      );
      await this.scheduleNextRenewal(baseId, result.expirationTime);
    } catch (error) {
      if (isAirtableAuthError(error)) {
        console.warn("Airtable renewWebhook: auth failed, stopping", baseId);
        return;
      }
      if (isAirtableNotFoundError(error)) {
        console.warn(
          "Airtable renewWebhook: webhook gone, recreating",
          baseId
        );
        await this.clear(`webhook_id_${baseId}`);
        await this.clear(`webhook_secret_${baseId}`);
        await this.clear(`webhook_cursor_${baseId}`);
        await this.clear(`webhook_expires_at_${baseId}`);
        const cb = await this.callback(this.setupWebhook, baseId);
        await this.runTask(cb);
        return;
      }
      console.warn(
        "Airtable renewWebhook: refresh failed, retrying in 1h",
        baseId,
        error
      );
      const cb = await this.callback(this.renewWebhook, baseId);
      await this.runTask(cb, {
        runAt: new Date(Date.now() + 60 * 60 * 1000),
      });
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

  /**
   * Drains pending webhook payloads from the saved cursor, applying record
   * changes and reacting to schema (tableFields) events. Self-reschedules
   * when payloads might still be available beyond this execution's
   * 10-batch guard, so a busy base eventually catches up across multiple
   * fresh executions instead of stalling at the cursor.
   *
   * Public so it can serve as a runTask callback target — invoked from
   * onWebhook (real-time delivery), pollWebhookPayloads (6h safety net),
   * and itself (continuation).
   */
  async processWebhookPayloads(baseId: string): Promise<void> {
    const webhookId = await this.get<string>(`webhook_id_${baseId}`);
    if (!webhookId) return;
    const detected =
      (await this.get<DetectedTable[]>(`task_tables_${baseId}`)) ?? [];

    const api = await this.getAPI(baseId);
    if (!api) return;
    let cursor = (await this.get<number>(`webhook_cursor_${baseId}`)) ?? 1;
    let tableMap = new Map(detected.map((d) => [d.tableId, d] as const));

    let ingested = false;
    let drained = false;
    for (let guard = 0; guard < 10; guard++) {
      const payloads = await api.listWebhookPayloads(baseId, webhookId, cursor);

      for (const payload of payloads.payloads) {
        ingested = true;
        tableMap = await this.applyPayload(payload, baseId, tableMap, api);
      }

      cursor = payloads.cursor;
      await this.set<number>(`webhook_cursor_${baseId}`, cursor);

      if (!payloads.mightHaveMore) {
        drained = true;
        break;
      }
    }

    if (ingested) {
      await this.set(`last_activity_at_${baseId}`, new Date().toISOString());
    }
    if (!drained) {
      // Hit the guard with payloads still pending. Queue a continuation
      // task so the next fresh execution gets its own request budget.
      const cb = await this.callback(this.processWebhookPayloads, baseId);
      await this.runTask(cb);
    }
  }

  /**
   * Process one webhook payload. Returns a (possibly refreshed) tableMap
   * — when the payload contains schema-change events, the cached
   * task_tables map is rebuilt from the live Airtable schema before
   * applying the record-change part of this same payload, so any newly
   * tracked tables get their record events applied with up-to-date metadata.
   */
  private async applyPayload(
    payload: AirtableWebhookPayload,
    baseId: string,
    tableMap: Map<string, DetectedTable>,
    api: AirtableAPI
  ): Promise<Map<string, DetectedTable>> {
    const changedTables = payload.changedTablesById ?? {};

    const hasFieldChange = Object.values(changedTables).some(
      (c) =>
        c.changedFieldsById ||
        c.createdFieldsById ||
        (c.destroyedFieldIds && c.destroyedFieldIds.length > 0)
    );
    let map = tableMap;
    if (hasFieldChange) {
      const refreshed = await this.refreshTaskTables(baseId, api);
      map = new Map(refreshed.map((d) => [d.tableId, d] as const));
    }

    for (const [tableId, change] of Object.entries(changedTables)) {
      const table = map.get(tableId);
      if (!table) continue;
      await this.applyTableChange(change, table, baseId, api);
    }
    return map;
  }

  private async applyTableChange(
    change: AirtableWebhookTableChange,
    table: DetectedTable,
    baseId: string,
    api: AirtableAPI
  ): Promise<void> {
    const recordIds = new Set<string>();
    for (const id of Object.keys(change.createdRecordsById ?? {})) recordIds.add(id);
    for (const id of Object.keys(change.changedRecordsById ?? {})) recordIds.add(id);

    for (const recordId of recordIds) {
      try {
        const record = await api.getRecord(baseId, table.tableId, recordId);
        const link = this.recordToLink(record, table, baseId, false);
        await this.tools.integrations.saveLink(link);
      } catch (error) {
        console.warn("Failed to sync Airtable record from webhook:", error);
      }
    }
  }

  // ---- Periodic safety poll ----

  /**
   * Periodic webhook-payload safety poll. Runs every 6 hours per enabled
   * channel and serves four purposes:
   *
   *  1. Recovers from missed webhook deliveries (network blip, transient
   *     5xx on our edge) by draining payloads from the saved cursor — the
   *     payloads sit in Airtable's 7-day buffer regardless of whether
   *     delivery fired.
   *  2. Keeps the webhook alive: hitting /payloads resets Airtable's
   *     7-day inactivity timer, complementing renewWebhook's 24h-before-
   *     expiry refresh.
   *  3. Hard recovery on a 404 from /payloads: the webhook has been
   *     deleted or aged out; recreate it and re-emit current record state.
   *  4. Soft recovery after 14 days of total silence: catches the rare
   *     case where the webhook is still alive on Airtable's side but no
   *     longer delivering for reasons we can't introspect (subscription
   *     stuck, regional glitch, etc.). Wasted work for legitimately quiet
   *     bases — bounded to one recovery per 14 days per base.
   *
   * Always reschedules in 6h on exit, regardless of whether work was done
   * or errors occurred — the poll is the backstop for everything else and
   * we want it running for as long as the channel is enabled. The exit
   * condition is "sync_enabled is false," checked at the top.
   */
  async pollWebhookPayloads(baseId: string): Promise<void> {
    if (!(await this.get<boolean>(`sync_enabled_${baseId}`))) return;

    let recoverReason: string | null = null;

    const webhookId = await this.get<string>(`webhook_id_${baseId}`);
    if (!webhookId) {
      recoverReason = "webhook id missing from storage";
    } else {
      try {
        await this.processWebhookPayloads(baseId);
      } catch (error) {
        if (isAirtableNotFoundError(error)) {
          recoverReason = "webhook returned 404 (deleted or expired)";
        } else if (isAirtableAuthError(error)) {
          // Auth has been revoked; reconnection will rebuild state via
          // onChannelEnabled. Don't try to recover here.
          console.warn(
            "Airtable pollWebhookPayloads: auth failed, skipping",
            baseId
          );
        } else {
          console.warn("Airtable pollWebhookPayloads failed", baseId, error);
        }
      }

      if (!recoverReason) {
        // Soft signal: long silence with no payloads. Migration backfill
        // for pre-Phase 5 channels with no last_activity_at — assume the
        // webhook is healthy (we just polled it) and start the clock now.
        let lastActivityISO = await this.get<string>(
          `last_activity_at_${baseId}`
        );
        if (!lastActivityISO) {
          lastActivityISO = new Date().toISOString();
          await this.set(`last_activity_at_${baseId}`, lastActivityISO);
        }
        const ageMs = Date.now() - new Date(lastActivityISO).getTime();
        if (ageMs > STALE_AFTER_MS) {
          const ageDays = Math.floor(ageMs / (24 * 60 * 60 * 1000));
          recoverReason = `no activity in ${ageDays} days`;
        }
      }
    }

    if (recoverReason) {
      await this.recoverWebhook(baseId, recoverReason);
    }

    const cb = await this.callback(this.pollWebhookPayloads, baseId);
    await this.runTask(cb, {
      runAt: new Date(Date.now() + POLL_INTERVAL_MS),
    });
  }

  /**
   * Reset webhook state and queue a fresh setup + record re-detect. Called
   * from pollWebhookPayloads when the webhook is confirmed dead (404), the
   * id has gone missing from storage, or activity has been silent for
   * long enough to suspect a stuck subscription.
   *
   * Bumps last_activity_at to "now" up front so a recovery that fails
   * quietly (e.g. setupWebhook errors out) doesn't re-fire on the very
   * next poll — we wait at least one full STALE_AFTER_MS window before
   * trying again.
   */
  private async recoverWebhook(
    baseId: string,
    reason: string
  ): Promise<void> {
    console.warn(
      `Airtable: recovering webhook for base ${baseId} (${reason})`
    );
    await this.clear(`webhook_id_${baseId}`);
    await this.clear(`webhook_secret_${baseId}`);
    await this.clear(`webhook_cursor_${baseId}`);
    await this.clear(`webhook_expires_at_${baseId}`);
    await this.set(`last_activity_at_${baseId}`, new Date().toISOString());

    const setupCb = await this.callback(this.setupWebhook, baseId);
    await this.runTask(setupCb);
    // Re-emit current record state so anything that changed during the
    // gap gets a fresh saveLink. initialSync=false so we don't reset
    // unread/archived flags users may have set in Plot.
    const detectCb = await this.callback(this.detectAndSync, baseId, false);
    await this.runTask(detectCb);
  }

  /**
   * Migration shim for in-flight tasks queued by pre-Phase-4 deploys. The
   * runtime resolves callbacks by method name at dispatch time, so
   * removing this method outright would break any reconcileComments task
   * already on the queue. Instead we keep the name but neuter the body:
   * run any pending one-shot migrations (renewWebhook backfill from
   * Phase 2, pollWebhookPayloads bootstrap from Phase 4) and return
   * without rescheduling. Each pre-existing in-flight task fires exactly
   * once after upgrade and then disappears.
   *
   * Safe to delete in a future cleanup once we're confident no
   * reconcileComments tasks remain queued (give it ~1 hour after deploy).
   */
  async reconcileComments(baseId: string): Promise<void> {
    if (!(await this.get<boolean>(`sync_enabled_${baseId}`))) return;

    // Phase 2 backfill: channels created before expiration tracking was
    // added need renewWebhook scheduled to avoid silent 7-day expiry.
    const expiresAt = await this.get<string>(`webhook_expires_at_${baseId}`);
    const webhookId = await this.get<string>(`webhook_id_${baseId}`);
    if (!expiresAt && webhookId) {
      const renewCb = await this.callback(this.renewWebhook, baseId);
      await this.runTask(renewCb);
    }

    // Phase 4 backfill: bootstrap the safety-poll chain. The flag is
    // also set in onChannelEnabled, so newly enabled channels skip this
    // and we never end up with two parallel poll chains for one base.
    const polled = await this.get<boolean>(`poll_initialized_${baseId}`);
    if (!polled) {
      await this.set(`poll_initialized_${baseId}`, true);
      const pollCb = await this.callback(this.pollWebhookPayloads, baseId);
      await this.runTask(pollCb);
    }
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

    const update: Record<string, unknown> = {};
    if (statusFieldType === "checkbox") {
      update[statusFieldName] = link.status === STATUS_DONE;
    } else {
      // link.status is the Airtable option name directly (from dynamic
      // per-channel statuses). Translate the legacy STATUS_TODO/STATUS_DONE
      // sentinels back through the stored option names for links created
      // before the dynamic-statuses change.
      let next: string | null = link.status;
      if (link.status === STATUS_TODO) {
        next = (meta.airtableTodoOptionName as string | null) ?? null;
      } else if (link.status === STATUS_DONE) {
        next = (meta.airtableDoneOptionName as string | null) ?? null;
      }
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
