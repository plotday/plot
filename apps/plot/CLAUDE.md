# Plot App

# Build, Run, Test Commands

- **Lint**: `cd apps/plot && flutter analyze`
- **Build**: The Flutter app is already running with hot reload enabled.

## Code Structure

-"lib/store/" contains entities and models
-"lib/state/" contains Bloc state
-"lib/widget/" contains UI components that are stateless unless local UI state is needed; Bloc state is passed in by pages and should not be referenced in widgets
-"lib/page/" contains views, dialogs, and pages, and is responsible for connecting Bloc state to widgets
-"lib/action/" contains classes defining all actions a user can perform; these can be triggered through the UI or keyboard shortcuts

# Drift schema changes

When making changes to the Drift schema, follow these steps:

1. Run `flutter pub run build_runner build --delete-conflicting-outputs` to generate the necessary files.
2. Increase Store.schemaVersion

# Code Style Guidelines

- **Formatting**: Follow Flutter/Dart style guide with strict typing
- **Strict types**: Use strong typing with `strict-casts`, `strict-inference`, `strict-raw-types`
- **Imports**: Group imports by type (dart, flutter, third-party, local)
- **Naming**: Use camelCase for variables/methods, PascalCase for classes/types.
- **Error handling**: Use nullable types and provide proper error states
- **State management**: Use Flutter Bloc for state management. Use StatelessWidgets where possible, and StatefulWidgets only for local UI state. Use Bloc only in pages and commands, not widgets.
- **UI**: Use forui widgets wherever possible. Only use `flutter/widgets.dart` and `forui/forui.dart` imports, but never `flutter/material.dart`.
- **Commands**: Every user action affecting state is defined as a command in "apps/plot/libs/commands/".
- **Documentation**: Include documentation comments for public APIs
- **File structure**: Keep files focused on a single responsibility
- **Class equality**: Use the equatable package for class equality checks to avoid boilerplate code.

Run `flutter analyze` before committing to ensure code quality.
