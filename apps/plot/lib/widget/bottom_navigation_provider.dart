import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Configuration for bottom navigation bar
class BottomNavigationConfig {
  final List<FBottomNavigationBarItem> items;
  final int currentIndex;
  final ValueChanged<int> onChange;

  const BottomNavigationConfig({
    required this.items,
    required this.currentIndex,
    required this.onChange,
  });
}

/// Provides bottom navigation configuration down the widget tree
class BottomNavigationProvider extends InheritedWidget {
  final BottomNavigationConfig? config;

  const BottomNavigationProvider({
    super.key,
    required this.config,
    required super.child,
  });

  /// Retrieves the bottom navigation config from the widget tree
  /// Returns null if no provider is found
  static BottomNavigationConfig? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<BottomNavigationProvider>()
        ?.config;
  }

  @override
  bool updateShouldNotify(BottomNavigationProvider oldWidget) {
    return config != oldWidget.config;
  }
}

/// Convenient wrapper to provide bottom navigation configuration
class BottomNavigationScope extends StatelessWidget {
  final BottomNavigationConfig? config;
  final Widget child;

  const BottomNavigationScope({
    super.key,
    required this.config,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return BottomNavigationProvider(
      config: config,
      child: child,
    );
  }
}
