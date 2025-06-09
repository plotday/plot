# Plot Project Guidelines

## Overview

Plot is multi-platform calendar and task management app that supports time budgeting and focused work on priorities.

Supported platforms:

- Desktop: macOS, Windows
- Mobile: Android, iOS

## Data

The app is local-first, so it can function without an internet connection while syncing when one is available.
Local storage uses the Drift package (which uses SQLite), with entities defined in "apps/plot/libs/store/".
Data is synchronized to a remote Supabase (PostgreSQL) database for backup, multi-device sync, and collaboration.
The Supabase database schema is defined in "libs/db/schema/".

## Code Structure

- The main app, written in Flutter, is in "apps/plot/".
  -"apps/plot/lib/store/" contains entities and models
  -"apps/plot/lib/state/" contains Bloc state
  -"apps/plot/lib/widget/" contains UI components that are stateless unless local UI state is needed; Bloc state is passed in by pages and should not be referenced in widgets
  -"apps/plot/lib/page/" contains views, dialogs, and pages, and is responsible for connecting Bloc state to widgets
  -"apps/plot/lib/command/" contains classes defining all actions a user can perform; these can be triggered through the UI or keyboard shortcuts
- APIs and server tasks are implemented using Clouflare Workers, located in "workers/".

## Build, Run, Test Commands

- **Lint Flutter app**: `cd apps/plot && flutter analyze`
- **Build Flutter app**: The Flutter app is already running with hot reload enabled.

## Code Style Guidelines

- **Formatting**: Follow Flutter/Dart style guide with strict typing
- **Strict types**: Use strong typing with `strict-casts`, `strict-inference`, `strict-raw-types`
- **Imports**: Group imports by type (dart, flutter, third-party, local)
- **Naming**: In Dart, camelCase for variables/methods, PascalCase for classes/types. In PostgreSQL, snake_case for tables/columns.
- **Error handling**: Use nullable types and provide proper error states
- **State management**: Use Flutter Bloc for state management. Use StatelessWidgets where possible, and StatefulWidgets only for local UI state.
- **Commands**: Every user action affecting state is defined as a command in "apps/plot/libs/commands/".
- **Documentation**: Include documentation comments for public APIs
- **File structure**: Keep files focused on a single responsibility

Run `flutter analyze` before committing to ensure code quality.
