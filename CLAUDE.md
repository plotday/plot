# Plot Project Guidelines

## Build, Run, Test Commands
- **Run Flutter app**: `cd apps/plot && flutter run`
- **Dev environment**: `pnpm dev`
- **Run specific test**: `cd apps/plot && flutter test test/widget_test.dart`
- **Run all tests**: `cd apps/plot && flutter test`
- **Lint**: `cd apps/plot && flutter analyze`
- **Build for Web**: `cd apps/plot && flutter pub run build_runner build`
- **Watch code changes**: `cd apps/plot && flutter pub run build_runner watch`

## Code Style Guidelines
- **Formatting**: Follow Flutter/Dart style guide with strict typing
- **Strict types**: Use strong typing with `strict-casts`, `strict-inference`, `strict-raw-types`
- **Imports**: Group imports by type (dart, flutter, third-party, local)
- **Naming**: camelCase for variables/methods, PascalCase for classes/types
- **Error handling**: Use nullable types and provide proper error states
- **State management**: Use Flutter Bloc for state management
- **Testing**: Write widget tests for UI components
- **Documentation**: Include documentation comments for public APIs
- **File structure**: Keep files focused on a single responsibility

Run `flutter analyze` before committing to ensure code quality.