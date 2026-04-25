# @plotday/twister

## 0.49.0

### Added

- `Integrations.saveLinks(links)` batch API. Connectors that sync many items per page should prefer this over looping `saveLink` — each call crosses the runtime boundary and counts against the per-execution request budget. ([`a0eb4a5`](https://github.com/plotday/plot/commit/a0eb4a56d36b57eb11fb17448c779fd68b04a881))
- `@plotday/twister/utils/markdown` with `markdownToPlainText(markdown)` for connectors that write back to external systems storing content verbatim as plain text (Google Drive comments, Todoist comments, Airtable cells, Attio notes). Renumbers lists, keeps bullet markers and paragraph breaks, strips emphasis/code syntax, and renders mentions as `@Name`. Pure in-process function — no RPC cost on `onNoteCreated` / `onNoteUpdated`. ([`b72c582`](https://github.com/plotday/plot/commit/b72c58285f073fa17f4da98e9e279801e29aebc7))
- new count tags for note reactions — Thinking, Remember, Agreed, Relieved, Send, Noted, Laugh, Surprised, Confused, Dismayed ([`fc81aab`](https://github.com/plotday/plot/commit/fc81aabb999634852e00f6e7de5aae02fb909da6))
- `NoteWriteBackResult` type and widened `onNoteCreated`/`onNoteUpdated` return types to accept it. Connectors performing two-way note sync can now return `{ key?, externalContent? }` so the runtime tracks a sync baseline of what the external system stored, preventing the next sync-in from clobbering Plot's (potentially richer-markdown) version with the round-tripped plain text. Back-compat preserved: `onNoteCreated` still accepts a plain string return. ([`960c614`](https://github.com/plotday/plot/commit/960c614e4a6d3ed4586b8b1da64b10ac39cdc22f))

## 0.48.0

### Added

- `AuthProvider.Airtable` for Airtable OAuth integrations. ([`900b697`](https://github.com/plotday/plot/commit/900b6976fb197f45dd59fa772c6edee813ea4fd6))

### Fixed

- `plot deploy` now bundles CJS dependencies that call `require("<node-builtin>")` (e.g. the asana SDK's `require("querystring")`). Previously the esbuild-generated `__require` stub would throw "Dynamic require of X is not supported" at runtime. The bundler now injects a module-level `require` built from `createRequire(import.meta.url)`, which Cloudflare Workers resolves via nodejs_compat. ([`b7d31d3`](https://github.com/plotday/plot/commit/b7d31d3f6f8b663c6c0e820aac66c65a5e2bd7a4))
- twist bundle banner now passes a literal `file:` URL to `createRequire` instead of `import.meta.url`. Cloudflare's Worker Loader leaves `import.meta.url` undefined, which caused every bundled twist/connector to throw `TypeError: path must be a file URL object...` at module-eval time and fail to deploy. ([`1a1c5cc`](https://github.com/plotday/plot/commit/1a1c5ccf63dc54978090021bcc27cb929e8db43d))
- `plot generate` was trying to install `@plotday/twist` (wrong package name) instead of `@plotday/twister`, causing post-generation dependency install to fail. Also updated `docs/CLI_REFERENCE.md` so the documented flags match the actual CLI (`--dir` / `--spec`, not `--input` / `--output`). ([`b57bb31`](https://github.com/plotday/plot/commit/b57bb3192170223eaa8d537b2f9d55532ba5a347))
- `plot build` (and therefore `plot deploy` / spec-driven twist generation) failed with "Could not resolve @plotday/twister" when run against the published package. The CLI bundler passes `conditions: ["@plotday/connector"]` to esbuild, and the package `exports` field points that condition at `./src/*.ts` — but the published tarball shipped only `dist/`, so every subpath import failed to resolve. Added `src` to the `files` field so the source files that the `@plotday/connector` condition references actually exist in the installed package. ([`b57bb31`](https://github.com/plotday/plot/commit/b57bb3192170223eaa8d537b2f9d55532ba5a347))

## 0.47.0

### Added

- `Connector.onCreateLink(draft)` hook and `CreateLinkDraft` type so connectors can create new items in external systems from Plot threads. A link type opts in by marking one of its statuses with `createDefault: true` on `LinkTypeConfig.statuses[]`; the status is also used as the default for newly created items. `CreateLinkDraft.contacts` carries the thread's contacts (excluding the creating user) so message/DM-style connectors can use them as recipients. ([`33085d3`](https://github.com/plotday/plot/commit/33085d302ac065c36b08ff9cf0929d4448aa6d4f))

## 0.46.0

### Added

- `static multipleInstances` property on `Twist` — set to `true` to allow multiple instances per scope; default is single-instance ([`22e4b0e`](https://github.com/plotday/plot/commit/22e4b0e5f406566a0da62a0cdc99593c0c1234ef))

### Changed

- `source` is now cross-user-scoped — two instances of the same connector emitting the same `source` converge on a single shared thread across users. Documented the requirement that `source` must be globally unique for the logical external item, and called out connectors whose external ids are workspace/tenant-scoped (attio, posthog, outlook-calendar, fellow) and need qualifiers. ([#118](https://github.com/plotday/plot/pull/118) [`969663d`](https://github.com/plotday/plot/commit/969663d59c88489fb5379a9abc427ef8fb92fb7a))

### Fixed

- qualify `source` strings in workspace/tenant/mailbox-scoped connectors so they stay globally unique under cross-user thread dedup. attio now uses `attio:<workspaceId>:<type>:<recordId>`; posthog uses `posthog:<projectId>:person:<distinctId>`; outlook-calendar uses `outlook-calendar:<calendarId>:<eventId>`; fellow uses `fellow:<subdomain>:note:<id>`. google-calendar now uses the event's `iCalUID` (shared across attendees' copies) in place of the per-calendar event id, so the same meeting converges into one thread across users. ([#118](https://github.com/plotday/plot/pull/118) [`44db2b0`](https://github.com/plotday/plot/commit/44db2b05529eb5f2f9e0ffaa5a06c854d037c7ea))

## 0.45.0

### Added

- `todo` boolean on `LinkTypeConfig.statuses[]` so connectors can indicate which status represents the active/to-do state (e.g. Gmail's "starred", Linear's "To Do"). When a user adds a thread to Plot's agenda, done-status links flip to this status so the link widget and thread tags reflect the active state. ([`fe72bb9`](https://github.com/plotday/plot/commit/fe72bb96e60b3fb9eb8d4ace5afbce32a34a1477))
- SyncContext parameter to onChannelEnabled with syncHistoryMin hint for plan-based sync limits

### Changed

- `accessContacts` accepts `NewContact[]` (email-based contacts) on write types, returns `Contact[]` on read types. Added `Contact` type for resolved contact identity. ([`e7a57ac`](https://github.com/plotday/plot/commit/e7a57ac589647c19b7f1f513f9eb11acb807d204))
- `network.createWebhook()` now runs callbacks asynchronously by
- NewNote.accessContacts now accepts NewContact objects (email-based) in addition to ActorId UUIDs, resolved server-side. Mentions on notes are for twist/connector dispatch routing only — removed person contacts from mentions in Gmail and Slack connectors. ([#115](https://github.com/plotday/plot/pull/115) [`eee1d19`](https://github.com/plotday/plot/commit/eee1d19ee28fdf71687e18dafd1429b2641fb6b4))
- Twists are now workspace-level (installed by a user, not by a priority). `Twist.activate()` no longer receives a `priority` argument, `Tool.preActivate`/`postActivate` drop their `priority` argument, and `Channel.priorityId` is gone — priority routing happens automatically server-side via `match_priority_for_user` when a twist creates threads or links without an explicit target. Added: `this.userId` on `Twist` (the installing user's ID) and new `Plot.getUserId()` / `Plot.getDefaultPriorityId()` helpers for twists that need to resolve the owner or their root priority explicitly. ([#115](https://github.com/plotday/plot/pull/115) [`25bc1b1`](https://github.com/plotday/plot/commit/25bc1b10520daa82485efaaeb0916f17adc0cd13))
- Thread and Note visibility model — replaced `private` boolean with `access` enum ('public'|'members'|'private') and `accessContacts` array on Thread, and replaced `private` boolean with `accessContacts` array on Note. Removed `mentions` from Thread type. Note `mentions` now contains only twist/connector IDs for dispatch routing. ([#112](https://github.com/plotday/plot/pull/112) [`31d1c05`](https://github.com/plotday/plot/commit/31d1c058efb3f1ec3df777efa21f17be16db6b56))

### Removed

- `PickPriorityConfig` type and `pickPriority` field from `NewThread` and `NewLink`. Priority matching is now handled by user-defined priority rules on the server. Use `priority` for explicit placement or omit for automatic classification. ([#115](https://github.com/plotday/plot/pull/115) [`0d25528`](https://github.com/plotday/plot/commit/0d25528dde120d45369f56a72460ee692635a159))

## 0.44.0

### Added

- "action" thread type for task threads ([`d7d5336`](https://github.com/plotday/plot/commit/d7d533625bb148c2b895994d682cae167d1e8522))
- `onNoteUpdated(note, thread)` hook to Connector base class for writing back note-level changes (e.g., reaction tags) to external services ([`16b6929`](https://github.com/plotday/plot/commit/16b6929d70fef76800402e1476db70d65ded48de))
- `pubsub` option to `Network.createWebhook()` for creating Google Pub/Sub-backed webhooks. When `pubsub: true`, returns a Pub/Sub topic name instead of a webhook URL, enabling connectors to integrate with services that deliver events via Pub/Sub (e.g., Google Workspace Events API). ([`e2ea4f1`](https://github.com/plotday/plot/commit/e2ea4f1ad24e0d22578ffe4f55e3143d23cb101f))
- `relatedSource` field on `Link` type for cross-connector thread bundling. Links whose `source` matches another link's `relatedSource` automatically share the same thread, regardless of creation order. ([`b854bdd`](https://github.com/plotday/plot/commit/b854bddc8f7b4c67f01f1a14f6f33deba82332f1))
- Todoist auth provider ([`855f2d4`](https://github.com/plotday/plot/commit/855f2d445237c0a9e766f5a087dbbbfd2343b947))
- `ThreadAccess.Full` permission level for listing, updating, and moving any thread in the twist's priority scope, and creating notes on any thread.
- optional `linkTypes` field to `Channel` type for per-channel link type configs (e.g., dynamic issue statuses per Linear team) ([`94aaa03`](https://github.com/plotday/plot/commit/94aaa03b7cd4f6388f5f836b9b0ac266f2098abd))
- `checkForTasks` field on `NewNote` for opt-in AI task detection on messaging notes ([`477ff6c`](https://github.com/plotday/plot/commit/477ff6cf124a1658b1127770e3a043e25ce6176d))
- `shared` and `keyOption` properties on Connector for declaring auth model (individual/shared, OAuth/key) ([`6fb33c2`](https://github.com/plotday/plot/commit/6fb33c2f48219e813510c0c665b528c215ff6bed))
- Imap built-in tool for high-level IMAP email access (connect, list mailboxes, search, fetch messages, set flags) ([`d977bc9`](https://github.com/plotday/plot/commit/d977bc9df21bc8494d7f9843e1b4a81ac8f50e63))
- `private` field on `NewLink` type for creating private threads via `saveLink()` ([`be8ff14`](https://github.com/plotday/plot/commit/be8ff140550c348d59bfe44da44442c5c8a7a071))
- `secure` property on TextDef for encrypted option values (API keys, secrets)
- `singleChannel` property on `Connector` for connectors with a single implicit channel ([`6fb33c2`](https://github.com/plotday/plot/commit/6fb33c2f48219e813510c0c665b528c215ff6bed))
- SMTP built-in tool for email sending with connect, send, and disconnect operations ([`07b2d1d`](https://github.com/plotday/plot/commit/07b2d1d07eb07a442b78ce1fc3ed6f0edc27b0cd))
- `defaultCreateThreads` field to `LinkTypeConfig` for connectors to specify the default thread creation mode per link type ([`9f3e7c0`](https://github.com/plotday/plot/commit/9f3e7c0ab4ba367184287f111068231bab4e1dea))
- `helpText` and `helpUrl` optional fields to `TextDef` for displaying help instructions below text input options ([`8b1b81e`](https://github.com/plotday/plot/commit/8b1b81e02487f93283d41490d8f7af4881422bd8))

### Changed

- `onNoteCreated` return type from `Promise<void>` to `Promise<string | void>` — returning a string sets the note's key for external system deduplication ([`16b6929`](https://github.com/plotday/plot/commit/16b6929d70fef76800402e1476db70d65ded48de))
- `NewContact` type now requires at least `name` or `email` to prevent "Unknown" contacts in the UI ([`f827e57`](https://github.com/plotday/plot/commit/f827e5718e537ab50cff8159f6d6fa704a197221))
- Enhanced JSDoc on `this.run()` (Twist/Tool), `onChannelEnabled` (Connector) to clarify when to use `this.run()` vs `this.runTask()` and warn about blocking the HTTP response in lifecycle methods. ([`d76cf40`](https://github.com/plotday/plot/commit/d76cf40ecec076134239a89f74e11e662408e0bc))
- `NewLinkWithNotes.title` is now optional — omit to preserve existing title on upsert ([`bf3992a`](https://github.com/plotday/plot/commit/bf3992aefdae844ca7c00b9044ef81f7f2513947))

### Removed

- `id` field from `Link` type and `{ id: Uuid }` variant from `NewLink` union. Use `source` for link identification. ([`02e701d`](https://github.com/plotday/plot/commit/02e701d9ce9942848debfef84a52831db353e205))

### Fixed

- `plot deploy` now reads `publisher` and `publisherUrl` from package.json to auto-resolve the publisher for non-personal deployments, and fails with exit code 1 in non-interactive environments instead of silently succeeding. ([`e155366`](https://github.com/plotday/plot/commit/e1553663b7b9958d727492f02fbf36b551d84824))
- CLI deploy command now retries on 429 (rate-limited) and 503 (service unavailable) responses with Retry-After support ([`2a511b7`](https://github.com/plotday/plot/commit/2a511b7ae1306a734634a130f904963170584051))

## 0.43.0

### Added

- `imageWidth` and `imageHeight` optional fields to file action type for image dimension metadata ([`95b2e1d`](https://github.com/plotday/plot/commit/95b2e1d69993541bf69280f2c6aea65fe73e53bc))
- Reply count tag (Tag.Reply = 1019) for flagging notes that need a response ([`0b24fe5`](https://github.com/plotday/plot/commit/0b24fe5ab3d839aa59d7f209d876422972493c1f))
- `getOwner()` method on the Plot tool — returns the full Actor (id, name, email) for the twist owner ([`80dcd07`](https://github.com/plotday/plot/commit/80dcd07e4a0ba37858561c61f1eaca5e6fdad398))
- `ThreadType` type and `type` field on `Thread`, `NewThread`, and `ThreadUpdate` for setting thread sub-type/category ([`5446cf7`](https://github.com/plotday/plot/commit/5446cf7f1ecc933fbba56d0801fcbca8cf5bc7c1))

### Changed

- Update AIModel enum to latest model versions — added Claude Opus 4.6 and Sonnet 4.6, removed Claude Sonnet 4.5, Opus 4.1, and Claude 3.7 Sonnet ([`4b85122`](https://github.com/plotday/plot/commit/4b85122a815008c6fe2dd943d744ff2687c1dfa4))

## 0.42.0

### Added

- `done` boolean field to LinkTypeConfig status entries to indicate completion statuses ([`e8209e3`](https://github.com/plotday/plot/commit/e8209e39e074d26a59f73a01326bc204f5fb73eb))

## 0.41.0

### Changed

- Made `NewContact.email` optional to support provider-ID-based contact resolution ([#107](https://github.com/plotday/plot/pull/107) [`823d6ec`](https://github.com/plotday/plot/commit/823d6ec45af8ee896fd8c08caba515ff6f49f27b))
- Renamed `--source` CLI flag to `--connector` in `plot create` command to match SDK naming ([`f30e3ba`](https://github.com/plotday/plot/commit/f30e3ba91bc91967133d51b975d3f1be68af8dc7))

### Removed

- `addContacts()` from Plot tool public API (contacts are created implicitly through thread/note creation)

## 0.40.0

### Added

- optional `tag` field to status definitions in `LinkTypeConfig.statuses` for propagating tags to threads (e.g., `tag: Tag.Done` marks the thread as Done) ([`50d4359`](https://github.com/plotday/plot/commit/50d4359a52a7dbfdfc63cc37f9a8fa77a3255ecc))
- `supportsAssignee` option to `LinkTypeConfig` for displaying and changing link assignees in the UI ([`ebc6ca5`](https://github.com/plotday/plot/commit/ebc6ca57fd573c9a6c621e48915242af5f607e6b))

## 0.39.0

### Added

- AIOptions, AICapabilities types and available() method to AI tool for controlling AI feature availability in twists ([#103](https://github.com/plotday/plot/pull/103) [`faba1b9`](https://github.com/plotday/plot/commit/faba1b95b0d1eace20e0cc7b045e469083478d8b))
- `thread.defaultMention` and `note.defaultMention` options to Plot tool for opt-in auto-mentioning on thread replies ([`62c95d0`](https://github.com/plotday/plot/commit/62c95d0e06ab6ae81f61a6f394e6895af19d98d2))

### Changed

- BREAKING: Renamed Source to Connector across the SDK. The `Source` class is now `Connector`, the `./source` export is now `./connector`, and all `@plotday/source-*` packages are now `@plotday/connector-*`. A deprecated `Source` alias is re-exported for backward compatibility. ([`27aed55`](https://github.com/plotday/plot/commit/27aed55e66268b40a8e52059d85a9e37cbbc9542))

## 0.38.0

### Added

- Semantic search tool for notes and links in the Plot tool, with configurable limit, threshold, and priority scope ([`fde9d49`](https://github.com/plotday/plot/commit/fde9d497a9480ba367bc123c8137428615b21aa0))
- Thread reference action type for navigating to related threads ([`fde9d49`](https://github.com/plotday/plot/commit/fde9d497a9480ba367bc123c8137428615b21aa0))

## 0.37.0

### Added

- Schedule type with ScheduleContact for event scheduling, recurring events, and per-user schedules ([#101](https://github.com/plotday/plot/pull/101) [`46fe8f1`](https://github.com/plotday/plot/commit/46fe8f1a3c86b73d71bac3b4b6119d43fd3481e1))
- Source.onThreadRead() hook for writing back read/unread status to external services ([#101](https://github.com/plotday/plot/pull/101) [`6e9dcf5`](https://github.com/plotday/plot/commit/6e9dcf5317a713747ccced73021e6c14e27aab3b))
- Source base class for building service integrations with provider, scopes, and lifecycle management ([#101](https://github.com/plotday/plot/pull/101) [`46fe8f1`](https://github.com/plotday/plot/commit/46fe8f1a3c86b73d71bac3b4b6119d43fd3481e1))
- LinkType config for sources and channelId on Link for account-based priority routing ([#101](https://github.com/plotday/plot/pull/101) [`46fe8f1`](https://github.com/plotday/plot/commit/46fe8f1a3c86b73d71bac3b4b6119d43fd3481e1))
- Package exports for ./source and ./schedule modules ([#101](https://github.com/plotday/plot/pull/101) [`46fe8f1`](https://github.com/plotday/plot/commit/46fe8f1a3c86b73d71bac3b4b6119d43fd3481e1))

### Changed

- BREAKING — Refactor Source base class to own provider identity and channel lifecycle ([#101](https://github.com/plotday/plot/pull/101) [`46fe8f1`](https://github.com/plotday/plot/commit/46fe8f1a3c86b73d71bac3b4b6119d43fd3481e1))
- BREAKING — Rename Activity to Thread and Link to Action throughout the SDK (types, methods, filters) ([#101](https://github.com/plotday/plot/pull/101) [`46fe8f1`](https://github.com/plotday/plot/commit/46fe8f1a3c86b73d71bac3b4b6119d43fd3481e1))
- BREAKING — Twist lifecycle hooks onThreadUpdated, onNoteCreated moved from Plot options to Twist base class methods; added onLinkCreated, onLinkUpdated, onLinkNoteCreated, onOptionsChanged ([#101](https://github.com/plotday/plot/pull/101) [`6e9dcf5`](https://github.com/plotday/plot/commit/6e9dcf5317a713747ccced73021e6c14e27aab3b))
- BREAKING — Removed deprecated IntegrationProviderConfig and IntegrationOptions types; added archiveLinks(filter) for bulk-archiving links ([#101](https://github.com/plotday/plot/pull/101) [`6e9dcf5`](https://github.com/plotday/plot/commit/6e9dcf5317a713747ccced73021e6c14e27aab3b))
- BREAKING — Removed thread.updated and note.created callbacks from Plot options (use Twist.onThreadUpdated/onNoteCreated instead); added `link: true` option and `getLinks(filter?)` method for link processing ([#101](https://github.com/plotday/plot/pull/101) [`6e9dcf5`](https://github.com/plotday/plot/commit/6e9dcf5317a713747ccced73021e6c14e27aab3b))
- BREAKING — Rename Syncable to Channel in Integrations tool, add saveLink() and saveContacts() methods ([#101](https://github.com/plotday/plot/pull/101) [`46fe8f1`](https://github.com/plotday/plot/commit/46fe8f1a3c86b73d71bac3b4b6119d43fd3481e1))

### Removed

- BREAKING — Deprecated twister functions and types ([#101](https://github.com/plotday/plot/pull/101) [`46fe8f1`](https://github.com/plotday/plot/commit/46fe8f1a3c86b73d71bac3b4b6119d43fd3481e1))
- BREAKING — Common interfaces (calendar, documents, messaging, projects, source-control) replaced by individual source implementations ([#101](https://github.com/plotday/plot/pull/101) [`46fe8f1`](https://github.com/plotday/plot/commit/46fe8f1a3c86b73d71bac3b4b6119d43fd3481e1))
- BREAKING — RSVP tags (Attend, Skip, Undecided) from Tag enum, replaced by ScheduleContact ([#101](https://github.com/plotday/plot/pull/101) [`46fe8f1`](https://github.com/plotday/plot/commit/46fe8f1a3c86b73d71bac3b4b6119d43fd3481e1))

## 0.36.0

### Added

- Options tool for defining user-configurable options for twists ([#96](https://github.com/plotday/plot/pull/96) [`f573ef1`](https://github.com/plotday/plot/commit/f573ef1b3a45abdccfcdc453d4e24221500b907e))

## 0.35.0

### Added

- Batch updates using ActivityUpdate.match with updateActivity() ([#93](https://github.com/plotday/plot/pull/93) [`f3ccb2f`](https://github.com/plotday/plot/commit/f3ccb2f91344b927536d367cea467e4cc2efefe3))
- Activity.order ([`6269510`](https://github.com/plotday/plot/commit/6269510ce4fe0fea5e95f40643c28fee7f9a0745))

### Changed

- BREAKING: Rewrite of the Integrations tool and all sync tools to support much improved sync configuration when installing or editing a twist ([#93](https://github.com/plotday/plot/pull/93) [`f3ccb2f`](https://github.com/plotday/plot/commit/f3ccb2f91344b927536d367cea467e4cc2efefe3))

## 0.34.0

### Added

- Note.reNote for notes replying to other notes (e.g. comment threads within a document) ([`057fc71`](https://github.com/plotday/plot/commit/057fc713a64db9dda04c7ddf687e86168ae95cf1))
- Contact.source for external service PII compliance ([`df93091`](https://github.com/plotday/plot/commit/df93091c6da6eed16ebc9daa9931677f670d2688))

### Changed

- Tightened types so Activity.done only available when type == Action ([`6ab1839`](https://github.com/plotday/plot/commit/6ab18392520eb6ef69a43212d2b66d599c9443e4))

## 0.33.2

### Added

- File attachments. For now, just metadata is available to twists. ([`279cb7b`](https://github.com/plotday/plot/commit/279cb7b23640a2d027f303b070f83c48f285bf4e))

## 0.33.1

### Added

- addRecurrenceExdates and removeRecurrenceExdates ([`4bdbd52`](https://github.com/plotday/plot/commit/4bdbd52ea397dc556e5fdbddcc0d6f3e8c05f95b))

## 0.33.0

### Added

- Update Note.key when updating with id ([`0004e24`](https://github.com/plotday/plot/commit/0004e241ea1c61a74141671a014788d4f96b9383))

### Changed

- BREAKING: All integrations are now individual, always acting on behalf of a particular user. ([`2208632`](https://github.com/plotday/plot/commit/22086320eb79c3cbe6c95aeaeb34472e4c3d7b50))

## 0.32.1

### Fixed

- Mark new items read for the author ([`aac9e42`](https://github.com/plotday/plot/commit/aac9e428c6dc07dfad8c284c4761eaba4088a310))

## 0.32.0

### Added

- Provide an activity preview ([`97e4949`](https://github.com/plotday/plot/commit/97e4949664c04b886bdd55c4666ac681bd012065))

### Changed

- BREAKING: Improve immutability of Activity.source and Note.key by using IDs rather than URLs ([`97e4949`](https://github.com/plotday/plot/commit/97e4949664c04b886bdd55c4666ac681bd012065))
- RSVP tags (attend, skip, undecided) are mutually exclusive per actor ([`b579997`](https://github.com/plotday/plot/commit/b5799978948ffffcffb3afb01ccf90997ee652b4))
- Explicitly set Activity.archived = false on initial syncs ([`6a0aec1`](https://github.com/plotday/plot/commit/6a0aec11ad1745c3b2500269de0335907b610e58))

## 0.31.2

### Added

- Priority.color for setting the priority theme color ([`bdb98a5`](https://github.com/plotday/plot/commit/bdb98a50860da15a7e2156cf2ac07236f5016fc7))

## 0.31.1

### Added

- Activity.kind to indicate the icon that should be used to depict the activity ([`3c8f841`](https://github.com/plotday/plot/commit/3c8f841b5c881fc42e0acadcc1d54859354a7815))

## 0.31.0

### Changed

- BREAKING: Return only the id when creating/upserting to increase performance ([`9428f5b`](https://github.com/plotday/plot/commit/9428f5bdca0221984836a67f902c8e7e691223b8))

### Fixed

- BREAKING: Fixed many issues with recurring activity, which required some changes to ActivityOccurrence ([`289cd83`](https://github.com/plotday/plot/commit/289cd83e292d1ebdd83b55990bffa33c9639000b))
- Clearer error when the server can't be reached during deploy ([`53585ca`](https://github.com/plotday/plot/commit/53585cac03d26ff0500dc227c81e349a3986380d))

## 0.30.0

### Changed

- Improve callback type safety ([`c6b5e0b`](https://github.com/plotday/plot/commit/c6b5e0bb99a3672325e253d824586571237069ca))

## 0.29.0

### Added

- Support for more serializable types, especially Date ([`1623e18`](https://github.com/plotday/plot/commit/1623e18a97afa97bb28f0c8497eabca1805d78a9))
- archived field on Priority, Activity, and Note ([`6685c33`](https://github.com/plotday/plot/commit/6685c330c617046b213524b058330745d2fee7a9))

### Changed

- BREAKING: Minor type and signature changes in preparation for the stable 1.0 interface ([`6685c33`](https://github.com/plotday/plot/commit/6685c330c617046b213524b058330745d2fee7a9))

## 0.28.0

### Added

- Activity.source and Note.key for upserts ([`8053f7a`](https://github.com/plotday/plot/commit/8053f7a49ca0dc871bd4e1ef8edb4dd54f1abaef))

## 0.27.0

### Added

- created_at for item's original creation time in the source system ([#75](https://github.com/plotday/plot/pull/75) [`5f0ebf3`](https://github.com/plotday/plot/commit/5f0ebf3aa347454c332b7bfeb799f022191a7fdb))

### Changed

- BREAKING: Replace Activity.source for linking with source items with generated and stored UUIDs ([`606b396`](https://github.com/plotday/plot/commit/606b396bb063a70c99200798287d29f5fd026bde))
- BREAKING: Support either IDs or email for contact fields ([`606b396`](https://github.com/plotday/plot/commit/606b396bb063a70c99200798287d29f5fd026bde))

## 0.26.0

### Added

- Note creation callback for new notes added to activities created by a twist ([`b0c756d`](https://github.com/plotday/plot/commit/b0c756ddd3b2f334f1a19248dbe9279b2777a5ec))
- activity.update field in the Plot tool for seeing only what changed ([`b0c756d`](https://github.com/plotday/plot/commit/b0c756ddd3b2f334f1a19248dbe9279b2777a5ec))

### Changed

- BREAKING: Moved unread flag for new activity and notes into those items ([`c72a690`](https://github.com/plotday/plot/commit/c72a6902bf9798b666abc8d9cc652a18973920f1))

## 0.25.1

### Added

- WebhookRequest.rawBody for signature verification ([`804d217`](https://github.com/plotday/plot/commit/804d21783512fd023940a6b281330fada22cf7bb))

### Changed

- BREAKING: Tightened callback types to catch mismatched arguments ([`9293f29`](https://github.com/plotday/plot/commit/9293f290f727cc76a7eb6fdcb1460a100f5117ef))

## 0.25.0

### Changed

- Breaking: Renamed Note noteType to contentType ([`844be3f`](https://github.com/plotday/plot/commit/844be3f7fcdcad7094734ce4a6d23594e3add068))

## 0.24.0

### Added

- Create activities with unread: false ([`fe78a0f`](https://github.com/plotday/plot/commit/fe78a0f9fba7db4a015b807d908cf509f4675b02))
- Activity.source upsert behaviour ([`fe78a0f`](https://github.com/plotday/plot/commit/fe78a0f9fba7db4a015b807d908cf509f4675b02))

### Changed

- BREAKING: Remove Attachment and Link tags, as they are computed and read-only ([`4d32630`](https://github.com/plotday/plot/commit/4d32630101a8a0f4f7768318a9eeb85bdfe24127))
- Tightened tag types. ([`4c73a88`](https://github.com/plotday/plot/commit/4c73a88c94fd5e75f35ab707b6975638296110d3))

## 0.23.0

### Added

- Update Activity assignee ([`f0cda95`](https://github.com/plotday/plot/commit/f0cda95e9bda28d503557ff2149da47ebbb27f14))

### Changed

- BREAKING: Note content field renamed for clarity ([`e66e968`](https://github.com/plotday/plot/commit/e66e968776c67afd376354317d94656b773b2d9f))

## 0.22.0

### Changed

- BREAKING: Refactored Activity and Note types for clarity and type safety. ([#67](https://github.com/plotday/plot/pull/67) [`2aa5b8f`](https://github.com/plotday/plot/commit/2aa5b8fe57fe785bdc41f8347e62ba4beab0c3c5))

## 0.21.0

### Changed

- BREAKING: ActivityType.Task to ActivityType.Action to match product language ([`dd13fed`](https://github.com/plotday/plot/commit/dd13fed684fb1499d92355f168a733b73738f1b6))

## 0.20.0

### Added

- Hints for routing new Activity into the correct Priority ([`765487b`](https://github.com/plotday/plot/commit/765487b0ea2acadf8ce47e887f4494548dfdca83))
- Conferencing links ([`e8349dd`](https://github.com/plotday/plot/commit/e8349ddb79f7afd914728e93366a1525086911b1))
- Common Messaging interface
- Notion, Slack, Atlassian, Linear, Monday, GitHub, Asana, and HubSpot integrations ([`bc6eac1`](https://github.com/plotday/plot/commit/bc6eac16283f3fbfbd92cdd0f041e1adde3bbff3))
- Plot.getActors() to retrieve name, email, and type for people and twists.
- Slack and Gmail webhook support ([`4e262a0`](https://github.com/plotday/plot/commit/4e262a04cd506cb679840fc1ae83fef3130e142e))
- Attend, Skip, Undecided tags ([`34a5860`](https://github.com/plotday/plot/commit/34a5860c389debc30c876fea933feb3ba87b719b))
- NoteType with support for HTML and text notes in addition to the default (Markdown) ([`765487b`](https://github.com/plotday/plot/commit/765487b0ea2acadf8ce47e887f4494548dfdca83))

### Changed

- BREAKING: Renamed to @plotday/twister ([#65](https://github.com/plotday/plot/pull/65) [`ba7469d`](https://github.com/plotday/plot/commit/ba7469d22d8412a6ff4f17ee7d5d9c3b18ec59e7))

### Fixed

- login path error ([`cd8c1de`](https://github.com/plotday/plot/commit/cd8c1de84c07957c6189babd900479a1c7cd582a))

## 0.19.1

### Added

- Text and HTML (in addition to Markdown) note types ([`9516790`](https://github.com/plotday/plot/commit/95167908d414db8d92eddea83e85948482917d3d))

## 0.19.0

### Added

- Activity.threadRoot ([`bdbedca`](https://github.com/plotday/plot/commit/bdbedca3bd46a98a0892fa7d6710b1b2bfe82c5b))

### Changed

- BREAKING: Plot Activity intents now take an object that can include examples ([`431d8c7`](https://github.com/plotday/plot/commit/431d8c7c07965bbf893d1e19efce8007c4b786ff))

## 0.18.3

### Changed

- Update several references to the previous twist subcommand group ([`02936a6`](https://github.com/plotday/plot/commit/02936a671496c6124a31c1c54d69598276f4d8bb))

### Fixed

- build fixes ([`c3c83a7`](https://github.com/plotday/plot/commit/c3c83a7cddc72966209721fceec2eeb96c385dc2))

## 0.18.2

### Fixed

- README links ([#59](https://github.com/plotday/plot/pull/59) [`a1542bc`](https://github.com/plotday/plot/commit/a1542bc96a0d158b6080d5e44fc5eb1b9d87781e))

## 0.18.1

### Fixed

- README links ([#57](https://github.com/plotday/plot/pull/57) [`c475d13`](https://github.com/plotday/plot/commit/c475d13ae250f3b10f649f9bbc6515ba16bbbb49))

## 0.18.0

### Added

- Docs for build.plot.day ([#53](https://github.com/plotday/plot/pull/53) [`262d280`](https://github.com/plotday/plot/commit/262d2808858fdcb7a69f92d22286c435bb3f479f))

### Changed

- Renamed @plotday/sdk to @plotday/twister. ([#55](https://github.com/plotday/plot/pull/55) [`8106ba0`](https://github.com/plotday/plot/commit/8106ba0597966909dd223b800adf4f63b9c4b278))

## 0.17.0

### Added

- Improved stack traces ([#51](https://github.com/plotday/plot/pull/51) [`02c6a1e`](https://github.com/plotday/plot/commit/02c6a1e834b9aa645f29191ed59ee5b66b70c32a))

### Changed

- **BREAKING: Package renamed from @plotday/sdk to @plotday/twister**
  - Product name changed to "Plot twist Builder"
  - Directory renamed from `public/sdk/` to `public/builder/`
  - Export `./sdk-docs` renamed to `./builder-docs`
  - Function `getSDKDocumentation()` renamed to `getBuilderDocumentation()`
  - See deprecation notice in @plotday/sdk@0.17.1
- BREAKING: Creating and updating Activity using the Plot tool now requires requesting permission in options ([#51](https://github.com/plotday/plot/pull/51) [`b3242e4`](https://github.com/plotday/plot/commit/b3242e4adecea87011379ac2dd58712dc91729d7))
- BREAKING: Twists and Tools now define a build() method to gain access to tools, which are then available via this.tools.
- BREAKING: Renamed callCallback, run, cancel, and cancelAll twist/Tool functions ([#51](https://github.com/plotday/plot/pull/51) [`49b4dc9`](https://github.com/plotday/plot/commit/49b4dc94e08906a89799903610325c5fe7ebe10b))
- BREAKING: Improved callback ergonomics and types to use functions instead of strings ([#51](https://github.com/plotday/plot/pull/51) [`02c6a1e`](https://github.com/plotday/plot/commit/02c6a1e834b9aa645f29191ed59ee5b66b70c32a))

## 0.16.1

### Fixed

- Several references to call() renamed to callCallback() ([#49](https://github.com/plotday/plot/pull/49) [`2405588`](https://github.com/plotday/plot/commit/2405588f3c296b7e06057f11096e43771615a4b5))

## 0.16.0

### Changed

- BREAKING: Rename twist.call() and Tool.call() to callCallback() to avoid confusion with JavaScript's Object.call(). ([#47](https://github.com/plotday/plot/pull/47) [`9ed2cf4`](https://github.com/plotday/plot/commit/9ed2cf4e019b5f7f0e04d35c383675ca4b6cd137))

## 0.15.0

### Changed

- BREAKING: Twists are now restricted to the http URLs they request via tools.enableInternet(). ([#45](https://github.com/plotday/plot/pull/45) [`0490f8e`](https://github.com/plotday/plot/commit/0490f8e801199893a971fdbfbead6ba2973a53c7))

## 0.14.8

### Added

- Documentation on generating twists from a spec ([#43](https://github.com/plotday/plot/pull/43) [`83ebb7e`](https://github.com/plotday/plot/commit/83ebb7ef96770e1d8ae42b62e8d48200424ee35e))

### Changed

- Improve developer docs in SDK readme ([#43](https://github.com/plotday/plot/pull/43) [`5ee6cab`](https://github.com/plotday/plot/commit/5ee6cab4a71584bdf7cbc176499c9b55e45f67da))

## 0.14.7

### Fixed

- Fix typo in readme ([#41](https://github.com/plotday/plot/pull/41) [`8054b77`](https://github.com/plotday/plot/commit/8054b777ac582ed972526a71548918e55d8c3de0))

## 0.14.6

### Changed

- Fix README link ([#39](https://github.com/plotday/plot/pull/39) [`6f06dce`](https://github.com/plotday/plot/commit/6f06dce1482f8d7af3c547bad2c0badf8d8e5f70))

## 0.14.5

### Changed

- Add login information to the README ([#37](https://github.com/plotday/plot/pull/37) [`f7439dc`](https://github.com/plotday/plot/commit/f7439dccdf05c3434a47800ffcd311d360d15cb3))

## 0.14.4

### Changed

- ActivityType.Action now has a default start of new Date() ([#34](https://github.com/plotday/plot/pull/34) [`d87d285`](https://github.com/plotday/plot/commit/d87d2850a2ac2c30bade586fc7f1654f37ff6101))

## 0.14.3

### Fixed

- Improve LLM guidance for activity creation ([#32](https://github.com/plotday/plot/pull/32) [`8f30644`](https://github.com/plotday/plot/commit/8f306448437af8bf5e20a5387594c0e655fcddf9))

## 0.14.2

### Added

- plot twist logs keepalive

## 0.14.1

### Changed

- plot twist logs takes id from package.json ([#29](https://github.com/plotday/plot/pull/29) [`9fefaca`](https://github.com/plotday/plot/commit/9fefaca426640fb84f7433471340d4f8ab4ba7b4))

## 0.14.0

### Added

- plot twist logs ([#27](https://github.com/plotday/plot/pull/27) [`8030c59`](https://github.com/plotday/plot/commit/8030c5951a72dc6326b06d798ea150843cdc0143))

### Fixed

- Improper use of tools in twist and Tool base classes causing "Tool not found" errors ([#27](https://github.com/plotday/plot/pull/27) [`43ce7ab`](https://github.com/plotday/plot/commit/43ce7abdd97bea1fc8ee8569fd371f5f249c498c))

## 0.13.1

### Added

- Progress updates for twist generate and deploy ([#25](https://github.com/plotday/plot/pull/25) [`b9c3528`](https://github.com/plotday/plot/commit/b9c35288c9a49a9a4d21f59b637146e33c15fe87))
- Install latest SDK package after generate ([#25](https://github.com/plotday/plot/pull/25) [`b9c3528`](https://github.com/plotday/plot/commit/b9c35288c9a49a9a4d21f59b637146e33c15fe87))

### Fixed

- Several instances of Twists and Tools missing the id argument ([#24](https://github.com/plotday/plot/pull/24) [`2d53d37`](https://github.com/plotday/plot/commit/2d53d3794419ee218976d6468319ae9129c93088))

## 0.13.0

### Changed

- BREAKING: Add twist id to twist and Tool constructors ([#22](https://github.com/plotday/plot/pull/22) [`34e7e43`](https://github.com/plotday/plot/commit/34e7e439d2d625e6749195623fe55389ff857e2a))
- Generate twist-guide.ts from twist.template.md ([#21](https://github.com/plotday/plot/pull/21) [`fee051d`](https://github.com/plotday/plot/commit/fee051dcb33729826cb31910e74fbdf8f57acdeb))

## 0.12.2

### Fixed

- Add lint and deploy scripts to generated package.json ([#19](https://github.com/plotday/plot/pull/19) [`0910b87`](https://github.com/plotday/plot/commit/0910b8770cd5cc404d5cedbe0e3380a624f7e348))

## 0.12.1

### Changed

- Export LLM docs ([#17](https://github.com/plotday/plot/pull/17) [`991afef`](https://github.com/plotday/plot/commit/991afeff288dfdaae4fb4f69a6471578149805aa))

## 0.12.0

### Changed

- BREAKING: Use ModelPreferences instead of an explicit AIModel in AI.prompt(). This supports BYOK and user preferences. ([#15](https://github.com/plotday/plot/pull/15) [`7cd2d7e`](https://github.com/plotday/plot/commit/7cd2d7e2f706abf464c2436076c30567e96a01f3))

## 0.11.1

### Changed

- Add instructions to AGENTS.md to avoid accidentally reprocessing twist-created activities ([#10](https://github.com/plotday/plot/pull/10) [`6dc8403`](https://github.com/plotday/plot/commit/6dc8403))
- improved changelog format ([#9](https://github.com/plotday/plot/pull/9) [`ceecf33`](https://github.com/plotday/plot/commit/ceecf33))
- Generate a plotTwistId on "plot twist generate" if none specified ([#10](https://github.com/plotday/plot/pull/10) [`6dc8403`](https://github.com/plotday/plot/commit/6dc8403))

### Fixed

- Set displayName on plot twist generate ([#10](https://github.com/plotday/plot/pull/10) [`6dc8403`](https://github.com/plotday/plot/commit/6dc8403))

## 0.11.0

### Added

- plot twist generate command ([#7](https://github.com/plotday/plot/pull/7) [`1d809ec`](https://github.com/plotday/plot/commit/1d809ec778244921cda072eb3744f36e28b3c1b4))

## 0.10.2

### Added

- CLAUDE.md on "plot twist create" ([#5](https://github.com/plotday/plot/pull/5) [`0ac9a95`](https://github.com/plotday/plot/commit/0ac9a95953212ccd3abb3517e143e6a0957c061b14))

## 0.10.1

### Added

- plot create --name argument ([#3](https://github.com/plotday/plot/pull/3) [`61668e5`](https://github.com/plotday/plot/commit/61668e5fb6a640f0894f922bc852f2669dd4ea39))

## 0.10.0

### Added

- README.md and AGENTS.md on "plot twist create" ([#1](https://github.com/plotday/plot/pull/1) [`dce4f2f`](https://github.com/plotday/plot/commit/dce4f2ff3596bd9c73212c90a1cd49a7dac12f48))

### Changed

- Initial automated release setup ([#1](https://github.com/plotday/plot/pull/1) [`a00de4c`](https://github.com/plotday/plot/commit/a00de4c48e3ec1d6190235d1d38fd3e5d398d480))
