# Plot App

# Build, Run, Test Commands

- **Lint**: `cd apps/plot && flutter analyze`
- **Build**: The Flutter app is already running with hot reload enabled.

# Code Style Guidelines

- **Formatting**: Follow Flutter/Dart style guide with strict typing
- **Strict types**: Use strong typing with `strict-casts`, `strict-inference`, `strict-raw-types`
- **Imports**: Group imports by type (dart, flutter, third-party, local)
- **Naming**: Use camelCase for variables/methods, PascalCase for classes/types.
- **Error handling**: Use nullable types and provide proper error states
- **State management**: Use Flutter Bloc for state management. Use StatelessWidgets where possible, and StatefulWidgets only for local UI state. Use Bloc only in pages and commands, not widgets.
- **Commands**: Every user action affecting state is defined as a command in "apps/plot/libs/commands/".
- **Documentation**: Include documentation comments for public APIs
- **File structure**: Keep files focused on a single responsibility
- **Class equality**: Use the equatable package for class equality checks to avoid boilerplate code.

Run `flutter analyze` before committing to ensure code quality.
