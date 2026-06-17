import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:plot/main.dart' show navigatorKey;
import 'package:plot/command/base.dart';
import 'package:plot/command/provider.dart';
import 'package:plot/router.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/onboarding.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/priorities_shell.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Debug-only screenshot scene runner. Sets up deterministic UI states for the
/// store-listing screenshots (see docs/store-listings.md) and prints
/// `SCENE_READY:<id>` to stdout once the target screen is composed, which the
/// capture orchestrator waits on. No-op in release builds.
class Scenes {
  Scenes._();

  static final Logger _log = Logger('Scenes');

  static String? _activeId;
  static String? _draftThreadTitle;
  static String? _draftContent;

  /// Pre-seeded picker search query for S5 (NewThreadPage people-picker).
  static String? _pickerQuery;

  /// Pre-seeded search query for S6 (SearchPage).
  static String? _searchQuery;

  /// Activates a scene's auxiliary state (used by widget hooks). Called by
  /// [run]; exposed for tests.
  @visibleForTesting
  static void activate(String id,
      {String? draftThreadTitle,
      String? draftContent,
      String? pickerQuery,
      String? searchQuery}) {
    _activeId = id;
    _draftThreadTitle = draftThreadTitle;
    _draftContent = draftContent;
    _pickerQuery = pickerQuery;
    _searchQuery = searchQuery;
  }

  @visibleForTesting
  static void clear() {
    _activeId = _draftThreadTitle = _draftContent = _pickerQuery =
        _searchQuery = null;
  }

  /// True while a screenshot scene is active.
  static bool get active => _activeId != null;

  /// The reply text to pre-seed for [threadTitle], or null. Consumed by the
  /// thread bloc + composer so S2 shows a half-typed reply with a live caret.
  static String? draftContentFor(String threadTitle) =>
      (_draftThreadTitle == threadTitle) ? _draftContent : null;

  /// The people-picker search text to pre-seed for S5, or null. Consumed by
  /// [NewThreadPageState.initState] so the picker shows filtered results.
  static String? get pickerQuery => _pickerQuery;

  /// The search-field text to pre-seed for S6, or null. Consumed by
  /// [_SearchViewState.initState] so cross-source results render immediately.
  static String? get searchQuery => _searchQuery;

