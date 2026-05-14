# Plot App

# Build, Run, Test Commands

- **Lint**: `cd apps/plot && flutter analyze`
- **Build**: The Flutter app is already running with hot reload enabled.

## Web font cache-busting

`pnpm build:web` runs `scripts/cache-bust-fonts.sh` after `flutter build web`,
which appends `?v=$FONT_CACHE_VERSION` to every font URL in
`build/web/assets/FontManifest.json`.

This is required because Flutter web tree-shakes icon fonts (Font Awesome,
etc.) but keeps the output filenames stable. When you change which icons the
app uses, the served font's contents change but its URL doesn't — browsers
keep serving the cached older font and new glyphs render as "tofu" boxes.

**Bump `FONT_CACHE_VERSION` in `scripts/cache-bust-fonts.sh` whenever you:**

1. Add or remove a Font Awesome icon (most commonly in
   `lib/widget/icon.dart`, but anywhere a `FontAwesomeIcons.*` is referenced
   counts).
2. Add, change, or replace a font file in `pubspec.yaml`.
3. Upgrade `font_awesome_flutter` or any other font-providing dependency.

If unsure, bump it — the cost of an unnecessary bump is one extra font
refetch per user; the cost of forgetting is broken icons until each user's
browser cache expires. After bumping, commit, then `pnpm build:web` and
redeploy.

## Code Structure

-"lib/store/" contains entities and models
-"lib/state/" contains Bloc state
-"lib/widget/" contains UI components that are stateless unless local UI state is needed; Bloc state is passed in by pages and should not be referenced in widgets
-"lib/page/" contains views, dialogs, and pages, and is responsible for connecting Bloc state to widgets
-"lib/action/" contains classes defining all actions a user can perform; these can be triggered through the UI or keyboard shortcuts

An overview of layout (including tabs and panels) can be found in "docs/layout.md".

# Drift schema changes

Version 243 was the **last full-reset migration**. All future schema changes
MUST use incremental migrations to preserve user data.

## How to make a schema change

1. Modify the table class in `lib/store/` (add column, change type, etc.)
2. Add a migration step in `Store.migration.onUpgrade` for the new version:
   ```dart
   if (from < 244) {
     await m.addColumn(threads, threads.newColumn);
   }
   ```
3. Bump `Store.schemaVersion` (e.g. 243 → 244)
4. Run `flutter pub run build_runner build`
5. Run `flutter analyze` to verify

## Common migration operations

- **Add column**: `await m.addColumn(table, table.columnName);`
- **Drop column**: `await m.alterTable(TableMigration(table));`
  (Drift rebuilds the table keeping only current columns)
- **Rename column**: `await m.alterTable(TableMigration(table,
    columnTransformer: {table.newName: table.oldName}));`
- **Add table**: `await m.createTable(newTable);`
- **Custom SQL**: `await m.database.customStatement('ALTER TABLE ...');`
- **Views**: Views are automatically recreated at the end of `onUpgrade` —
  no per-version migration needed for view changes.

## Important notes

- New nullable columns with defaults don't need data migration
- Non-nullable columns require a default value or a data migration step
- Test migrations locally before committing
- Never drop-and-recreate tables in production — user data will be lost

# Code Style Guidelines

- **Formatting**: Follow Flutter/Dart style guide with strict typing
- **Strict types**: Use strong typing with `strict-casts`, `strict-inference`, `strict-raw-types`
- **Imports**: Group imports by type (dart, flutter, third-party, local)
- **Naming**: Use camelCase for variables/methods, PascalCase for classes/types.
- **Error handling**: Use nullable types and provide proper error states
- **State management**: Use Flutter Bloc for state management. Use StatelessWidgets where possible, and StatefulWidgets only for local UI state. Use Bloc only in pages and commands, not widgets.
- **UI**: Use forui widgets wherever possible. Only use `flutter/widgets.dart` and `forui/forui.dart` imports, but never `flutter/material.dart`.
- **Modals & dialogs**: Always use the project's `Modal` widget (`lib/widget/modal.dart`) or a subclass of it (e.g. `ConfirmModal`, `FormModal`, `SelectModal`, `EditorLinkModal`). Never call `showFDialog` or `showDialog` directly and never render `FDialog` as the outermost modal — those bypass `ModalProvider`, so they render behind existing Plot modals and don't route through `Modal.handleCommandResult`. For yes/no confirmations, use `ConfirmModal(...).run(context)`.
- **Commands**: Every user action affecting state is defined as a command in "apps/plot/libs/commands/".
- **Documentation**: Include documentation comments for public APIs
- **File structure**: Keep files focused on a single responsibility
- **Class equality**: Use the equatable package for class equality checks to avoid boilerplate code.
- **UI text**: Use sentence case for all menu items, command titles, group titles, and button labels. Capitalize only the first word and proper nouns (e.g. "Add a priority", "Copy page link", "Move to new thread").

Run `flutter analyze` before committing to ensure code quality.

# Debugging: Local SQLite Database

The app uses Drift (SQLite) for local storage. Each user has their own database file.

**Database location (macOS)**:
```
~/Library/Containers/day.plot.app/Data/Documents/plot-{user_id}.sqlite
```

**Finding the right database**:
```bash
# List all user databases
ls ~/Library/Containers/day.plot.app/Data/Documents/plot-*.sqlite

# Find database for a specific user ID
ls ~/Library/Containers/day.plot.app/Data/Documents/plot-e71c60e9-2e89-49bb-a038-a0e10b399d30.sqlite
```

**Querying the database**:
```bash
# List tables
sqlite3 ~/Library/Containers/day.plot.app/Data/Documents/plot-{user_id}.sqlite ".tables"

# Query threads
sqlite3 ~/Library/Containers/day.plot.app/Data/Documents/plot-{user_id}.sqlite \
  "SELECT hex(id), title, archived_at, updated_at FROM threads LIMIT 10;"

# Check sync state
sqlite3 ~/Library/Containers/day.plot.app/Data/Documents/plot-{user_id}.sqlite \
  "SELECT * FROM sync_states;"
```

**Note**: The local database column names use snake_case (e.g., `archived_at`, `updated_at`) while the Dart models use camelCase.
