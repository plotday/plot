import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:flutter/material.dart' as material;
import 'package:platform_builder/platform_builder.dart';
import 'package:drift/drift.dart' show Value;

import 'colour_scheme.dart';

class Dialog extends StatelessWidget {
  const Dialog({
    required this.builder,
    this.header,
    this.constraints = const BoxConstraints(maxHeight: 500, maxWidth: 750),
    this.maxWidthPercentage = 0.8,
    this.maxHeightPercentage = 0.8,
    this.padding = const EdgeInsets.all(16),
    super.key,
  });

  final Widget Function(BuildContext context) builder;
  final Widget? header;
  final BoxConstraints constraints;
  final double maxWidthPercentage;
  final double maxHeightPercentage;
  final EdgeInsets padding;

  Future<Value<T>> show<T>(BuildContext context) {
    return DialogProvider.of(context).push<T>(context, this);
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    BoxConstraints constraints = this.constraints.enforce(
      BoxConstraints(
        maxHeight: mediaQuery.size.height * maxHeightPercentage,
        maxWidth: mediaQuery.size.width * maxWidthPercentage,
      ),
    );

    return PlatformBuilder(
      builder: (_) => FDialog.raw(
        style: context.theme.dialogStyle.copyWith(
          decoration: BoxDecoration(
            color: context.colour.modalBackground,
            border: Border.all(color: context.colour.border),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        builder: (context, style) => Padding(
          padding: EdgeInsets.all(1),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (header != null) header!,
                Container(
                  padding: padding,
                  child: ConstrainedBox(
                    constraints: constraints,
                    child: builder(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DialogProvider extends InheritedWidget {
  DialogProvider({required super.child, super.key});

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  Future<Value<T>> push<T>(BuildContext context, Widget dialog) async {
    final child = NoTransitionRoute<Value<T>>(
      builder: (context) => _InnerDialogProvider(
        this,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              pop(context, Value<T>.absent());
            },
          },
          child: dialog,
        ),
      ),
    );

    if (_navigatorKey.currentState == null) {
      final result = await material.showDialog<Value<T>>(
        context: context,
        requestFocus: true,
        builder: (context) {
          return Navigator(key: _navigatorKey, onGenerateRoute: (_) => child);
        },
      );
      return result ?? Value.absent();
    } else {
      final result = await _navigatorKey.currentState!.push(child);
      return result ?? Value.absent();
    }
  }

  void pop<T>(BuildContext context, Value<T> result) {
    Navigator.of(
      context,
      rootNavigator: !Navigator.of(context).canPop(),
    ).pop(result);
  }

  static DialogProvider of(BuildContext context) {
    final DialogProvider? provider =
        context
            .dependOnInheritedWidgetOfExactType<_InnerDialogProvider>()
            ?.provider ??
        context.dependOnInheritedWidgetOfExactType<DialogProvider>();
    assert(provider != null, 'No DialogProvider found in context');
    return provider!;
  }

  @override
  bool updateShouldNotify(DialogProvider oldWidget) => false;
}

class _InnerDialogProvider extends InheritedWidget {
  const _InnerDialogProvider(this.provider, {required super.child});

  final DialogProvider provider;

  @override
  bool updateShouldNotify(_InnerDialogProvider oldWidget) => false;
}

class NoTransitionRoute<T> extends PageRoute<T> {
  NoTransitionRoute({required this.builder, super.settings});

  final WidgetBuilder builder;

  @override
  Color get barrierColor => Color(0x80000000);

  @override
  String get barrierLabel => "Dialog";

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child; // No transition
  }
}