  /// Entry point invoked from RootProvider's UserReady handler. Awaits the
  /// router, runs the scene's setup, settles a few frames, then emits the
  /// readiness marker.
  static Future<void> run(String id) async {
    if (!kDebugMode) return;
    _log.info('Scene starting: $id');
    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows)) {
      try {
        await windowManager.ensureInitialized();
        await _placeWindowForCapture(const Size(1440, 900));
      } catch (e) {
        _log.warning('window sizing failed', e);
      }
    }
    if (id == 'S2') {
      Scenes.activate('S2',
          draftThreadTitle: 'Chelsea (A) — coaching staff plan',
          draftContent:
              "Great work, all. Let's go high press from the first whistle");
    } else if (id == 'S6') {
      Scenes.activate('S6', searchQuery: 'Chelsea');
    } else {
      Scenes.activate(id);
    }
    final context = await _awaitContext();
    if (context == null) {
      _log.warning('Scene $id: navigator never became ready');
      return;
    }
    try {
      final setup = _registry[id];
      if (setup == null) {
        _log.warning('Unknown scene: $id');
        return;
      }
      // ignore: use_build_context_synchronously
      await setup(context);
      await _settle();
      await _hideKeyboard();
      // ignore: avoid_print  (the capture orchestrator greps stdout for this)
      print('SCENE_READY:$id');
    } catch (e, s) {
      _log.warning('Scene $id failed', e, s);
    }
  }

  /// Sizes the capture window and places it on the display with the highest
  /// backing scale factor (the built-in Retina panel on a Mac), centered within
  /// that display's visible bounds.
  ///
  /// The macOS capture uses `screencapture -l <windowID>`, which renders the
  /// window bitmap at the scale of whichever display the window sits on. If the
  /// window lands on a 1× external monitor (e.g. when that monitor is the "main"
  /// display), a 1440×900 window captures at 1440×900 and the compose step —
  /// which never upscales — yields a small, low-res shot. Targeting the Retina
  /// display makes the same window capture at 2× (2880×1800), matching the rest
  /// of the macOS/Windows store assets. Reads the live display layout, so it's
  /// independent of the user's monitor arrangement / which display is primary.
  static Future<void> _placeWindowForCapture(Size size) async {
    await windowManager.setSize(size);
    try {
      // `screen_retriever` doesn't report a scale factor on macOS, but Flutter's
      // PlatformDispatcher exposes each display's devicePixelRatio — use it to
      // pick the Retina (2×) display, then match that display to a
      // `screen_retriever` entry (which carries the on-screen position) by
      // logical size so we know where to move the window.
      final uiDisplays = WidgetsBinding.instance.platformDispatcher.displays;
      ui.Display? hi;
      for (final d in uiDisplays) {
        if (hi == null || d.devicePixelRatio > hi.devicePixelRatio) hi = d;
      }
      if (hi != null && hi.devicePixelRatio > 1) {
        final wantW = hi.size.width / hi.devicePixelRatio;
        final wantH = hi.size.height / hi.devicePixelRatio;
        for (final g in await screenRetriever.getAllDisplays()) {
          if ((g.size.width - wantW).abs() < 2 &&
              (g.size.height - wantH).abs() < 2) {
            final origin = g.visiblePosition ?? Offset.zero;
            final area = g.visibleSize ?? g.size;
            await windowManager.setPosition(Offset(
              origin.dx + (area.width - size.width) / 2,
              origin.dy + (area.height - size.height) / 2,
            ));
            _log.info('Capture window placed on "${g.name}" '
                '(devicePixelRatio ${hi.devicePixelRatio})');
            return;
          }
        }
      }
    } catch (e) {
      _log.warning('high-DPI display targeting failed; centering on main', e);
    }
    // No Retina display found (or lookup failed): center on the main display.
    await windowManager.setAlignment(Alignment.center);
  }

  // ---------------------------------------------------------------------------
  // Store lookup helpers
  // ---------------------------------------------------------------------------

  static Future<String?> _priorityIdByTitle(String title) async {
    final row = await (Store.get.select(Store.get.priorities)
          ..where((p) => p.title.equals(title))
          ..limit(1))
        .getSingleOrNull();
    return row?.id.toShortString();
  }

  static Future<String?> _threadIdByTitle(String title) async {
    final row = await (Store.get.select(Store.get.threads)
          ..where((t) => t.title.equals(title))
          ..where((t) => t.archivedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
    return row?.id.toShortString();
  }

  /// Whether to show the multi-panel layout, resolved deterministically for
  /// screenshots from the real `LayoutBloc.multiPanel` flag (which is width-
  /// driven: phone = single, tablet/iPad + desktop = multi). On desktop the
  /// flag lags the capture window resize, so we poll for it to settle; on
  /// fixed-size mobile screens it's stable from launch.
  static Future<bool> _resolveMultiPanel() async {
    final desktop = !kIsWeb && (Platform.isMacOS || Platform.isWindows);
    if (desktop) {
      for (var i = 0; i < 30; i++) {
        if (LayoutBloc.instance?.state.multiPanel ?? false) return true;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return true;
    }
    // Mobile: trust the stable flag — true on a wide tablet (iPad), false on a
    // phone. A few frames of grace in case the bloc isn't built yet.
    for (var i = 0; i < 10; i++) {
      final m = LayoutBloc.instance?.state.multiPanel;
      if (m != null) return m;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Registry filled in Tasks 4 (S1) and 5 (S2).
  // ---------------------------------------------------------------------------

  static final Map<String, Future<void> Function(BuildContext)> _registry = {
    'S1': (context) async {
      final focusId = await _priorityIdByTitle("Launch women's team");
      if (focusId == null) throw StateError('S1: focus not found');
      final multi = await _resolveMultiPanel();
      if (multi) {
        final scarfId =
            await _threadIdByTitle('Founding-season scarf design');
        if (scarfId != null) {
          // Push the thread onto the focus's inner stack (the detail panel).
          // Works on Mac AND iPad — the poll waits for the inner stack's
          // default child (NewThreadRoute in multi-panel) before pushing, so
          // the thread isn't clobbered by the default-child seeding.
          // ignore: use_build_context_synchronously
          PrioritiesShell.openThread(context, focusId, scarfId);
        } else {
          // ignore: use_build_context_synchronously
          context.router.replaceAll([PriorityRoute(priorityIdString: focusId)]);
        }
      } else {
        // ignore: use_build_context_synchronously
        context.router.replaceAll([PriorityRoute(priorityIdString: focusId)]);
      }
    },
    'S2': (context) async {
      final row = await (Store.get.select(Store.get.threads)
            ..where((t) => t.title.equals('Chelsea (A) — coaching staff plan'))
            ..where((t) => t.archivedAt.isNull())
            ..limit(1))
          .getSingleOrNull();
      if (row == null) throw StateError('S2: thread not found');
      // ignore: use_build_context_synchronously
      PrioritiesShell.openThread(context,
          row.priorityId.toShortString(), row.id.toShortString());
    },
    'S3': (context) async {
      // Navigate to the Agenda tab. The scene is captured in dark mode (set via
      // launch arg, not here). No additional state needed.
      // ignore: use_build_context_synchronously
      context.router.navigate(const AgendaRoute());
    },
    'S4': (context) async {
      // Navigate to the Priorities (focus list) tab — shows Inbox, FYI,
      // Everything, then the six focuses. Single-panel only (desktop uses the
      // sidebar squircle instead).
      // ignore: use_build_context_synchronously
      context.router.replaceAll([const PrioritiesRoute()]);
    },
    'S5': (context) async {
      // Open the New Thread compose. PrioritiesShell.openNewThread drives the
      // Activity-tab inner stack so it lands on the compose page in BOTH
      // single-panel (phone: New is a tab, not a nested child) and multi-panel.
      // The people-picker field is pre-seeded with "Po" (Scenes._pickerQuery)
      // via the hook in NewThreadPageState.initState so it filters to Posy.
      final focusId = await _priorityIdByTitle("Launch women's team");
      if (focusId == null) throw StateError('S5: focus not found');
      // ignore: use_build_context_synchronously
      PrioritiesShell.openNewThread(context, focusId);
    },
    'S6': (context) async {
      // Navigate to the Search tab. The search field and results are pre-seeded
      // with "Chelsea" via the hook in _SearchViewState.initState.
      // ignore: use_build_context_synchronously
      context.router.navigate(const SearchRoute());
    },
    'S7': (context) async {
      // Open the Plot AI thread "Revenue model assumptions" (women's team focus).
      final row = await (Store.get.select(Store.get.threads)
            ..where((t) => t.title.equals('Revenue model assumptions'))
            ..where((t) => t.archivedAt.isNull())
            ..limit(1))
          .getSingleOrNull();
      if (row == null) throw StateError('S7: thread not found');
      // ignore: use_build_context_synchronously
      PrioritiesShell.openThread(context,
          row.priorityId.toShortString(), row.id.toShortString());
    },
    'S8': (context) async {
      // Open onboarding directly at the "Connect your tools" step — the
      // sectioned Messaging / Calendars / Apps connector grid plus the user's
      // existing connections. The OnboardingBloc provider (app.dart) sits above
      // the navigator, so the navigator context can read it.
      //
      // RootProvider fires `OnboardingBloc.start()` concurrently with the scene
      // runner; for a returning user (margot) it emits OnboardingCompleted.
      // Wait for that single emission to land before we override the step so it
      // can't clobber the screenshot state.
      final bloc = context.read<OnboardingBloc>();
      for (var i = 0; i < 30; i++) {
        if (bloc.state is! OnboardingLoading) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      bloc.showStepForScreenshot('Connect your tools');
    },
    'S11': (context) async {
      // Open the ⌘K command palette over the multi-panel — the exact Commands
      // the keyK shortcut shows (command/base.dart). The CommandRegistry is an
      // inherited widget scoped BELOW the navigator, so resolve it from the
      // focused widget's context (deep in the command scope), not the root.
      // Unawaited so the modal stays open while SCENE_READY prints.
      final scoped = FocusManager.instance.primaryFocus?.context ?? context;
      if (!scoped.mounted) return;
      // ignore: use_build_context_synchronously
      unawaited(Commands(groups: CommandRegistry.of(scoped).commands)
          .show(scoped, showFilter: true));
    },
  };

  static Future<BuildContext?> _awaitContext() async {
    for (var i = 0; i < 120; i++) {
      final c = navigatorKey?.currentContext;
      if (c != null && c.mounted) return c;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  /// On touch devices, dismiss the on-screen keyboard before capture so it
  /// can never overlay the UI. A scene that focuses an input (e.g. S2's reply
  /// composer, S6's search field) otherwise raises the soft keyboard on
  /// Android; iOS uses the simulator's hardware keyboard so nothing shows, but
  /// we dismiss there too for parity. The field stays populated — only the
  /// keyboard is hidden — then we settle a few frames for the dismissal to
  /// paint. No-op on desktop/web (no soft keyboard).
  static Future<void> _hideKeyboard() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } catch (e) {
      _log.warning('keyboard hide failed', e);
    }
    await _settle();
  }

  /// Wait for layout + paint to settle after navigation. Generous, because some
  /// destinations (e.g. the multi-panel NewThreadPage, or a thread's notes)
  /// load asynchronously and must finish before we signal readiness/capture.
  static Future<void> _settle() async {
    for (var i = 0; i < 10; i++) {
      await WidgetsBinding.instance.endOfFrame;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1500));
  }
}
