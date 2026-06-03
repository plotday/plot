import 'package:plot/app_info.dart';
import 'package:plot/base.dart';
import 'package:plot/state/compose_targets.dart';
import 'package:plot/state/root_provider.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/onboarding.dart';
import 'package:plot/state/settings.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:flutter/cupertino.dart' show DefaultCupertinoLocalizations;
import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

import 'widget/window.dart';
import 'widget/widget.dart';
import 'command/command.dart';

class PlotScrollBehavior extends material.MaterialScrollBehavior {
  const PlotScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // Only Android uses the Material stretch/glow overscroll indicator.
    // iOS/macOS use bounce physics (inherent feedback), Windows/web have none.
    if (material.Theme.of(context).platform ==
        material.TargetPlatform.android) {
      return super.buildOverscrollIndicator(context, child, details);
    }
    return child;
  }
}

class App extends StatefulWidget {
  const App({super.key});

  @override
  AppState createState() => AppState();
}

class AppState extends State<App> {
  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => ThemeBloc()),
        BlocProvider(create: (_) => LocalPreferencesBloc()),
        BlocProvider(create: (_) => SettingsBloc()),
        BlocProvider(create: (_) => OnboardingBloc()),
        // Materializes the step-1 target-picker list (NewThreadPage). Depends
        // on LocalPreferencesBloc for connection MRU recency; MultiBlocProvider
        // builds providers in order so the read above is available here.
        BlocProvider(
          create: (context) =>
              ComposeTargetsBloc(context.read<LocalPreferencesBloc>()),
        ),
      ],
      child: Directionality(
        textDirection: TextDirection.ltr,
        // Provide default Material/Cupertino/Widgets localizations above the
        // app's overlays (FToaster's Overlay.wrap sits above MaterialApp), so
        // any widget mounted in any overlay can resolve CupertinoLocalizations.
        // Without this, the iOS Cupertino selection toolbar's button labels
        // (Cut/Copy/Paste, etc.) crash with a null check operator on
        // CupertinoLocalizations.of(context) when shown from an overlay above
        // the MaterialApp.
        child: Localizations(
          locale: const Locale('en'),
          delegates: const [
            material.DefaultMaterialLocalizations.delegate,
            DefaultCupertinoLocalizations.delegate,
            DefaultWidgetsLocalizations.delegate,
          ],
          child: ColourScheme(
            child: Builder(
              builder: (context) => Window(
                child: CommandProvider(
                  child: FTheme(
                    data: buildTheme(context, context.colour),
                    child: Builder(
                      builder: (context) => DefaultTextStyle(
                        style: context.theme.typography.md.copyWith(
                          color: context.theme.colors.foreground,
                          decoration: TextDecoration.none,
                        ),
                        child: material.Material(
                          type: material.MaterialType.transparency,
                          child: FToaster(
                            child: RootProvider(
                              builder: (routerConfig) => PlatformBuilder(
                                builder: (context) =>
                                    material.MaterialApp.router(
                                      title: 'Plot',
                                      debugShowCheckedModeBanner: false,
                                      scrollBehavior:
                                          const PlotScrollBehavior(),
                                      localizationsDelegates:
                                          FLocalizations.localizationsDelegates,
                                      supportedLocales:
                                          FLocalizations.supportedLocales,
                                      theme: material.ThemeData(
                                        colorScheme:
                                            material.ColorScheme.fromSeed(
                                              seedColor: const Color(
                                                0x002BDD66,
                                              ),
                                              brightness:
                                                  context.colour.brightness ==
                                                      Brightness.light
                                                  ? material.Brightness.light
                                                  : material.Brightness.dark,
                                            ),
                                      ),
                                      // MaterialApp installs an internal
                                      // DefaultTextStyle of `_errorTextStyle`
                                      // (red text with yellow double-underline
                                      // decoration) as a "wrap your content in
                                      // Material" warning. Our routes use
                                      // forui-based shells (no Material at the
                                      // page root), so per-widget styles
                                      // override the red color but inherit the
                                      // yellow underline. Replace it here
                                      // (above the Navigator, inside the
                                      // MaterialApp) so all routes see the
                                      // forui default text style instead.
                                      builder: (context, child) =>
                                          DefaultTextStyle(
                                            style: context.theme.typography.md
                                                .copyWith(
                                                  color: context
                                                      .theme
                                                      .colors
                                                      .foreground,
                                                  decoration:
                                                      TextDecoration.none,
                                                ),
                                            child:
                                                child ??
                                                const SizedBox.shrink(),
                                          ),
                                      routerConfig: routerConfig,
                                    ),
                                // Provide a Material `Theme` above MacosApp so any
                                // `Theme.of(context).scaffoldBackgroundColor` lookup
                                // inside the app (e.g. auto_route's Navigator and
                                // AutoTabsRouter empty-stack fallbacks) resolves to
                                // our dark/light surface color instead of the
                                // default light Material theme — which would
                                // otherwise produce a white flash on macOS during
                                // initial route resolution.
                                macOSBuilder: (context) => material.Theme(
                                  data: material.ThemeData(
                                    brightness:
                                        context.colour.brightness ==
                                            Brightness.light
                                        ? material.Brightness.light
                                        : material.Brightness.dark,
                                    scaffoldBackgroundColor:
                                        context.colour.background,
                                  ),
                                  child: macos.MacosApp.router(
                                    title: 'Plot',
                                    localizationsDelegates:
                                        FLocalizations.localizationsDelegates,
                                    supportedLocales:
                                        FLocalizations.supportedLocales,
                                    theme:
                                        (context.colour.brightness ==
                                                    Brightness.light
                                                ? macos.MacosThemeData.light()
                                                : macos.MacosThemeData.dark())
                                            .copyWith(
                                              primaryColor:
                                                  context.colour.accent,
                                            ),
                                    debugShowCheckedModeBanner: false,
                                    routerConfig: routerConfig,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ErrorApp extends StatefulWidget {
  final Object error;

  const ErrorApp({required this.error, super.key});

  @override
  State<ErrorApp> createState() => _ErrorAppState();
}

class _ErrorAppState extends State<ErrorApp> {
  bool _copied = false;

  String get _errorDetails {
    final buffer = StringBuffer()
      ..writeln('Failed to start Plot.')
      ..writeln()
      ..writeln('Error: ${widget.error}');

    try {
      buffer
        ..writeln()
        ..writeln(AppInfo.versionString);
    } catch (_) {
      // AppInfo may not be initialized yet
    }

    return buffer.toString();
  }

  Future<void> _copyError() async {
    await Clipboard.setData(ClipboardData(text: _errorDetails));
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => ThemeBloc()),
        BlocProvider(create: (_) => LocalPreferencesBloc()),
        BlocProvider(create: (_) => SettingsBloc()),
      ],
      child: PlatformBuilder(
        builder: (context) => material.MaterialApp(
          home: ColourScheme(
            child: material.Scaffold(
              body: Directionality(
                textDirection: TextDirection.ltr,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        spacing: 8,
                        children: [
                          const Text('Failed to start Plot.'),
                          SelectionArea(
                            child: Text(
                              'Error: ${widget.error}',
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            spacing: 8,
                            children: [
                              FButton(
                                variant: FButtonVariant.outline,
                                onPress: () => Base.signOut(),
                                prefix: const Icon(PlotIcon.signOut, size: 16),
                                child: const Text('Sign out'),
                              ),
                              FButton.icon(
                                variant: FButtonVariant.outline,
                                onPress: _copyError,
                                child: Icon(
                                  _copied
                                      ? FontAwesomeIcons.check
                                      : FontAwesomeIcons.copy,
                                  size: 16,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
