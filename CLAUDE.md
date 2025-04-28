# Plot Project Guidelines

## Code Structure

- The main app is in apps/plot.
- The database schema is in libs/db/schema.

## Build, Run, Test Commands

- **Build Flutter app**: `cd apps/plot && derry build macos`
- **Lint**: `cd apps/plot && flutter analyze`

## Code Style Guidelines

- **Formatting**: Follow Flutter/Dart style guide with strict typing
- **Strict types**: Use strong typing with `strict-casts`, `strict-inference`, `strict-raw-types`
- **Imports**: Group imports by type (dart, flutter, third-party, local)
- **Naming**: camelCase for variables/methods, PascalCase for classes/types
- **Error handling**: Use nullable types and provide proper error states
- **State management**: Use Flutter Bloc for state management
- **Documentation**: Include documentation comments for public APIs
- **File structure**: Keep files focused on a single responsibility

Run `flutter analyze` before committing to ensure code quality.

