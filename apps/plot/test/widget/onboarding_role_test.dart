import 'package:flutter/material.dart' show MaterialApp, Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/widget/onboarding/onboarding_progress.dart';
import 'package:plot/widget/onboarding/onboarding_role.dart';
import 'package:plot/widget/onboarding/onboarding_step_scope.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('RoleOption', () {
    test('has five options, Project replaces Volunteering', () {
      expect(RoleOption.values, hasLength(5));
      expect(RoleOption.values.map((o) => o.label), [
        'Work',
        'Project',
        'Personal',
        'School',
        'Other',
      ]);
    });

    test('Project metadata', () {
      expect(RoleOption.project.prompt, 'What is the project?');
      expect(RoleOption.project.placeholder, 'Website redesign');
      expect(RoleOption.project.icon, FontAwesomeIcons.rocket);
      expect(RoleOption.project.roleName('Atlas migration'), 'Atlas migration');
      expect(RoleOption.project.roleName('   '), 'Project'); // blank → label
    });

    test('prompted vs unprompted options', () {
      // Work/Project/Other ask a follow-up question; Personal/School do not.
      expect(RoleOption.work.prompt, 'Where do you work?');
      expect(RoleOption.other.prompt, 'What should we call this role?');
      expect(RoleOption.personal.prompt, isNull);
      expect(RoleOption.school.prompt, isNull);
      // Unprompted options name themselves from the label alone.
      expect(RoleOption.personal.roleName(''), 'Personal');
      expect(RoleOption.school.roleName(''), 'School');
    });

    test('every option has an icon', () {
      for (final option in RoleOption.values) {
        expect(option.icon, isA<IconData>());
      }
    });
  });

  group('OnboardingRoleSelection defaults', () {
    test('defaults to Work', () {
      // The picker pre-selects Work so a new user starts in their work role.
      expect(OnboardingRoleSelection().option, RoleOption.work);
    });
  });

  group('OnboardingRoleContent (picker)', () {
    testWidgets('renders all five labelled, icon-bearing tiles', (tester) async {
      await tester.pumpWidget(
        _host(OnboardingRoleContent(selection: OnboardingRoleSelection())),
      );

      for (final option in RoleOption.values) {
        expect(find.text(option.label), findsOneWidget);
        expect(find.byIcon(option.icon), findsOneWidget);
      }
      expect(find.text('Volunteering'), findsNothing);
    });

    testWidgets('tapping an option updates the selection and clears text', (
      tester,
    ) async {
      final selection = OnboardingRoleSelection()..text = 'stale';
      await tester.pumpWidget(_host(OnboardingRoleContent(selection: selection)));

      await tester.tap(find.text('Project'));
      await tester.pump();

      expect(selection.option, RoleOption.project);
      // Switching options drops any answer carried over from a prior option.
      expect(selection.text, isEmpty);
    });

    testWidgets('tapping an option advances via the step scope', (tester) async {
      var advanced = 0;
      final selection = OnboardingRoleSelection();
      await tester.pumpWidget(
        _host(
          OnboardingStepScope(
            advance: () async {
              advanced++;
            },
            child: OnboardingRoleContent(selection: selection),
          ),
        ),
      );

      await tester.tap(find.text('Work'));
      await tester.pump();

      expect(selection.option, RoleOption.work);
      expect(advanced, 1); // advanced immediately, no separate Next tap
    });
  });

  group('OnboardingRolePromptContent (follow-up field)', () {
    testWidgets('shows the option placeholder and autofocuses', (tester) async {
      final selection = OnboardingRoleSelection()..option = RoleOption.work;
      await tester.pumpWidget(
        _host(OnboardingRolePromptContent(selection: selection)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Acme Co'), findsOneWidget); // placeholder hint
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue); // autofocused on mount
    });

    testWidgets('typed text is written back to the selection', (tester) async {
      final selection = OnboardingRoleSelection()..option = RoleOption.project;
      await tester.pumpWidget(
        _host(OnboardingRolePromptContent(selection: selection)),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(EditableText), 'Website redesign');
      await tester.pump();

      expect(selection.text, 'Website redesign');
    });

    testWidgets('claims focus even when another field already owns the '
        'shared scope (composer-behind-overlay)', (tester) async {
      // Reproduces the live bug: the new-thread composer behind the onboarding
      // overlay already holds focus in the shared FocusScope, so the follow-up
      // field's passive `autofocus` would be ignored (FocusScopeNode.autofocus
      // is a no-op when the scope already has a focused child).
      final competitor = FocusNode(debugLabel: 'composer');
      final selection = OnboardingRoleSelection()..option = RoleOption.work;

      // 1. Composer grabs focus first.
      await tester.pumpWidget(
        _host(
          Focus(
            focusNode: competitor,
            autofocus: true,
            child: const SizedBox(width: 1, height: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(competitor.hasFocus, isTrue);

      // 2. The follow-up step appears while the composer still owns the scope.
      await tester.pumpWidget(
        _host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Focus(
                focusNode: competitor,
                child: const SizedBox(width: 1, height: 1),
              ),
              OnboardingRolePromptContent(selection: selection),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(
        field.focusNode.hasFocus,
        isTrue,
        reason: 'follow-up field must take focus from the composer behind it',
      );
    });

    testWidgets('seeds the field from any existing selection text', (
      tester,
    ) async {
      final selection = OnboardingRoleSelection()
        ..option = RoleOption.other
        ..text = 'Superhero';
      await tester.pumpWidget(
        _host(OnboardingRolePromptContent(selection: selection)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Superhero'), findsOneWidget);
    });

    testWidgets('Enter submits via the step scope', (tester) async {
      var advanced = 0;
      final selection = OnboardingRoleSelection()..option = RoleOption.work;
      await tester.pumpWidget(
        _host(
          OnboardingStepScope(
            advance: () async {
              advanced++;
            },
            child: OnboardingRolePromptContent(selection: selection),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(EditableText), 'Acme Co');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(advanced, 1);
    });
  });

  group('OnboardingRoleSelection.text', () {
    test('textListenable fires on change; whitespace is not a valid name', () {
      final selection = OnboardingRoleSelection();
      var fired = 0;
      selection.textListenable.addListener(() => fired++);

      selection.text = 'Acme';
      expect(fired, 1);
      expect(selection.text.trim().isNotEmpty, isTrue);

      selection.text = '   ';
      expect(fired, 2);
      expect(selection.text.trim().isNotEmpty, isFalse);
    });
  });

  group('OnboardingProgress Next enablement', () {
    testWidgets('a null onNext renders Next disabled (no tap-through)', (
      tester,
    ) async {
      var nexts = 0;
      await tester.pumpWidget(
        _host(
          OnboardingProgress(
            currentStep: 1,
            totalSteps: 4,
            onNext: null,
            onBack: () {},
          ),
        ),
      );

      // The label still renders, but the button is non-interactive.
      expect(find.text('Next'), findsOneWidget);
      await tester.tap(find.text('Next'), warnIfMissed: false);
      await tester.pump();
      expect(nexts, 0);
    });

    testWidgets('a non-null onNext fires on tap', (tester) async {
      var nexts = 0;
      await tester.pumpWidget(
        _host(
          OnboardingProgress(
            currentStep: 1,
            totalSteps: 4,
            onNext: () => nexts++,
            onBack: () {},
          ),
        ),
      );

      await tester.tap(find.text('Next'));
      await tester.pump();
      expect(nexts, 1);
    });
  });
}
