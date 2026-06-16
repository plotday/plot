import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:plot/main.dart' show navigatorKey;
import 'package:plot/command/base.dart';
import 'package:plot/command/provider.dart';
import 'package:plot/command/twist.dart';
import 'package:plot/router.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/priorities_shell.dart';
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
        await windowManager.setSize(const Size(1440, 900));
        await windowManager.setAlignment(Alignment.center);
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
      // Open the Connections manager (Gmail, Calendar, Slack, Teams, Notion, …
      // tiles, some Connected). Two requirements, learned the hard way:
      //  1. SelectModal needs a context UNDER ModalProvider — the root navigator
      //     context is above it, so use the focused widget's context (the
      //     default new-thread picker field sits under the provider).
      //  2. SelectModal.open pre-fetches its items and bails if that context
      //     unmounts during the await — prewarm so the pre-fetch is instant.
      await ManageConnections.prewarm();
      final scoped = FocusManager.instance.primaryFocus?.context;
      if (scoped == null || !scoped.mounted) return;
      // Fire-and-forget so the modal stays open while SCENE_READY prints.
      unawaited(ManageConnections(keepCache: true).run(scoped));
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
