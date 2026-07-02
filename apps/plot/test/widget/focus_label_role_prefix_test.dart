import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/widget.dart';

/// [FocusLabel] prepends a `[Role] ›` crumb only when the focus opts in
/// (`showRole: true`) AND the user has more than one role. The search/filter
/// "global view" sidebar relies on this to keep each role's "Inbox" focus
/// distinguishable once the role accordion is flattened into a single list
/// ([PriorityWidget] forwards `showRole: true` there).
void main() {
  Widget host(Widget child) {
    final scheme = ColourSchemeData(
      themeColor: const ThemeColor.defaultColor(),
      brightness: Brightness.light,
    );
    return Provider<ColourSchemeData>.value(
      value: scheme,
      child: Builder(
        builder: (context) => FTheme(
          data: buildTheme(context, scheme),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 280, child: child),
            ),
          ),
        ),
      ),
    );
  }

  Role role(String name, {ThemeColor color = const ThemeColor.defaultColor()}) =>
      Role.fromRow(
        RoleRow(
          id: Uuid.generate(),
          createdBy: Uuid.generate(),
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          name: name,
          color: color,
        ),
      );

  // A per-role Inbox focus: `is_inbox`, owned by [roleId]. Its
  // [Priority.displayTitle] is the fixed "Inbox", so two of these are
  // indistinguishable without their role prefix. [everything] is true for the
  // Personal role's Inbox, which is that role's root focus (stored title
  // "Everything", displayed "Inbox"); false for every other role's Inbox.
  Priority inboxFocus(RoleId roleId, {bool everything = false, String? title}) {
    final row = PriorityRow(
      id: Uuid.generate(),
      createdBy: Uuid.generate(),
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      title: title ?? (everything ? 'Everything' : 'Inbox'),
      path: Path('inbox'),
      order: const Order(0),
      unread: false,
      role: 'member',
      roleId: roleId,
      isInbox: true,
      isFyi: false,
      attentionWindowSet: false,
      seeWithinSet: false,
      earlyNotificationsEnabledSet: false,
      notifyWindowSet: false,
      sendWindowSet: false,
    );
    return Priority.fromStore(row, draft: true);
  }

  tearDown(Role.clearCache);

  testWidgets('shows the role prefix with 2+ roles when showRole is true', (
    tester,
  ) async {
    final work = role('Work');
    final personal = role('Personal');
    Role.setCacheForTesting([work, personal]);

    await tester.pumpWidget(
      host(FocusLabel(priority: inboxFocus(work.id), showRole: true)),
    );

    expect(find.textContaining('Work'), findsOneWidget);
    expect(find.textContaining('Inbox'), findsOneWidget);
  });

  testWidgets(
    "shows the role prefix for a role's root Inbox (the Personal Inbox)",
    (tester) async {
      // The Personal role's Inbox is that role's root focus (`root == true`).
      // It must still get its `[Role] ›` prefix so it is distinguishable from
      // every other role's "Inbox" — the `!root` guard used to suppress it.
      final personal = role('Personal');
      final work = role('Work');
      Role.setCacheForTesting([personal, work]);

      await tester.pumpWidget(
        host(
          FocusLabel(
            priority: inboxFocus(personal.id, everything: true),
            showRole: true,
          ),
        ),
      );

      expect(find.textContaining('Personal'), findsOneWidget);
      expect(find.textContaining('Inbox'), findsOneWidget);
    },
  );

  testWidgets('omits the role prefix when showRole is false', (tester) async {
    final work = role('Work');
    final personal = role('Personal');
    Role.setCacheForTesting([work, personal]);

    await tester.pumpWidget(
      host(FocusLabel(priority: inboxFocus(work.id), showRole: false)),
    );

    // The plain title renders, with no role crumb.
    expect(find.text('Inbox'), findsOneWidget);
    expect(find.textContaining('Work'), findsNothing);
  });

  testWidgets('omits the role prefix when the user has a single role', (
    tester,
  ) async {
    final work = role('Work');
    Role.setCacheForTesting([work]);

    await tester.pumpWidget(
      host(FocusLabel(priority: inboxFocus(work.id), showRole: true)),
    );

    expect(find.text('Inbox'), findsOneWidget);
    expect(find.textContaining('Work'), findsNothing);
  });

  // Colour: a role's Inbox always follows its role's colour, even when the
  // Inbox's own `color` is NULL so [Priority.displayColor] would fall back to
  // the brand default. The server keeps an Inbox's colour synced to its role,
  // but a freshly-flagged Inbox — notably the Personal role's root Inbox,
  // stored as "Everything" with no explicit colour — can still be NULL. The
  // label resolves the role's colour from the warm cache instead.

  group('Inbox colour follows the role', () {
    // The same scheme [host] builds, so we can compute the expected colours.
    final scheme = ColourSchemeData(
      themeColor: const ThemeColor.defaultColor(),
      brightness: Brightness.light,
    );
    final roleColour = scheme.colours.fromTheme(const ThemeColor(3));
    final brandDefault = scheme.colours.fromTheme(
      const ThemeColor.defaultColor(),
    );

    test('Priority.labelDisplayColor resolves an Inbox to its role colour', () {
      final personal = role('Personal', color: const ThemeColor(3));
      Role.setCacheForTesting([personal]);

      final inbox = inboxFocus(personal.id, everything: true);
      // The stored Inbox has no `color`, so its raw displayColor is the brand
      // default, but the role-aware label colour is the role's.
      expect(inbox.displayColor, const ThemeColor.defaultColor());
      expect(inbox.labelDisplayColor, const ThemeColor(3));
    });

    test('an ordinary focus keeps its own displayColor', () {
      final personal = role('Personal', color: const ThemeColor(3));
      Role.setCacheForTesting([personal]);

      // A non-inbox focus is unaffected — its label colour is its displayColor.
      final ordinary = inboxFocus(personal.id, title: 'Marketing')
          .copyWith(isInbox: false);
      expect(ordinary.labelDisplayColor, ordinary.displayColor);
    });

    test('falls back to displayColor when the role is not cached', () {
      final personal = role('Personal', color: const ThemeColor(3));
      // Cache intentionally NOT seeded with [personal].
      Role.setCacheForTesting([]);

      final inbox = inboxFocus(personal.id, everything: true);
      expect(inbox.labelDisplayColor, inbox.displayColor);
    });

    testWidgets("colours a role's Inbox icon in the role's colour", (
      tester,
    ) async {
      final personal = role('Personal', color: const ThemeColor(3));
      Role.setCacheForTesting([personal]);

      await tester.pumpWidget(
        host(
          FocusLabel(
            priority: inboxFocus(personal.id, everything: true),
            showRole: false,
          ),
        ),
      );

      final icon = tester.widget<Icon>(find.byIcon(PlotIcon.inbox));
      expect(icon.color, roleColour);
      expect(icon.color, isNot(brandDefault));
    });

    testWidgets(
      "colours a role's Inbox in the role's colour with the role prefix",
      (tester) async {
        final personal = role('Personal', color: const ThemeColor(3));
        final work = role('Work');
        Role.setCacheForTesting([personal, work]);

        // Two roles + showRole:true → the focus-switch modal path (prefix).
        await tester.pumpWidget(
          host(
            FocusLabel(
              priority: inboxFocus(personal.id, everything: true),
              showRole: true,
            ),
          ),
        );

        final icon = tester.widget<Icon>(find.byIcon(PlotIcon.inbox));
        expect(icon.color, roleColour);
        expect(icon.color, isNot(brandDefault));
      },
    );
  });

  // The focus-switcher / move / merge pickers render their entries from
  // [PriorityCommand]s. The root Inbox must NOT be passed a branded
  // `label: 'Inbox'` (which would force the brand colour + drop the role
  // prefix); it renders as the ordinary role focus it is.

  test('the Inbox command title is "Inbox" without a branded label', () {
    final personal = role('Personal');
    // Stored title is "Everything"; the command must still surface as "Inbox"
    // (via displayTitle) so typing "inbox" finds it.
    final rootInbox = inboxFocus(personal.id, everything: true);
    expect(ChangeCurrentPriority(rootInbox).title, 'Inbox');
  });

  testWidgets('the Inbox command body shows the role prefix (not branded)', (
    tester,
  ) async {
    final personal = role('Personal');
    final work = role('Work');
    Role.setCacheForTesting([personal, work]);

    final rootInbox = inboxFocus(personal.id, everything: true);
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) =>
              ChangeCurrentPriority(rootInbox).buildBody(context) ??
              const SizedBox.shrink(),
        ),
      ),
    );

    // Prefixed + branded as "Inbox" (never the stored "Everything").
    expect(find.textContaining('Personal'), findsOneWidget);
    expect(find.textContaining('Inbox'), findsOneWidget);
    expect(find.textContaining('Everything'), findsNothing);
  });
}
