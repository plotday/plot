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

type TableMapping = {
  baseId: string;
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

type SyncUnit = { tableId: string; viewId?: string };

type SyncState = {
  units: SyncUnit[];
  unitIndex: number;
  offset: string | null;
  initialSync: boolean;
};

// Pre-tree-refactor sync state. Migrated on read in `syncBatch`.
type LegacySyncState = {
  tableIndex: number;
  offset: string | null;
  initialSync: boolean;
};

type ParsedChannelId =
  | { kind: "base"; baseId: string }
  | { kind: "table"; baseId: string; tableId: string }
  | { kind: "view"; baseId: string; tableId: string; viewId: string };

type LinkStatus = NonNullable<LinkTypeConfig["statuses"]>[number];

const POLL_INTERVAL_MS = 6 * 60 * 60 * 1000;
const STALE_AFTER_MS = 14 * 24 * 60 * 60 * 1000;

/**
 * Channel ids encode the Base > Table > View hierarchy as slash-separated
 * Airtable ids: `appXXX`, `appXXX/tblYYY`, `appXXX/tblYYY/viwZZZ`. Slash is
 * safe because Airtable ids never contain one.
 */
function parseChannelId(id: string): ParsedChannelId {
  const parts = id.split("/");
  if (parts.length === 1) return { kind: "base", baseId: parts[0] };
  if (parts.length === 2)
    return { kind: "table", baseId: parts[0], tableId: parts[1] };
  if (parts.length === 3)
    return {
      kind: "view",
      baseId: parts[0],
      tableId: parts[1],
      viewId: parts[2],
    };
  throw new Error(`Invalid Airtable channel id: ${id}`);
}

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

  /**
   * Returns Bases as top-level channels, with Tables nested under each Base
   * and Views nested under each Table. Enabling at any level is supported:
   * a Base syncs all its tables, a Table syncs all its records (any view),
   * a View syncs only the records visible in that view.
   *
   * Per-channel `linkTypes` declare statuses derived from the inspected
   * table(s) so two-way status sync preserves workflow-specific labels
   * ("In Progress", "Fixed", etc.) instead of collapsing to To Do / Done.
   */
  async getChannels(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    if (!token) return [];
    const api = new AirtableAPI(token.token);
    const bases = await api.listBases();
    return Promise.all(
      bases.map(async (b: AirtableBase): Promise<Channel> => {
        let tables: AirtableTable[];
        try {
          tables = await api.listTables(b.id);
        } catch {
          return { id: b.id, title: b.name };
        }

        const baseStatuses = this.unionStatuses(tables);

        const tableChildren: Channel[] = tables.map((t) => {
          const mapping = this.detectTableMapping(b.id, t);
          const tableStatuses = this.statusesForTable(mapping, t);
          const linkTypes: LinkTypeConfig[] | undefined =
            tableStatuses.length > 0
              ? [
                  {
                    type: "task",
                    label: "Task",
                    logo: LOGO,
                    logoDark: LOGO,
                    logoMono: LOGO_MONO,
                    statuses: tableStatuses,
                    supportsAssignee: true,
                  },
                ]
              : undefined;

          const viewChildren: Channel[] = (t.views ?? []).map((v) => ({
            id: `${b.id}/${t.id}/${v.id}`,
            title: v.name,
            ...(linkTypes ? { linkTypes } : {}),
          }));

          return {
            id: `${b.id}/${t.id}`,
            title: t.name,
            ...(viewChildren.length > 0 ? { children: viewChildren } : {}),
            ...(linkTypes ? { linkTypes } : {}),
          };
        });

        return {
          id: b.id,
          title: b.name,
          ...(tableChildren.length > 0 ? { children: tableChildren } : {}),
          ...(baseStatuses.length > 0
            ? {
                linkTypes: [
                  {
                    type: "task",
                    label: "Task",
                    logo: LOGO,
                    logoDark: LOGO,
                    logoMono: LOGO_MONO,
                    statuses: baseStatuses,
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
   * Pure inspection: detect the field mapping for a single table. Replaces
   * the old "is this a task table?" heuristic — every table gets a mapping,
   * but the relevant fields may all be null for non-task-shaped tables
   * (those still sync as plain links with title only).
   */
  private detectTableMapping(
    baseId: string,
    table: AirtableTable
  ): TableMapping {
    const primary = table.fields.find((f) => f.id === table.primaryFieldId);

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

    const dueDate = table.fields.find(
      (f) => f.type === "date" || f.type === "dateTime"
    );

    let doneOption: string | null = null;
    let todoOption: string | null = null;
    if (statusSelect) {
      const choices = statusSelect.options?.choices ?? [];
      doneOption =
        choices.find((c) => DONE_OPTION_MATCHERS.test(c.name))?.name ?? null;
      todoOption =
        choices.find((c) => TODO_OPTION_MATCHERS.test(c.name))?.name ?? null;
    }

    const notesField =
      table.fields.find(
        (f) =>
          (f.type === "multilineText" || f.type === "richText") &&
          NOTES_FIELD_MATCHERS.test(f.name)
      ) ??
      table.fields.find(
        (f) => f.type === "multilineText" || f.type === "richText"
      );

    return {
      baseId,
      tableId: table.id,
      tableName: table.name,
      primaryFieldId: primary?.id ?? table.primaryFieldId,
      primaryFieldName: primary?.name ?? "Name",
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

  private statusesForTable(
    mapping: TableMapping,
    table: AirtableTable
  ): LinkStatus[] {
    if (mapping.statusFieldType === "checkbox") {
      const out: LinkStatus[] = [];
      this.appendStatus(out, STATUS_TODO, "To Do");
      this.appendStatus(out, STATUS_DONE, "Done");
      return out;
    }
    if (mapping.statusFieldType === "singleSelect" && mapping.statusFieldId) {
      const field = table.fields.find((f) => f.id === mapping.statusFieldId);
      const out: LinkStatus[] = [];
      for (const choice of field?.options?.choices ?? []) {
        this.appendStatus(out, choice.name, choice.name);
      }
      return out;
    }
    return [];
  }

  /**
   * Statuses for a Base channel = union of every table's status options.
   * Preserves workflow-specific labels across the whole base; falls back to
   * To Do / Done when any table uses a checkbox.
   */
  private unionStatuses(tables: AirtableTable[]): LinkStatus[] {
    const optionNames = new Set<string>();
    let hasCheckbox = false;
    for (const t of tables) {
      const mapping = this.detectTableMapping("", t);
      if (mapping.statusFieldType === "checkbox") hasCheckbox = true;
      if (mapping.statusFieldType === "singleSelect" && mapping.statusFieldId) {
        const field = t.fields.find((f) => f.id === mapping.statusFieldId);
        for (const choice of field?.options?.choices ?? []) {
          optionNames.add(choice.name);
        }
      }
    }
    const out: LinkStatus[] = [];
    if (hasCheckbox) {
      this.appendStatus(out, STATUS_TODO, "To Do");
      this.appendStatus(out, STATUS_DONE, "Done");
    }
    for (const name of optionNames) this.appendStatus(out, name, name);
    return out;
  }

  private appendStatus(
    out: LinkStatus[],
    status: string,
    label: string
  ): void {
    const isDone = DONE_OPTION_MATCHERS.test(status);
    const hasCreateDefault = out.some((s) => s.createDefault === true);
    if (isDone) {
      out.push({ status, label, done: true, tag: Tag.Done });
    } else if (!hasCreateDefault) {
      out.push({ status, label, todo: true, createDefault: true });
    } else {
      out.push({ status, label, todo: true });
    }
  }

  // ---- Lifecycle ----

  async onChannelEnabled(
    channel: Channel,
    _context?: SyncContext
  ): Promise<void> {
    const parsed = parseChannelId(channel.id);
    const baseId = parsed.baseId;

    // Order matters: addEnabledChannel reads `enabled_channels_${baseId}`
    // and falls back to seeding `[baseId]` when `sync_enabled_${baseId}`
    // is true (the legacy upgrade path). Writing `sync_enabled` first
    // would mis-seed the list with a Base channel that wasn't actually
    // enabled when the user picks a Table or View on a fresh connection.
    await this.addEnabledChannel(baseId, channel.id);
    await this.set(`sync_enabled_${baseId}`, true);

    const api = await this.getAPI(baseId);
    if (!api) return;

    let tables: AirtableTable[];
    try {
      tables = await api.listTables(baseId);
    } catch (error) {
      console.warn(
        "Airtable onChannelEnabled: listTables failed",
        baseId,
        error
      );
      return;
    }

    let units: SyncUnit[];
    if (parsed.kind === "base") {
      for (const t of tables) {
        await this.set<TableMapping>(
          `table_mapping_${baseId}_${t.id}`,
          this.detectTableMapping(baseId, t)
        );
      }
      units = tables.map((t) => ({ tableId: t.id }));
    } else {
      const t = tables.find((x) => x.id === parsed.tableId);
      if (!t) return;
      await this.set<TableMapping>(
        `table_mapping_${baseId}_${t.id}`,
        this.detectTableMapping(baseId, t)
      );
      units =
        parsed.kind === "view"
          ? [{ tableId: parsed.tableId, viewId: parsed.viewId }]
          : [{ tableId: parsed.tableId }];
    }

    if (units.length > 0) {
      await this.set<SyncState>(`sync_state_${channel.id}`, {
        units,
        unitIndex: 0,
        offset: null,
        initialSync: true,
      });
      const cb = await this.callback(this.syncBatch, channel.id);
      await this.runTask(cb);
    }

    // Webhook + safety poll are per-base; bring them up only when this is
    // the first channel under the base.
    const existingWebhook = await this.get<string>(`webhook_id_${baseId}`);
    if (!existingWebhook) {
      const webhookCb = await this.callback(this.setupWebhook, baseId);
      await this.runTask(webhookCb);
    }
    const polled = await this.get<boolean>(`poll_initialized_${baseId}`);
    if (!polled) {
      await this.set(`poll_initialized_${baseId}`, true);
      const pollCb = await this.callback(this.pollWebhookPayloads, baseId);
      await this.runTask(pollCb, {
        runAt: new Date(Date.now() + POLL_INTERVAL_MS),
      });
    }
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    const parsed = parseChannelId(channel.id);
    const baseId = parsed.baseId;

    await this.removeEnabledChannel(baseId, channel.id);
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`tracked_view_records_${channel.id}`);

    const remaining = await this.listEnabledChannels(baseId);
    if (remaining.length === 0) {
      await this.stopBaseSync(baseId);
    }
  }

  /**
   * Tear down all per-base webhook + poll state when the last channel under
   * a base is disabled. Also clears legacy keys from before the tree
   * refactor so re-enabling later starts clean.
   */
  private async stopBaseSync(baseId: string): Promise<void> {
    const webhookId = await this.get<string>(`webhook_id_${baseId}`);
    if (webhookId) {
      try {
        const api = await this.getAPI(baseId);
        if (api) await api.deleteWebhook(baseId, webhookId);
      } catch (error) {
        console.warn("Failed to delete Airtable webhook:", error);
      }
    }
    await this.clear(`sync_enabled_${baseId}`);
    await this.clear(`webhook_id_${baseId}`);
    await this.clear(`webhook_secret_${baseId}`);
    await this.clear(`webhook_cursor_${baseId}`);
    await this.clear(`webhook_url_${baseId}`);
    await this.clear(`webhook_expires_at_${baseId}`);
    await this.clear(`last_activity_at_${baseId}`);
    await this.clear(`poll_initialized_${baseId}`);
    await this.clear(`enabled_channels_${baseId}`);
    // Legacy keys from pre-tree-refactor versions.
    await this.clear(`sync_state_${baseId}`);
    await this.clear(`task_tables_${baseId}`);
    await this.clear(`tracked_records_${baseId}`);
    await this.clear(`viewer_${baseId}`);
  }

  private async addEnabledChannel(
    baseId: string,
    channelId: string
  ): Promise<void> {
    const list = await this.listEnabledChannels(baseId);
    if (!list.includes(channelId)) {
      list.push(channelId);
      await this.set(`enabled_channels_${baseId}`, list);
    }
  }

  private async removeEnabledChannel(
    baseId: string,
    channelId: string
  ): Promise<void> {
    const list = await this.listEnabledChannels(baseId);
    const next = list.filter((c) => c !== channelId);
    await this.set(`enabled_channels_${baseId}`, next);
  }

  /**
   * Reads the per-base set of enabled channel ids. Pre-tree-refactor
   * connections never wrote this list, so on first read after upgrade we
   * seed it from the legacy `sync_enabled_${baseId}` flag (the base id was
   * the only channel id back then).
   */
  private async listEnabledChannels(baseId: string): Promise<string[]> {
    const explicit = await this.get<string[]>(`enabled_channels_${baseId}`);
    if (explicit !== null) return explicit;
    if (await this.get<boolean>(`sync_enabled_${baseId}`)) {
      const seeded = [baseId];
      await this.set(`enabled_channels_${baseId}`, seeded);
      return seeded;
    }
    return [];
  }

  // ---- Detection + Backfill (legacy entry points kept for in-flight tasks) ----

  /**
   * Pre-tree-refactor entry point. Old `onChannelEnabled` callbacks queued
   * `detectAndSync(baseId, initialSync)`; we keep the method so in-flight
   * tasks resolve. After upgrade it runs the equivalent of a fresh
   * Base-level enable: refresh per-table mappings and queue a Base-level
   * sync if the base channel is enabled.
   */
  async detectAndSync(baseId: string, initialSync: boolean): Promise<void> {
    if (!(await this.get<boolean>(`sync_enabled_${baseId}`))) return;
    const api = await this.getAPI(baseId);
    if (!api) return;
    let tables: AirtableTable[];
    try {
      tables = await api.listTables(baseId);
    } catch {
      return;
    }
    for (const t of tables) {
      await this.set<TableMapping>(
        `table_mapping_${baseId}_${t.id}`,
        this.detectTableMapping(baseId, t)
      );
    }
    const enabled = await this.listEnabledChannels(baseId);
    const baseChannel = enabled.find(
      (c) => parseChannelId(c).kind === "base"
    );
    if (!baseChannel) return;
    if (tables.length === 0) return;
    await this.set<SyncState>(`sync_state_${baseChannel}`, {
      units: tables.map((t) => ({ tableId: t.id })),
      unitIndex: 0,
      offset: null,
      initialSync,
    });
    const cb = await this.callback(this.syncBatch, baseChannel);
    await this.runTask(cb);
  }

  // ---- Sync ----

  /**
   * Drains one page of records for the current sync unit (table[/view]),
   * upserting each record as a Plot link. Self-reschedules until the unit
   * pagination drains, then advances to the next unit.
   *
   * Backwards compatible with in-flight callbacks queued by the pre-tree
   * refactor (signature was `syncBatch(baseId)`; baseId is a valid Base
   * channel id under the new scheme).
   */
  async syncBatch(channelId: string): Promise<void> {
    const parsed = parseChannelId(channelId);
    const baseId = parsed.baseId;

    if (!(await this.get<boolean>(`sync_enabled_${baseId}`))) return;

    let state = await this.get<SyncState | LegacySyncState>(
      `sync_state_${channelId}`
    );
    if (!state) return;

    if (!("units" in state)) {
      const legacy = state as LegacySyncState;
      const legacyTables =
        (await this.get<Array<TableMapping & { tableId: string }>>(
          `task_tables_${baseId}`
        )) ?? [];
      for (const t of legacyTables) {
        const existing = await this.get<TableMapping>(
          `table_mapping_${baseId}_${t.tableId}`
        );
        if (!existing) {
          await this.set<TableMapping>(
            `table_mapping_${baseId}_${t.tableId}`,
            { ...t, baseId }
          );
        }
      }
      const migrated: SyncState = {
        units: legacyTables.map((t) => ({ tableId: t.tableId })),
        unitIndex: legacy.tableIndex,
        offset: legacy.offset,
        initialSync: legacy.initialSync,
      };
      await this.set<SyncState>(`sync_state_${channelId}`, migrated);
      state = migrated;
    }
    const ss = state as SyncState;

    if (ss.unitIndex >= ss.units.length) {
      await this.clear(`sync_state_${channelId}`);
      return;
    }

    const unit = ss.units[ss.unitIndex];
    const mapping = await this.getTableMapping(baseId, unit.tableId);
    if (!mapping) {
      // Table vanished from the schema — skip the unit and continue.
      await this.advanceSync(channelId, ss);
      const next = await this.callback(this.syncBatch, channelId);
      await this.runTask(next);
      return;
    }

    const api = await this.getAPI(baseId);
    if (!api) return;

    let page;
    try {
      page = await api.listRecords(baseId, unit.tableId, {
        offset: ss.offset,
        pageSize: 50,
        ...(unit.viewId ? { view: unit.viewId } : {}),
      });
    } catch (error) {
      if (isAirtableAuthError(error)) {
        console.warn(
          "Airtable syncBatch: auth failed, stopping",
          channelId,
          error
        );
        await this.clear(`sync_state_${channelId}`);
        return;
      }
      throw error;
    }

    const trackedIds: string[] = [];
    for (const record of page.records) {
      try {
        const link = this.recordToLink(
          record,
          mapping,
          channelId,
          ss.initialSync
        );
        await this.tools.integrations.saveLink(link);
        trackedIds.push(record.id);
      } catch (error) {
        if (isAirtableAuthError(error)) {
          console.warn(
            "Airtable syncBatch: auth failed, stopping",
            channelId,
            error
          );
          await this.clear(`sync_state_${channelId}`);
          return;
        }
        console.warn(
          "Airtable syncBatch: saveLink failed",
          record.id,
          error
        );
      }
    }

    // Track view membership so the safety poll can detect records that
    // later fall out of the view.
    if (parsed.kind === "view" && trackedIds.length > 0) {
      const previous =
        (await this.get<string[]>(`tracked_view_records_${channelId}`)) ?? [];
      const merged = Array.from(new Set([...previous, ...trackedIds]));
      await this.set(`tracked_view_records_${channelId}`, merged);
    }

    if (page.offset) {
      await this.set<SyncState>(`sync_state_${channelId}`, {
        ...ss,
        offset: page.offset,
      });
    } else {
      await this.advanceSync(channelId, ss);
    }

    if (await this.get<SyncState>(`sync_state_${channelId}`)) {
      const next = await this.callback(this.syncBatch, channelId);
      await this.runTask(next);
    }
  }

  private async advanceSync(
    channelId: string,
    ss: SyncState
  ): Promise<void> {
    if (ss.unitIndex + 1 < ss.units.length) {
      await this.set<SyncState>(`sync_state_${channelId}`, {
        ...ss,
        unitIndex: ss.unitIndex + 1,
        offset: null,
      });
    } else {
      await this.clear(`sync_state_${channelId}`);
    }
  }

  /**
   * Per-table field mapping, with three fallback layers:
   *  1. New per-table cache (`table_mapping_${baseId}_${tableId}`).
   *  2. Legacy per-base array (`task_tables_${baseId}`) for connections
   *     that haven't been re-enabled since the tree refactor.
   *  3. Live re-detection via `listTables` when neither cache hit.
   */
  private async getTableMapping(
    baseId: string,
    tableId: string
  ): Promise<TableMapping | null> {
    const direct = await this.get<TableMapping>(
      `table_mapping_${baseId}_${tableId}`
    );
    if (direct) return direct;
    const legacy = await this.get<Array<TableMapping & { tableId: string }>>(
      `task_tables_${baseId}`
    );
    const found = legacy?.find((t) => t.tableId === tableId);
    if (found) return { ...found, baseId };
    const api = await this.getAPI(baseId);
    if (!api) return null;
    try {
      const tables = await api.listTables(baseId);
      const t = tables.find((x) => x.id === tableId);
      if (!t) return null;
      const mapping = this.detectTableMapping(baseId, t);
      await this.set<TableMapping>(
        `table_mapping_${baseId}_${tableId}`,
        mapping
      );
      return mapping;
    } catch {
      return null;
    }
  }

  // ---- Channel attribution ----

  /**
   * Resolve the most-specific enabled channel id covering this record.
   * Order: enabled View containing this record > enabled Table > enabled
   * Base. Returns null when no enabled channel covers the record (e.g. the
   * webhook fired on a table whose channels are all disabled).
   */
  private async resolveChannelForRecord(
    api: AirtableAPI,
    baseId: string,
    tableId: string,
    recordId: string
  ): Promise<string | null> {
    const enabled = await this.listEnabledChannels(baseId);
    const viewChannels: string[] = [];
    let tableChannel: string | null = null;
    let baseChannel: string | null = null;
    for (const c of enabled) {
      const p = parseChannelId(c);
      if (p.kind === "base") baseChannel = c;
      else if (p.kind === "table" && p.tableId === tableId) tableChannel = c;
      else if (p.kind === "view" && p.tableId === tableId) viewChannels.push(c);
    }
    for (const view of viewChannels) {
      const parsed = parseChannelId(view) as Extract<
        ParsedChannelId,
        { kind: "view" }
      >;
      if (
        await this.recordInView(api, baseId, tableId, parsed.viewId, recordId)
      ) {
        return view;
      }
    }
    if (tableChannel) return tableChannel;
    if (baseChannel) return baseChannel;
    return null;
  }

  /**
   * Cheap view-membership check via `filterByFormula=RECORD_ID()='...'`
   * scoped to the view. Returns 0 or 1 record without listing the whole view.
   */
  private async recordInView(
    api: AirtableAPI,
    baseId: string,
    tableId: string,
    viewId: string,
    recordId: string
  ): Promise<boolean> {
    try {
      const page = await api.listRecords(baseId, tableId, {
        view: viewId,
        filterByFormula: `RECORD_ID()='${recordId}'`,
        pageSize: 1,
        fields: [],
      });
      return page.records.length > 0;
    } catch {
      return false;
    }
  }

  // ---- Record → Link ----

  private recordToLink(
    record: AirtableRecord,
    table: TableMapping,
    channelId: string,
    initialSync: boolean
  ): NewLinkWithNotes {
    const baseId = table.baseId;
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
      channelId,
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
        syncableId: channelId,
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
  private deriveTitle(record: AirtableRecord, table: TableMapping): string {
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
    table: TableMapping
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
    table: TableMapping
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

  private isSystemField(name: string, table: TableMapping): boolean {
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
  private deriveStatus(record: AirtableRecord, table: TableMapping): string {
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
    table: TableMapping
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
      // payloads to enabled channels inside applyTableChange; this keeps
      // the webhook valid when the set of enabled tables/views changes.
      //
      // tableFields keeps the cached table_mapping_* keys fresh when a
      // status field gains new options, gets renamed, etc.
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
   * for as long as any channel under the base is enabled. Clamps to
   * "1 minute from now" minimum to avoid scheduling tasks in the past
   * when the expiration is already inside the renewal window (e.g. clock
   * skew, slow refresh).
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

    const api = await this.getAPI(baseId);
    if (!api) return;
    let cursor = (await this.get<number>(`webhook_cursor_${baseId}`)) ?? 1;

    let ingested = false;
    let drained = false;
    for (let guard = 0; guard < 10; guard++) {
      const payloads = await api.listWebhookPayloads(
        baseId,
        webhookId,
        cursor
      );

      for (const payload of payloads.payloads) {
        ingested = true;
        await this.applyPayload(payload, baseId, api);
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
      const cb = await this.callback(this.processWebhookPayloads, baseId);
      await this.runTask(cb);
    }
  }

  /**
   * Process one webhook payload. Refreshes per-table mappings for any table
   * that carried schema-change events before applying the record changes
   * in the same payload, so newly-tracked fields/options are picked up
   * without webhook recreation.
   */
  private async applyPayload(
    payload: AirtableWebhookPayload,
    baseId: string,
    api: AirtableAPI
  ): Promise<void> {
    const changedTables = payload.changedTablesById ?? {};

    const hasFieldChange = Object.values(changedTables).some(
      (c) =>
        c.changedFieldsById ||
        c.createdFieldsById ||
        (c.destroyedFieldIds && c.destroyedFieldIds.length > 0)
    );
    if (hasFieldChange) {
      try {
        const tables = await api.listTables(baseId);
        for (const tableId of Object.keys(changedTables)) {
          const t = tables.find((x) => x.id === tableId);
          if (t) {
            await this.set<TableMapping>(
              `table_mapping_${baseId}_${tableId}`,
              this.detectTableMapping(baseId, t)
            );
          }
        }
      } catch (error) {
        console.warn("Airtable: failed to refresh schema", baseId, error);
      }
    }

    for (const [tableId, change] of Object.entries(changedTables)) {
      await this.applyTableChange(change, tableId, baseId, api);
    }
  }

  private async applyTableChange(
    change: AirtableWebhookTableChange,
    tableId: string,
    baseId: string,
    api: AirtableAPI
  ): Promise<void> {
    const recordIds = new Set<string>();
    for (const id of Object.keys(change.createdRecordsById ?? {}))
      recordIds.add(id);
    for (const id of Object.keys(change.changedRecordsById ?? {}))
      recordIds.add(id);

    for (const recordId of recordIds) {
      try {
        const channelId = await this.resolveChannelForRecord(
          api,
          baseId,
          tableId,
          recordId
        );
        if (!channelId) continue;
        const mapping = await this.getTableMapping(baseId, tableId);
        if (!mapping) continue;
        const record = await api.getRecord(baseId, tableId, recordId);
        const link = this.recordToLink(record, mapping, channelId, false);
        await this.tools.integrations.saveLink(link);

        if (parseChannelId(channelId).kind === "view") {
          const previous =
            (await this.get<string[]>(
              `tracked_view_records_${channelId}`
            )) ?? [];
          if (!previous.includes(recordId)) {
            previous.push(recordId);
            await this.set(`tracked_view_records_${channelId}`, previous);
          }
        }
      } catch (error) {
        console.warn(
          "Failed to sync Airtable record from webhook:",
          error
        );
      }
    }
  }

  // ---- Periodic safety poll ----

  /**
   * Periodic webhook-payload safety poll. Runs every 6 hours per active
   * base and serves five purposes:
   *
   *  1. Recovers from missed webhook deliveries by draining payloads from
   *     the saved cursor.
   *  2. Keeps the webhook alive: hitting /payloads resets Airtable's
   *     7-day inactivity timer, complementing renewWebhook.
   *  3. Hard recovery on a 404 from /payloads.
   *  4. Soft recovery after 14 days of total silence.
   *  5. View reconciliation: archives records that have fallen out of any
   *     enabled view since the last poll, when no broader channel still
   *     covers them.
   *
   * Always reschedules in 6h on exit, regardless of whether work was done
   * or errors occurred — the poll is the backstop for everything else and
   * we want it running for as long as any channel under the base is
   * enabled. The exit condition is "sync_enabled is false," checked at
   * the top.
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
          console.warn(
            "Airtable pollWebhookPayloads: auth failed, skipping",
            baseId
          );
        } else {
          console.warn(
            "Airtable pollWebhookPayloads failed",
            baseId,
            error
          );
        }
      }

      if (!recoverReason) {
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
    } else {
      try {
        await this.reconcileViews(baseId);
      } catch (error) {
        console.warn(
          "Airtable view reconciliation failed",
          baseId,
          error
        );
      }
    }

    const cb = await this.callback(this.pollWebhookPayloads, baseId);
    await this.runTask(cb, {
      runAt: new Date(Date.now() + POLL_INTERVAL_MS),
    });
  }

  /**
   * For each enabled View under this base: list current records, diff
   * against `tracked_view_records_${channelId}`, archive ids that fell
   * out (only when no broader channel — Base, Table, or sibling View —
   * still covers the record). Persists the fresh id set as the new
   * baseline for the next poll.
   */
  private async reconcileViews(baseId: string): Promise<void> {
    const enabled = await this.listEnabledChannels(baseId);
    const viewChannels = enabled.filter(
      (c) => parseChannelId(c).kind === "view"
    );
    if (viewChannels.length === 0) return;

    const baseEnabled = enabled.includes(baseId);
    const tableEnabled = (tid: string) =>
      enabled.includes(`${baseId}/${tid}`);

    const api = await this.getAPI(baseId);
    if (!api) return;

    for (const viewChannel of viewChannels) {
      const parsed = parseChannelId(viewChannel) as Extract<
        ParsedChannelId,
        { kind: "view" }
      >;

      let liveIds: string[] = [];
      try {
        let offset: string | null = null;
        do {
          const page = await api.listRecords(baseId, parsed.tableId, {
            view: parsed.viewId,
            pageSize: 100,
            fields: [],
            offset,
          });
          for (const r of page.records) liveIds.push(r.id);
          offset = page.offset ?? null;
        } while (offset);
      } catch (error) {
        console.warn(
          "Airtable reconcileViews: list failed",
          viewChannel,
          error
        );
        continue;
      }

      const previous =
        (await this.get<string[]>(`tracked_view_records_${viewChannel}`)) ??
        [];
      const liveSet = new Set(liveIds);
      const dropped = previous.filter((id) => !liveSet.has(id));

      // Skip the per-record sibling-view check entirely when a broader
      // channel covers the table — the records remain valid under that
      // channel and shouldn't be archived.
      if (
        dropped.length > 0 &&
        previous.length > 0 &&
        !baseEnabled &&
        !tableEnabled(parsed.tableId)
      ) {
        const otherViewIds = viewChannels
          .filter((c) => c !== viewChannel)
          .map(
            (c) =>
              parseChannelId(c) as Extract<
                ParsedChannelId,
                { kind: "view" }
              >
          )
          .filter((p) => p.tableId === parsed.tableId)
          .map((p) => p.viewId);
        for (const recordId of dropped) {
          let stillCovered = false;
          for (const otherViewId of otherViewIds) {
            if (
              await this.recordInView(
                api,
                baseId,
                parsed.tableId,
                otherViewId,
                recordId
              )
            ) {
              stillCovered = true;
              break;
            }
          }
          if (stillCovered) continue;
          try {
            await this.tools.integrations.saveLink({
              source: `airtable:${baseId}:record:${recordId}`,
              type: "task",
              channelId: viewChannel,
              archived: true,
              meta: {
                airtableBaseId: baseId,
                airtableTableId: parsed.tableId,
                airtableRecordId: recordId,
                syncProvider: "airtable",
                syncableId: viewChannel,
              },
            });
          } catch (error) {
            console.warn(
              "Airtable reconcileViews: archive failed",
              recordId,
              error
            );
          }
        }
      }

      await this.set(`tracked_view_records_${viewChannel}`, liveIds);
    }
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
    // Re-emit current record state for every enabled channel under this
    // base so anything that changed during the gap gets a fresh saveLink.
    // initialSync=false so we don't reset unread/archived flags users may
    // have set in Plot.
    const enabled = await this.listEnabledChannels(baseId);
    for (const channelId of enabled) {
      const parsed = parseChannelId(channelId);
      const units: SyncUnit[] = [];
      if (parsed.kind === "base") {
        const api = await this.getAPI(baseId);
        if (!api) continue;
        try {
          const tables = await api.listTables(baseId);
          for (const t of tables) units.push({ tableId: t.id });
        } catch {
          continue;
        }
      } else if (parsed.kind === "table") {
        units.push({ tableId: parsed.tableId });
      } else {
        units.push({ tableId: parsed.tableId, viewId: parsed.viewId });
      }
      if (units.length === 0) continue;
      await this.set<SyncState>(`sync_state_${channelId}`, {
        units,
        unitIndex: 0,
        offset: null,
        initialSync: false,
      });
      const cb = await this.callback(this.syncBatch, channelId);
      await this.runTask(cb);
    }
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

    const expiresAt = await this.get<string>(`webhook_expires_at_${baseId}`);
    const webhookId = await this.get<string>(`webhook_id_${baseId}`);
    if (!expiresAt && webhookId) {
      const renewCb = await this.callback(this.renewWebhook, baseId);
      await this.runTask(renewCb);
    }

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
    const statusFieldName = meta.airtableStatusFieldName as
      | string
      | null
      | undefined;
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
