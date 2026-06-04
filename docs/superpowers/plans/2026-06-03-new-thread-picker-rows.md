# New-thread Picker Rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reformat the step-1 new-thread target rows into two-line rows (focus-tinted connection header + people/channel/focus content), drop the Note/Chat distinction in favour of focus-notes + people + twists, accept multi-recipient / `Name <email>` input that creates named contacts, and surface emails only to disambiguate identically-named people.

**Architecture:** The `ComposeTargetsBloc` stays the source of truth. It keeps producing `ComposeTarget`s (the selection/MRU model) but now resolves each into a new presentation model, `ComposeTargetView` (header text + tint + per-recipient display with "show email" flags + focus priority). All connection-wide work (focus-colour tally, recipient disambiguation, actor pre-loading) happens once during the cached `_ComposeSearchContext` build, so opening and per-keystroke search add no new queries. The row widget renders views and stays dumb. A one-line server change lets `inviteEmails` of the form `"Name <email>"` create named contacts.

**Tech Stack:** Flutter/Dart (forui, flutter_bloc, drift), Cloudflare Workers (TypeScript, Hono), Postgres (Atlas; no schema change here).

**Spec:** `docs/superpowers/specs/2026-06-03-new-thread-picker-rows-design.md`

**Conventions for every task below:**
- Flutter analyze: `cd apps/plot && flutter analyze <changed files>` (info-level OK; the CI gate is `--no-fatal-infos`). Run the **full** app analyze for any change to a non-nullable model constructor (none here, but the rule stands).
- Flutter unit tests: `cd apps/plot && flutter test test/<path>`. A worktree needs `flutter pub get` + `dart run build_runner build --delete-conflicting-outputs` + the `app.env` asset copied from main before tests run (see project worktree notes).
- Worker tests: `cd workers/api && timeout 120 pnpm test -- <file>` (unit config; integration pool wedges the shell, so always `timeout`).
- Dart-only commits in a Flutter-only worktree need `git commit --no-verify` (husky `husky.sh` is absent without `pnpm install`). Commit only the listed paths: `git commit -- <paths>`.
- Never use `flutter/material.dart` in app code — only `flutter/widgets.dart` + `forui/forui.dart` (the existing `OutlineInputBorder` `show`-import in `target_picker_list.dart` is the sanctioned exception).

---

## File map

**Create**
- `apps/plot/lib/widget/compose/compose_target_view.dart` — `ComposeTargetView`, `RecipientDisplay`, the `connectionColorKey` helper, and the pure disambiguation helper.
- `apps/plot/test/widget/compose/email_parser_test.dart` — parser/encoder unit tests.
- `apps/plot/test/widget/compose/compose_target_view_test.dart` — disambiguation helper unit tests.

**Modify**
- `apps/plot/lib/widget/compose/email_parser.dart` — multi-recipient parsing + `Name <email>` + `InviteAddress`.
- `apps/plot/lib/widget/compose/compose_target.dart` — add `priorityId`; drop the dedicated Note/Chat labels' reliance on the old single-line label where needed (label stays for search/dedup).
- `apps/plot/lib/state/compose_targets.dart` — `ComposeScanThread.priorityId`; context-build tally/colour-map/actor-preload/disambiguation; focus-note + twist targets; `_toViews`; multi-recipient search.
- `apps/plot/lib/state/compose_targets_state.dart` — `targets` becomes `List<ComposeTargetView>`.
- `apps/plot/lib/widget/compose/target_picker_list.dart` — two-line row widget, focus tint, AvatarGroup + names / channel / FocusLabel / twist, hover tooltip, item-height/scroll update; `_results` becomes `List<ComposeTargetView>`.
- `apps/plot/lib/page/new_thread.dart` — focus pre-select in `_suggestFocusForTarget`; `onSelect` unwraps `view.target`.
- `apps/plot/lib/widget/compose/contacts_compose_field.dart` — `ContactChipEmail` parses `Name <email>` for its label.
- `workers/api/src/app/sync/threads.ts` — parse `Name <email>` before `upsert_contacts`.
- `apps/plot/test/state/compose_targets_test.dart` — bloc-level tests for focus-note targets + multi-recipient search.
- `workers/api/src/app/sync/threads.test.ts` (or nearest existing unit test file for this module) — invite-name parse test.
- `docs/updates.md`, `docs/features.md` — finalize.

---

## Phase A — Pure model & parsing (DB-free, full TDD)

### Task 1: Multi-recipient email parser

**Files:**
- Modify: `apps/plot/lib/widget/compose/email_parser.dart`
- Test: `apps/plot/test/widget/compose/email_parser_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// apps/plot/test/widget/compose/email_parser_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/compose/email_parser.dart';

void main() {
  group('EmailParser.parseRecipients', () {
    test('single bare email', () {
      final r = EmailParser.parseRecipients('kris@plot.day');
      expect(r, hasLength(1));
      expect(r.single.email, 'kris@plot.day');
      expect(r.single.name, isNull);
    });

    test('comma / semicolon / space separated', () {
      for (final input in [
        'a@x.com, b@y.com',
        'a@x.com; b@y.com',
        'a@x.com b@y.com',
        ' a@x.com ,;  b@y.com ',
      ]) {
        final r = EmailParser.parseRecipients(input);
        expect(r.map((e) => e.email), ['a@x.com', 'b@y.com'], reason: input);
        expect(r.every((e) => e.name == null), isTrue, reason: input);
      }
    });

    test('Name <email> form captures the name', () {
      final r = EmailParser.parseRecipients('Kris Braun <kris@plot.day>');
      expect(r.single.email, 'kris@plot.day');
      expect(r.single.name, 'Kris Braun');
    });

    test('quoted name is unquoted', () {
      final r = EmailParser.parseRecipients('"Braun, Kris" <kris@plot.day>');
      expect(r.single.name, 'Braun, Kris');
      expect(r.single.email, 'kris@plot.day');
    });

    test('mixed named and bare, multiple separators', () {
      final r = EmailParser.parseRecipients(
        'Kris Braun <kris@plot.day>, dana@acme.co; sam@x.io',
      );
      expect(r.map((e) => e.email), ['kris@plot.day', 'dana@acme.co', 'sam@x.io']);
      expect(r[0].name, 'Kris Braun');
      expect(r[1].name, isNull);
      expect(r[2].name, isNull);
    });

    test('non-email junk yields no recipients', () {
      expect(EmailParser.parseRecipients('Kris Braun'), isEmpty);
      expect(EmailParser.parseRecipients('hello world'), isEmpty);
      expect(EmailParser.parseRecipients(''), isEmpty);
    });

    test('isEmailQuery true only when at least one email parses', () {
      expect(EmailParser.isEmailQuery('a@x.com b@y.com'), isTrue);
      expect(EmailParser.isEmailQuery('Greg'), isFalse);
    });

    test('emails are lower-cased and trimmed', () {
      final r = EmailParser.parseRecipients('KRIS@Plot.Day');
      expect(r.single.email, 'kris@plot.day');
    });
  });
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd apps/plot && flutter test test/widget/compose/email_parser_test.dart`
Expected: FAIL (`parseRecipients`/`isEmailQuery`/`ParsedRecipient` undefined).

- [ ] **Step 3: Implement the parser**

Replace the body of `apps/plot/lib/widget/compose/email_parser.dart` with:

```dart
/// One parsed recipient from a compose query: a normalized email plus an
/// optional display name captured from the `Name <email>` form.
class ParsedRecipient {
  const ParsedRecipient({required this.email, this.name});
  final String email;
  final String? name;
}

/// Lenient email parsing for compose-field input. Not for validating
/// mail-routable addresses — bad addresses surface as bounces server-side.
class EmailParser {
  static final RegExp _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  // "Display Name <email>"; name group is non-greedy, email is inside <>.
  static final RegExp _named = RegExp(r'^(.*)<([^>]+)>$');
  // Top-level separators between recipients: comma or semicolon.
  static final RegExp _segment = RegExp(r'[,;]');
  static final RegExp _whitespace = RegExp(r'\s+');

  /// True iff [value] (after trimming) is a single address.
  static bool isEmail(String value) => _email.hasMatch(value.trim());

  /// True iff [value] parses to at least one recipient (email mode).
  static bool isEmailQuery(String value) => parseRecipients(value).isNotEmpty;

  /// Trimmed form of [value]. Retained for callers that still want it.
  static String normalize(String value) => value.trim();

  /// Parse [input] into recipients. Splits on commas/semicolons; each segment
  /// is either a `Name <email>` form or one-or-more whitespace-separated bare
  /// emails. Non-email tokens are dropped. Returns [] when nothing parses
  /// (the caller then treats the query as a name search).
  static List<ParsedRecipient> parseRecipients(String input) {
    final out = <ParsedRecipient>[];
    for (final rawSegment in input.split(_segment)) {
      final segment = rawSegment.trim();
      if (segment.isEmpty) continue;
      final named = _named.firstMatch(segment);
      if (named != null) {
        final email = named.group(2)!.trim();
        if (!_email.hasMatch(email)) continue;
        final name = _unquote(named.group(1)!.trim());
        out.add(ParsedRecipient(
          email: email.toLowerCase(),
          name: name.isEmpty ? null : name,
        ));
        continue;
      }
      for (final token in segment.split(_whitespace)) {
        final t = token.trim();
        if (_email.hasMatch(t)) {
          out.add(ParsedRecipient(email: t.toLowerCase()));
        }
      }
    }
    return out;
  }

  static String _unquote(String s) {
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      return s.substring(1, s.length - 1).trim();
    }
    return s;
  }
}
```

- [ ] **Step 4: Run, verify it passes**

Run: `cd apps/plot && flutter test test/widget/compose/email_parser_test.dart`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git commit --no-verify -- apps/plot/lib/widget/compose/email_parser.dart apps/plot/test/widget/compose/email_parser_test.dart -m "feat(compose): multi-recipient + Name<email> email parsing"
```

---

### Task 2: `InviteAddress` encode/parse for named invites

`inviteEmails` stays `List<String>`; a named invite is encoded as `"Name <email>"`, a nameless one as the bare email. This avoids any Drift migration or sync wire-format change.

**Files:**
- Modify: `apps/plot/lib/widget/compose/email_parser.dart`
- Test: `apps/plot/test/widget/compose/email_parser_test.dart`

- [ ] **Step 1: Add failing tests** (append to the existing test file)

```dart
  group('InviteAddress', () {
    test('format with name', () {
      expect(InviteAddress.format(email: 'k@x.com', name: 'Kris Braun'),
          'Kris Braun <k@x.com>');
    });
    test('format without name is bare', () {
      expect(InviteAddress.format(email: 'k@x.com', name: null), 'k@x.com');
      expect(InviteAddress.format(email: 'k@x.com', name: ''), 'k@x.com');
    });
    test('parse named', () {
      final a = InviteAddress.parse('Kris Braun <k@x.com>');
      expect(a.email, 'k@x.com');
      expect(a.name, 'Kris Braun');
    });
    test('parse bare', () {
      final a = InviteAddress.parse('k@x.com');
      expect(a.email, 'k@x.com');
      expect(a.name, isNull);
    });
    test('round-trips', () {
      for (final s in ['k@x.com', 'Kris Braun <k@x.com>']) {
        final a = InviteAddress.parse(s);
        expect(InviteAddress.format(email: a.email, name: a.name), s);
      }
    });
  });
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd apps/plot && flutter test test/widget/compose/email_parser_test.dart`
Expected: FAIL (`InviteAddress` undefined).

- [ ] **Step 3: Implement** (append to `email_parser.dart`)

```dart
/// Wire encoding for a pending email invitation that optionally carries a
/// display name. Encoded as RFC-style `"Name <email>"` (or the bare email when
/// nameless) inside the existing `inviteEmails` string list — so no schema or
/// sync change is needed. The server parses the same form before
/// `upsert_contacts` to create a *named* contact.
class InviteAddress {
  const InviteAddress({required this.email, this.name});
  final String email;
  final String? name;

  static String format({required String email, String? name}) =>
      (name != null && name.trim().isNotEmpty)
          ? '${name.trim()} <$email>'
          : email;

  static InviteAddress parse(String encoded) {
    final r = EmailParser.parseRecipients(encoded);
    if (r.isNotEmpty) return InviteAddress(email: r.first.email, name: r.first.name);
    return InviteAddress(email: encoded.trim());
  }
}
```

- [ ] **Step 4: Run, verify it passes**

Run: `cd apps/plot && flutter test test/widget/compose/email_parser_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit --no-verify -- apps/plot/lib/widget/compose/email_parser.dart apps/plot/test/widget/compose/email_parser_test.dart -m "feat(compose): InviteAddress Name<email> encode/parse"
```

---

### Task 3: `ComposeTarget.priorityId` (focus-note carries its focus)

**Files:**
- Modify: `apps/plot/lib/widget/compose/compose_target.dart`

- [ ] **Step 1: Add the field + a focus-note constructor**

In `compose_target.dart`, add to the private constructor params and fields:

```dart
  const ComposeTarget._({
    required this.kind,
    required this.signature,
    required this.label,
    this.connection,
    this.target,
    this.linkType,
    this.channel,
    this.teamId,
    this.contacts = const [],
    this.groups = const [],
    this.inviteEmails = const [],
    this.priorityId, // NEW
  });
```

```dart
  /// For a focus-note target, the focus this note is filed into; null for all
  /// other kinds. Carried into step-2 so the focus is pre-selected.
  final Uuid? priorityId;
```

Add a named constructor for a focus-note (reuses the `note` kind + note signature, **scoped per focus**):

```dart
  /// A Plot focus-note target: a private note pre-filed into [priorityId].
  /// Uses the [ComposeTargetKind.note] kind; the signature is widened with the
  /// focus id so distinct focuses rank as distinct rows. [teamId] is the focus's
  /// most-common Plot scope (null = Personal).
  factory ComposeTarget.focusNote({
    required Uuid priorityId,
    required BigInt? teamId,
  }) {
    return ComposeTarget._(
      kind: ComposeTargetKind.note,
      signature: 'note:${teamId?.toString() ?? 'personal'}:p=$priorityId',
      label: 'Note', // presentation comes from the view; label kept for dedup
      teamId: teamId,
      priorityId: priorityId,
    );
  }
```

Add `priorityId` to `props`:

```dart
  @override
  List<Object?> get props => [
        kind, signature, label, connection?.id, linkType?.type, channel?.id,
        teamId, contacts, groups, inviteEmails, priorityId,
      ];
```

- [ ] **Step 2: Verify it compiles**

Run: `cd apps/plot && flutter analyze lib/widget/compose/compose_target.dart`
Expected: No errors (info-level OK).

- [ ] **Step 3: Commit**

```bash
git commit --no-verify -- apps/plot/lib/widget/compose/compose_target.dart -m "feat(compose): ComposeTarget.priorityId + focusNote constructor"
```

---

### Task 4: `ContactChipEmail` shows the invite name

**Files:**
- Modify: `apps/plot/lib/widget/compose/contacts_compose_field.dart:40-48`

- [ ] **Step 1: Update the chip label to parse `Name <email>`**

Replace the `ContactChipEmail` class body so `label` shows the name when present:

```dart
/// A chip backed by a raw email invitation (not yet a known contact). The
/// stored string may be `"Name <email>"` (named invite) or a bare email.
class ContactChipEmail implements ContactChipValue {
  ContactChipEmail(this.encoded) : _parsed = InviteAddress.parse(encoded);
  final String encoded;
  final InviteAddress _parsed;
  String get email => _parsed.email;
  String? get name => _parsed.name;
  @override
  String get key => 'email:${_parsed.email}';
  @override
  String get label => _parsed.name ?? _parsed.email;
}
```

Add the import at the top of the file:

```dart
import 'package:plot/widget/compose/email_parser.dart';
```

Update the call site in `apps/plot/lib/page/new_thread.dart:_resolveContactChips` (the `for (final email in draft.inviteEmails) chips.add(ContactChipEmail(email));` loop): no change needed — it already passes the stored string, which `ContactChipEmail` now parses.

- [ ] **Step 2: Verify it compiles**

Run: `cd apps/plot && flutter analyze lib/widget/compose/contacts_compose_field.dart lib/page/new_thread.dart`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git commit --no-verify -- apps/plot/lib/widget/compose/contacts_compose_field.dart -m "feat(compose): show invite display name on email chips"
```

---

## Phase B — Presentation model + bloc

### Task 5: `ComposeTargetView`, `RecipientDisplay`, and the pure disambiguation helper

**Files:**
- Create: `apps/plot/lib/widget/compose/compose_target_view.dart`
- Test: `apps/plot/test/widget/compose/compose_target_view_test.dart`

- [ ] **Step 1: Write the failing test for the disambiguation helper**

```dart
// apps/plot/test/widget/compose/compose_target_view_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/compose/compose_target_view.dart';

void main() {
  group('resolveRecipientDisplays', () {
    // nameToEmails: per-connection name -> addresses ordered primary-first.
    test('single address for a name -> bare, no email shown', () {
      final out = resolveRecipientDisplays(
        recipients: const [(name: 'Kris Braun', email: 'kris@plot.day', actorId: null)],
        nameToEmailsForConnection: const {'kris braun': ['kris@plot.day']},
      );
      expect(out.single.showEmail, isFalse);
    });

    test('primary address bare, secondary shows email', () {
      final byName = {'kris braun': ['kris@plot.day', 'kris@personal.com']};
      final primary = resolveRecipientDisplays(
        recipients: const [(name: 'Kris Braun', email: 'kris@plot.day', actorId: null)],
        nameToEmailsForConnection: byName,
      );
      final secondary = resolveRecipientDisplays(
        recipients: const [(name: 'Kris Braun', email: 'kris@personal.com', actorId: null)],
        nameToEmailsForConnection: byName,
      );
      expect(primary.single.showEmail, isFalse);
      expect(secondary.single.showEmail, isTrue);
    });

    test('name match is case-insensitive', () {
      final out = resolveRecipientDisplays(
        recipients: const [(name: 'KRIS BRAUN', email: 'kris@personal.com', actorId: null)],
        nameToEmailsForConnection: const {
          'kris braun': ['kris@plot.day', 'kris@personal.com']
        },
      );
      expect(out.single.showEmail, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd apps/plot && flutter test test/widget/compose/compose_target_view_test.dart`
Expected: FAIL (undefined `resolveRecipientDisplays` / `compose_target_view.dart`).

- [ ] **Step 3: Implement the view model + helper**

```dart
// apps/plot/lib/widget/compose/compose_target_view.dart
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart' show ActorId, Priority, ThemeColor;
import 'package:plot/widget/compose/compose_target.dart';

/// One recipient as it should appear on a people row.
class RecipientDisplay extends Equatable {
  const RecipientDisplay({
    required this.name,
    required this.email,
    required this.showEmail,
    this.actorId,
  });

  /// Display name (falls back to the email when there is no name).
  final String name;

  /// Full email, for the hover tooltip and the exception-only inline form.
  final String? email;

  /// Append ` <email>` inline (exception-only disambiguation, see spec §8).
  final bool showEmail;

  /// Resolved actor for the avatar; null for a pending invite.
  final ActorId? actorId;

  @override
  List<Object?> get props => [name, email, showEmail, actorId];
}

/// Presentation wrapper around a [ComposeTarget]: everything the row widget
/// needs that requires connection-wide / async context only the bloc has
/// (the focus tint, the disambiguated recipient list, the focus-note's focus).
class ComposeTargetView extends Equatable {
  const ComposeTargetView({
    required this.target,
    required this.header,
    required this.headerColor,
    this.recipients = const [],
    this.focusPriority,
  });

  final ComposeTarget target;

  /// Line-1 connection header text.
  final String header;

  /// Tint for the header (most-common focus for the connection; the focus's
  /// own colour for a focus-note). Resolve with
  /// `context.colour.colours.fromTheme(headerColor, muted: true)`.
  final ThemeColor headerColor;

  /// People rows only: disambiguated recipients (avatars + names + tooltip).
  final List<RecipientDisplay> recipients;

  /// Focus-note rows only: the focus to render via `FocusLabel`.
  final Priority? focusPriority;

  @override
  List<Object?> get props =>
      [target, header, headerColor, recipients, focusPriority?.id];
}

/// Record shape for one recipient before disambiguation.
typedef RecipientInput = ({String name, String? email, ActorId? actorId});

/// Apply the exception-only email rule (spec §8): show the email beside a name
/// only when that name maps to >1 address within the connection, and only on
/// the non-primary address. [nameToEmailsForConnection] is keyed by lowercased
/// name with addresses ordered primary-first.
List<RecipientDisplay> resolveRecipientDisplays({
  required List<RecipientInput> recipients,
  required Map<String, List<String>> nameToEmailsForConnection,
}) {
  return [
    for (final r in recipients)
      RecipientDisplay(
        name: r.name,
        email: r.email,
        actorId: r.actorId,
        showEmail: _isException(r, nameToEmailsForConnection),
      ),
  ];
}

bool _isException(
  RecipientInput r,
  Map<String, List<String>> nameToEmails,
) {
  final email = r.email?.toLowerCase();
  if (email == null) return false;
  final addresses = nameToEmails[r.name.toLowerCase()];
  if (addresses == null || addresses.length < 2) return false;
  // Primary (first / most-used) stays bare; any other address is the exception.
  return addresses.first.toLowerCase() != email;
}
```

> Note: confirm `ThemeColor` and `Priority` are exported from `package:plot/store/store.dart`. `ThemeColor` lives in `lib/util/theme_color.dart`; if it is not re-exported by `store.dart`, import it directly: `import 'package:plot/util/theme_color.dart' show ThemeColor;`.

- [ ] **Step 4: Run, verify it passes**

Run: `cd apps/plot && flutter test test/widget/compose/compose_target_view_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit --no-verify -- apps/plot/lib/widget/compose/compose_target_view.dart apps/plot/test/widget/compose/compose_target_view_test.dart -m "feat(compose): ComposeTargetView + exception-only recipient disambiguation"
```

---

### Task 6: Carry `priorityId` through the authored-thread scan

**Files:**
- Modify: `apps/plot/lib/state/compose_targets.dart` (`ComposeScanThread` ~765-780; `_scanAuthoredThreads` ~539-554)

- [ ] **Step 1: Add `priorityId` to `ComposeScanThread`**

```dart
class ComposeScanThread extends Equatable {
  const ComposeScanThread({
    this.teamId,
    this.contacts = const [],
    this.groups = const [],
    this.primaryLink,
    required this.priorityId, // NEW
  });

  final BigInt? teamId;
  final List<Uuid> contacts;
  final List<Uuid> groups;
  final ComposeScanLink? primaryLink;
  final Uuid priorityId; // NEW: the thread's filed focus (non-null on ThreadRow)

  @override
  List<Object?> get props => [teamId, contacts, groups, primaryLink, priorityId];
}
```

- [ ] **Step 2: Populate it in `_scanAuthoredThreads`**

In the `scanThreads.add(ComposeScanThread(...))` call, add `priorityId: row.priorityId,`.

- [ ] **Step 3: Fix the pure-helper tests that build `ComposeScanThread`**

`composeSignatureForScanThread` / `buildUsedTargetSignatures` tests in `test/state/compose_targets_test.dart` construct `ComposeScanThread(...)`. Add `priorityId: Uuid.generate()` (or a fixed test UUID) to each construction so they still compile. (The signature helpers ignore `priorityId`.)

- [ ] **Step 4: Verify**

Run: `cd apps/plot && flutter analyze lib/state/compose_targets.dart && flutter test test/state/compose_targets_test.dart`
Expected: analyze clean; existing tests PASS.

- [ ] **Step 5: Commit**

```bash
git commit --no-verify -- apps/plot/lib/state/compose_targets.dart apps/plot/test/state/compose_targets_test.dart -m "feat(compose): carry priorityId through authored-thread scan"
```

---

### Task 7: Context-build resolution — focus-colour map, focus objects, roster actors, disambiguation map

This task extends `_ComposeSearchContext` (cached, rebuilt only on `refresh()`/invalidate) so all per-connection resolution happens once.

**Files:**
- Modify: `apps/plot/lib/state/compose_targets.dart` (`_ComposeSearchContext` ~711-740; `_buildSearchContext` ~218-249; add `connectionColorKey` to `compose_target_view.dart`)

- [ ] **Step 1: Add `connectionColorKey` to `compose_target_view.dart`**

```dart
/// The grouping key a target's header tint is computed against (spec §4):
/// connector/twist -> the connection (twist-instance) id; Plot chat -> per
/// scope so a work team's colour stays distinct from personal.
String connectionColorKey(ComposeTarget t) {
  switch (t.kind) {
    case ComposeTargetKind.connector:
    case ComposeTargetKind.twist:
      return 'conn:${t.connection?.id ?? t.target?.twist.id}';
    case ComposeTargetKind.chat:
      return 'plot:${t.teamId?.toString() ?? 'personal'}';
    case ComposeTargetKind.note:
      // Focus-notes tint by their own focus, handled directly in _toView.
      return 'plot:${t.teamId?.toString() ?? 'personal'}';
  }
}
```

- [ ] **Step 2: Extend `_ComposeSearchContext` with resolved maps**

Add fields + constructor params:

```dart
  /// Most-common focus colour per [connectionColorKey] (spec §4).
  final Map<String, ThemeColor> colorByConnection;

  /// Focuses resolved for focus-note rows + colour lookups, by id.
  final Map<Uuid, Priority> priorityById;

  /// Per [connectionColorKey]: lowercased contact name -> addresses
  /// (primary-first) used on that connection (spec §8).
  final Map<String, Map<String, List<String>>> nameToEmailsByConnection;

  /// Focuses to surface as focus-note rows, MRU order, with their most-common
  /// Plot scope. (priorityId, teamId-of-most-common-scope)
  final List<({Uuid priorityId, BigInt? teamId})> focusNoteOrder;
```

- [ ] **Step 3: Compute them in `_buildSearchContext`**

After the existing `scan`/`teams`/`createTargets` are loaded, add resolution. The scan already holds per-thread `priorityId`, `teamId`, `contacts`, and `primaryLink`. Build:

```dart
    // --- Focus-note ordering: focuses seen in the scan, MRU-first, each with
    // its most-common Plot scope. Only no-link (Plot) threads count toward a
    // focus-note row's scope; connector threads still feed the colour tally.
    final focusScopeCounts = <Uuid, Map<BigInt?, int>>{};
    final focusOrder = <Uuid>[]; // MRU-first, deduped
    // --- Colour tally: most-common priorityId per connectionColorKey.
    final connKeyPriorityCounts = <String, Map<Uuid, int>>{};
    // --- Disambiguation: per connectionColorKey, name -> ordered addresses.
    final connKeyNameAddrs = <String, Map<String, List<String>>>{};

    for (final st in scan.threads) {
      // Colour tally key for this scanned thread.
      final isPlot = st.primaryLink == null;
      final connKey = isPlot
          ? 'plot:${st.teamId?.toString() ?? 'personal'}'
          : 'conn:${st.primaryLink!.instanceId}';
      (connKeyPriorityCounts[connKey] ??= {}).update(
        st.priorityId, (n) => n + 1, ifAbsent: () => 1);

      if (isPlot) {
        if (!focusOrder.contains(st.priorityId)) focusOrder.add(st.priorityId);
        (focusScopeCounts[st.priorityId] ??= {}).update(
          st.teamId, (n) => n + 1, ifAbsent: () => 1);
      }

      // Disambiguation: record each roster contact's name+email for connKey.
      for (final cId in st.contacts) {
        final actor = Actor.fromCache(ActorId.fromUuid(cId));
        final name = actor?.name;
        final email = actor?.email;
        if (name == null || name.isEmpty || email == null) continue;
        final byName = connKeyNameAddrs[connKey] ??= {};
        final list = byName[name.toLowerCase()] ??= [];
        if (!list.contains(email.toLowerCase())) list.add(email.toLowerCase());
      }
    }

    // Resolve the small set of distinct priorityIds we need a colour/object for:
    // the per-connection winners + the focus-note focuses.
    final winners = <Uuid>{
      for (final counts in connKeyPriorityCounts.values)
        _topByCount(counts),
      ...focusOrder,
    };
    final priorities = await Priority.get(order: PriorityOrder.nested);
    final priorityById = {for (final p in priorities) p.id: p};
    final colorByConnection = <String, ThemeColor>{
      for (final e in connKeyPriorityCounts.entries)
        e.key: priorityById[_topByCount(e.value)]?.displayColor
            ?? const ThemeColor.defaultColor(),
    };
    final focusNoteOrder = [
      for (final pid in focusOrder)
        if (priorityById[pid] != null && !priorityById[pid]!.root)
          (priorityId: pid, teamId: _topScope(focusScopeCounts[pid]!)),
    ];
```

Add these small helpers to the bloc (private static):

```dart
  static Uuid _topByCount(Map<Uuid, int> counts) {
    var best = counts.keys.first;
    var bestN = -1;
    counts.forEach((k, n) { if (n > bestN) { best = k; bestN = n; } });
    return best;
  }

  static BigInt? _topScope(Map<BigInt?, int> counts) {
    BigInt? best;
    var bestN = -1;
    counts.forEach((k, n) { if (n > bestN) { best = k; bestN = n; } });
    return best;
  }
```

Then preload roster actors so `Actor.fromCache` (used in the disambiguation loop and at render) is warm. Do this **before** the scan loop above so the loop's `Actor.fromCache` hits:

```dart
    // Warm the actor cache for every roster contact in the scan in one query.
    final rosterIds = {
      for (final st in scan.threads) ...st.contacts,
    }.map(ActorId.fromUuid).toList();
    if (rosterIds.isNotEmpty) {
      await Actor.get(id: null, types: const [ActorType.user, ActorType.contact]);
      // Actor.get with no id returns the candidate set and caches them; if a
      // narrower by-ids fetch exists, prefer it. The aim is fromCache hits below.
    }
```

> Implementation note: prefer a by-ids batch fetch if `Actor` exposes one; otherwise the existing `Actor.get(types: [...])` already caches all contacts. Verify `Actor` has no cheaper `getMany(ids)` before settling on the broad fetch.

Pass all four new fields into the `_ComposeSearchContext(...)` constructor.

- [ ] **Step 4: Verify it compiles**

Run: `cd apps/plot && flutter analyze lib/state/compose_targets.dart`
Expected: No errors.

- [ ] **Step 5: Commit**

```bash
git commit --no-verify -- apps/plot/lib/state/compose_targets.dart apps/plot/lib/widget/compose/compose_target_view.dart -m "feat(compose): resolve focus colour, focuses, roster actors, disambiguation in context build"
```

---

### Task 8: `state.targets` becomes `List<ComposeTargetView>` + `_toView`/`_toViews`

**Files:**
- Modify: `apps/plot/lib/state/compose_targets_state.dart`
- Modify: `apps/plot/lib/state/compose_targets.dart` (`refresh`, `search`, `prependToCache`, add `_toView`/`_toViews`)

- [ ] **Step 1: Change the state type**

```dart
// compose_targets_state.dart
part of 'compose_targets.dart';

class ComposeTargetsState extends Equatable {
  const ComposeTargetsState({required this.targets});
  final List<ComposeTargetView> targets;
  ComposeTargetsState copyWith({List<ComposeTargetView>? targets}) =>
      ComposeTargetsState(targets: targets ?? this.targets);
  @override
  List<Object?> get props => [targets];
}
```

Add the import to `compose_targets.dart`:

```dart
import 'package:plot/widget/compose/compose_target_view.dart';
```

- [ ] **Step 2: Add `_toView` / `_toViews`**

```dart
  /// Resolve a [ComposeTarget] into its presentation view using the cached
  /// context (header text, focus tint, disambiguated recipients, focus object).
  /// Falls back to neutral defaults when no context is cached yet (e.g. a fresh
  /// prepend before the next refresh).
  ComposeTargetView _toView(ComposeTarget t, _ComposeSearchContext? ctx) {
    final header = _headerFor(t, ctx);
    // Focus-notes tint by their own focus; everything else by its connection.
    final ThemeColor color;
    Priority? focus;
    if (t.kind == ComposeTargetKind.note && t.priorityId != null) {
      focus = ctx?.priorityById[t.priorityId!];
      color = focus?.displayColor ?? const ThemeColor.defaultColor();
    } else {
      color = ctx?.colorByConnection[connectionColorKey(t)]
          ?? const ThemeColor.defaultColor();
    }
    final recipients = _recipientsFor(t, ctx);
    return ComposeTargetView(
      target: t,
      header: header,
      headerColor: color,
      recipients: recipients,
      focusPriority: focus,
    );
  }

  List<ComposeTargetView> _toViews(
    List<ComposeTarget> targets,
    _ComposeSearchContext? ctx,
  ) => [for (final t in targets) _toView(t, ctx)];
```

`_headerFor` builds line-1 text:

```dart
  String _headerFor(ComposeTarget t, _ComposeSearchContext? ctx) {
    switch (t.kind) {
      case ComposeTargetKind.connector:
        final target = t.target!;
        final showAccount = (ctx?.connectionCount(target) ?? 1) > 1;
        final account = target.accountName;
        return (showAccount && account != null && account.isNotEmpty)
            ? '${target.connectorName} · $account'
            : target.connectorName;
      case ComposeTargetKind.twist:
        return t.label; // twist name is already the label
      case ComposeTargetKind.chat:
      case ComposeTargetKind.note:
        final hasTeams = ctx?.hasTeams ?? false;
        if (!hasTeams) return 'Plot';
        final scope = t.teamId == null
            ? 'Personal'
            : (ctx?.teamNames[t.teamId] ?? 'Team');
        return 'Plot · $scope';
    }
  }
```

`_recipientsFor` builds the people list (chat + connector DM) applying disambiguation:

```dart
  List<RecipientDisplay> _recipientsFor(
    ComposeTarget t, _ComposeSearchContext? ctx) {
    final isPeople = t.kind == ComposeTargetKind.chat ||
        (t.kind == ComposeTargetKind.connector && (t.target?.isDmType ?? false));
    if (!isPeople) return const [];
    final connKey = connectionColorKey(t);
    final byName = ctx?.nameToEmailsByConnection[connKey] ?? const {};
    final inputs = <RecipientInput>[];
    for (final cId in t.contacts) {
      final actor = Actor.fromCache(ActorId.fromUuid(cId));
      final name = actor?.nameOrEmail ?? '';
      inputs.add((name: name, email: actor?.email, actorId: ActorId.fromUuid(cId)));
    }
    for (final encoded in t.inviteEmails) {
      final inv = InviteAddress.parse(encoded);
      inputs.add((name: inv.name ?? inv.email, email: inv.email, actorId: null));
    }
    return resolveRecipientDisplays(
      recipients: inputs,
      nameToEmailsForConnection: byName,
    );
  }
```

- [ ] **Step 3: Wire `refresh` / `search` / `prependToCache` to views**

- `refresh()`: after `_materializeBaseList()` returns `List<ComposeTarget>`, fetch the cached ctx and emit views: `emit(state.copyWith(targets: _toViews(targets, await _searchContextFor())));`
- `search()`: change return type to `Future<List<ComposeTargetView>>`; wherever it currently returns `state.targets` (already views) return them; wherever it builds `List<ComposeTarget>`, map through `_toViews(..., ctx)` (it already obtains `ctx` via `_searchContextFor()`).
- `prependToCache(ComposeTarget target)`: build a view via `_toView(target, _searchContext)` (sync best-effort with the cached context) and prepend it, deduping by `target.signature`:

```dart
  void prependToCache(ComposeTarget target) {
    _invalidateSearchContext();
    final view = _toView(target, _searchContext); // _searchContext may be null
    final next = <ComposeTargetView>[
      view,
      ...state.targets.where((v) => v.target.signature != target.signature),
    ];
    emit(state.copyWith(targets: next));
  }
```

> `_invalidateSearchContext()` sets `_searchContext = null`, so `_toView` here uses neutral defaults — acceptable for the just-created prepend; the next `refresh()` re-resolves colours. If you want the prepend to keep colour, capture `final ctx = _searchContext;` **before** `_invalidateSearchContext()` and pass `ctx`.

- [ ] **Step 4: Verify it compiles**

Run: `cd apps/plot && flutter analyze lib/state/compose_targets.dart lib/state/compose_targets_state.dart`
Expected: errors only in `target_picker_list.dart` (fixed in Phase C) — none in these two files.

- [ ] **Step 5: Commit**

```bash
git commit --no-verify -- apps/plot/lib/state/compose_targets.dart apps/plot/lib/state/compose_targets_state.dart -m "feat(compose): emit ComposeTargetView from bloc (header, tint, recipients, focus)"
```

---

### Task 9: Focus-note + twist targets replace Note/Chat in the base list

**Files:**
- Modify: `apps/plot/lib/state/compose_targets.dart` (`_materializeBaseList` ~253-306)

- [ ] **Step 1: Replace the Note/Chat template loop with focus-notes + twists**

In `_materializeBaseList`, the "Always-available templates" section currently loops `teamScopes` adding `ComposeTarget.note(...)` + `ComposeTarget.chat(...)`. Replace that loop with:

```dart
    // Focus-note targets: each focus seen in the scan, MRU-first, with its
    // most-common Plot scope (spec §3).
    for (final f in ctx.focusNoteOrder) {
      templates.add(ComposeTarget.focusNote(
        priorityId: f.priorityId,
        teamId: f.teamId,
      ));
    }
    // Twist targets: every chat-capable twist instance (spec §3) — net-new in
    // step 1.
    for (final twist in await _chatCapableTwists()) {
      templates.add(ComposeTarget.twist(
        twist,
        allInstances: const [],
        teamName: twist.teamId == null ? null : ctx.teamNames[twist.teamId],
      ));
    }
```

Leave the connector-template loop (`for (final t in ctx.createTargets)`) unchanged. Leave the used-combos pass (which still yields rostered Plot chats + connector DM combos) unchanged.

- [ ] **Step 2: Add `_chatCapableTwists()`**

Mirror how the step-2 Connection field sources twists (it builds `TwistConnectionChoice`). Locate that source (search `TwistConnectionChoice(` and `TwistInstance.` in `lib/page/new_thread.dart` / `lib/widget/compose/`) and reuse the same query. Concretely:

```dart
  /// Chat-capable twist instances to surface as step-1 targets. Mirrors the
  /// twists offered by the step-2 Connection field.
  Future<List<TwistInstance>> _chatCapableTwists() async {
    // Verify the exact predicate against the step-2 Connection field source.
    final all = await TwistInstance.getActive();
    return all.where((t) => t.isChatCapable).toList();
  }
```

> The exact `TwistInstance` accessor (`getActive` / `getAll`) and the chat-capable predicate (`isChatCapable` or a `parsedLinkTypes`/`compose` check) must match the step-2 source. Find it before writing this — do not invent a predicate. If twists are sourced via a bloc/store helper in step 2, call the same helper.

- [ ] **Step 3: Verify it compiles**

Run: `cd apps/plot && flutter analyze lib/state/compose_targets.dart`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git commit --no-verify -- apps/plot/lib/state/compose_targets.dart -m "feat(compose): focus-note + twist targets replace generic Note/Chat"
```

---

### Task 10: Multi-recipient email search

**Files:**
- Modify: `apps/plot/lib/state/compose_targets.dart` (`search` ~67-81; replace `_searchByEmail` ~464-520 with `_searchByRecipients`)

- [ ] **Step 1: Route email-mode queries to the multi-recipient path**

In `search()`:

```dart
  Future<List<ComposeTargetView>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return state.targets;

    final recipients = EmailParser.parseRecipients(trimmed);
    if (recipients.isNotEmpty) {
      return _searchByRecipients(recipients);
    }

    final ctx = await _searchContextFor();
    final lower = trimmed.toLowerCase();
    final filtered = state.targets // already views
        .where((v) => v.target.label.toLowerCase().contains(lower)
            || v.header.toLowerCase().contains(lower))
        .map((v) => v.target)
        .toList();
    final byName = await _searchByName(trimmed);
    return _toViews(_dedupeBySignature([...filtered, ...byName]), ctx);
  }
```

> `_searchByName` still returns `List<ComposeTarget>`; map the deduped result through `_toViews`. Update its signature only if you also want it to filter views.

- [ ] **Step 2: Implement `_searchByRecipients`** (generalises `_searchByEmail`)

```dart
  /// Email-mode synthesis for one or more parsed recipients. Resolves each
  /// address to a known contact (roster) or a pending named invite, then emits
  /// Plot Chat options (Personal + each team, pinned) carrying ALL recipients,
  /// followed by address-capable connections carrying the same roster.
  Future<List<ComposeTargetView>> _searchByRecipients(
    List<ParsedRecipient> recipients,
  ) async {
    final ctx = await _searchContextFor();

    final contactIds = <Uuid>[];
    final invites = <String>[];
    for (final r in recipients) {
      final actors = await Actor.get(
        search: r.email,
        types: const [ActorType.user, ActorType.contact],
        primary: true,
        inviteable: true,
      );
      final matched = actors
          .where((a) => (a.email ?? '').toLowerCase() == r.email)
          .toList();
      if (matched.isNotEmpty) {
        contactIds.add(matched.first.id.toUuid());
      } else {
        invites.add(InviteAddress.format(email: r.email, name: r.name));
      }
    }

    final teamScopes = <BigInt?>[null, ...ctx.teams.map((t) => t.teamId)];
    final chats = <ComposeTarget>[
      for (final teamId in teamScopes)
        ComposeTarget.chat(
          teamId: teamId,
          hasTeams: ctx.hasTeams,
          teamName: teamId == null ? null : ctx.teamNames[teamId],
          contactDetail: null, // presentation comes from the view's recipients
          contacts: contactIds,
          groups: const [],
          inviteEmails: invites,
        ),
    ];

    final addressCapable = ctx.createTargets
        .where((t) => t.isDmType)
        .map((t) => ComposeTarget.connector(
              t,
              connectionCount: ctx.connectionCount(t),
              contacts: contactIds,
            ))
        .toList();
    final ranked = _prefs.rankSignaturesByMru(
      signatures: addressCapable.map((t) => t.signature).toList());
    final bySig = {for (final t in addressCapable) t.signature: t};
    final rankedConnectors = [for (final sig in ranked) bySig[sig]!];

    return _toViews(
      _dedupeBySignature([...chats, ...rankedConnectors]), ctx);
  }
```

> The recipients carried by these synthesized targets won't be in the per-connection disambiguation map (that map is built from *historical* scan threads), so `_recipientsFor` shows bare names for them with emails on hover — correct: there is no on-screen duplicate to disambiguate within a single freshly-typed roster. Resolved contacts may not be warm in `Actor.fromCache`; `Actor.get(search:)` above caches them, so `_recipientsFor` resolves names.

- [ ] **Step 3: Delete the old `_searchByEmail`** (now replaced) and update any caller.

- [ ] **Step 4: Verify it compiles**

Run: `cd apps/plot && flutter analyze lib/state/compose_targets.dart`
Expected: No errors.

- [ ] **Step 5: Commit**

```bash
git commit --no-verify -- apps/plot/lib/state/compose_targets.dart -m "feat(compose): multi-recipient + named-invite email search"
```

---

### Task 11: Bloc tests for focus-notes + multi-recipient search

**Files:**
- Modify: `apps/plot/test/state/compose_targets_test.dart`

- [ ] **Step 1: Add tests** exercising the pure/derivable pieces without a DB where possible. The existing file tests `composeSignatureForScanThread` / `buildUsedTargetSignatures` (pure). Add:
  - `ComposeTarget.focusNote` signature distinctness (two different focuses → different signatures; same focus+scope → equal).
  - `connectionColorKey`: connector vs `plot:personal` vs `plot:<team>` produce the documented keys.
  - `_topByCount` / `_topScope` tie-break + winner (expose them as `@visibleForTesting` static helpers, or test via a small public wrapper).

```dart
  test('focusNote signature is per focus+scope', () {
    final a = Uuid.generate();
    final b = Uuid.generate();
    final t1 = ComposeTarget.focusNote(priorityId: a, teamId: null);
    final t2 = ComposeTarget.focusNote(priorityId: a, teamId: null);
    final t3 = ComposeTarget.focusNote(priorityId: b, teamId: null);
    expect(t1.signature, t2.signature);
    expect(t1.signature, isNot(t3.signature));
  });

  test('connectionColorKey is per Plot scope', () {
    final personal = ComposeTarget.chat(teamId: null, hasTeams: true);
    final team = ComposeTarget.chat(teamId: BigInt.from(7), hasTeams: true);
    expect(connectionColorKey(personal), 'plot:personal');
    expect(connectionColorKey(team), 'plot:7');
  });
```

Add `import 'package:plot/widget/compose/compose_target_view.dart';`.

- [ ] **Step 2: Run, verify PASS**

Run: `cd apps/plot && flutter test test/state/compose_targets_test.dart`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git commit --no-verify -- apps/plot/test/state/compose_targets_test.dart -m "test(compose): focus-note + connection-key derivation"
```

---

## Phase C — Row UI (two-line rows)

### Task 12: `_results` → views, two-line row scaffold + item height

**Files:**
- Modify: `apps/plot/lib/widget/compose/target_picker_list.dart`

- [ ] **Step 1: Switch the result type to views**

- `List<ComposeTarget> _results` → `List<ComposeTargetView> _results`.
- `initState`: `_results = context.read<ComposeTargetsBloc>().state.targets;` (now views — type matches).
- `_onBaseListChanged(state)`: `_results = state.targets;` (views).
- `_runSearch`: `search(query)` now returns `List<ComposeTargetView>` — assign directly.
- `onActivate` / `_handleEnter` / tap handlers: call `widget.onSelect(_results[index].target)` (unwrap `.target`).
- `BlocListener<ComposeTargetsBloc, ComposeTargetsState>(listenWhen: (p, c) => p.targets != c.targets, ...)` — unchanged (compares view lists).
- `widget.onSelect` keeps signature `void Function(ComposeTarget)`.

- [ ] **Step 2: Bump the item-height estimate**

Two-line rows are taller. Change both occurrences of `estimatedItemHeight = 50.0` / `estimatedItemHeight: 50.0` to a shared constant:

```dart
  /// Two-line rows: header (xs) + content (~20px avatars/text) + padding.
  static const double _estimatedItemHeight = 62.0;
```

Use `_estimatedItemHeight` in `_scrollToIndex` (replacing the local `const estimatedItemHeight = 50.0;`) and in `ListViewSelector(estimatedItemHeight: _estimatedItemHeight)`.

- [ ] **Step 3: Verify it compiles** (rows will still render via the old `_targetTile` until Task 13; temporarily build the header on top of the existing tile is fine, but the next task replaces `_targetTile` wholesale)

Run: `cd apps/plot && flutter analyze lib/widget/compose/target_picker_list.dart`
Expected: errors only where `_targetTile`/`_buildRow` reference `target.kind` on a view — fix by passing `view.target` into the (still single-line) tile for now. Keep this step compiling.

- [ ] **Step 4: Commit**

```bash
git commit --no-verify -- apps/plot/lib/widget/compose/target_picker_list.dart -m "refactor(compose): picker list operates on ComposeTargetView + taller rows"
```

---

### Task 13: Two-line row content widget

**Files:**
- Modify: `apps/plot/lib/widget/compose/target_picker_list.dart`

- [ ] **Step 1: Replace `_targetTile` with a two-line builder**

Replace `_buildRow`'s `final tile = _targetTile(context, target);` with `final tile = _rowContent(context, view);`, and replace `_targetTile` with:

```dart
  /// Two-line row: line 1 = focus-tinted connection header; line 2 = leading
  /// glyph + people / channel / focus / twist content.
  Widget _rowContent(BuildContext context, ComposeTargetView view) {
    final isDark = context.read<ThemeBloc>().isDarkMode(context);
    final spacing = context.theme.spacing;
    final headerColor =
        context.colour.colours.fromTheme(view.headerColor, muted: true);
    final leadingPadding = EdgeInsets.only(left: spacing.lg, right: 8);

    final EdgeInsets padding = widget.inline
        ? EdgeInsets.symmetric(vertical: spacing.xs)
        : EdgeInsets.symmetric(horizontal: spacing.lg, vertical: spacing.xs);

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Line 1: connection header, focus-tinted. Style copied from the
          // ThreadWidget channel header (typography.xs, height 1, ellipsis).
          Padding(
            padding: EdgeInsets.only(left: spacing.lg, bottom: 2),
            child: Text(
              view.header,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.theme.typography.xs.copyWith(
                color: headerColor,
                height: 1,
              ),
            ),
          ),
          // Line 2: leading glyph + content.
          _rowContentLine(context, view, isDark, leadingPadding),
        ],
      ),
    );
  }
```

- [ ] **Step 2: Implement `_rowContentLine` per content kind**

```dart
  Widget _rowContentLine(
    BuildContext context,
    ComposeTargetView view,
    bool isDark,
    EdgeInsets leadingPadding,
  ) {
    final t = view.target;
    // Focus-note: focus icon + name in the focus colour, via FocusLabel.
    if (t.kind == ComposeTargetKind.note && view.focusPriority != null) {
      return Padding(
        padding: leadingPadding,
        child: FocusLabel(priority: view.focusPriority, muted: true),
      );
    }

    final leading = Padding(
      padding: leadingPadding,
      child: _leadingGlyph(context, view, isDark),
    );

    // People: AvatarGroup + names (exception-only emails), with a hover tooltip.
    if (view.recipients.isNotEmpty) {
      final actors = [
        for (final r in view.recipients)
          if (r.actorId != null) Actor.fromCache(r.actorId!),
      ].whereType<Actor>().toList();
      final names = view.recipients
          .map((r) => r.showEmail && r.email != null
              ? '${r.name} <${r.email}>'
              : r.name)
          .join(', ');
      final content = Row(
        children: [
          leading,
          if (actors.isNotEmpty) ...[
            AvatarGroup(actors: actors, totalCount: view.recipients.length, size: 18),
            SizedBox(width: context.theme.spacing.xs),
          ],
          Expanded(
            child: Text(names,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: context.theme.typography.md),
          ),
        ],
      );
      return _withRecipientTooltip(context, view, content);
    }

    // Twist: logo + twist name.
    if (t.kind == ComposeTargetKind.twist) {
      return Row(children: [
        leading,
        Expanded(child: Text(t.label,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: context.theme.typography.md)),
      ]);
    }

    // Channel connector: logo + channel name.
    final channelName = t.channel?.title ?? t.label;
    return Row(children: [
      leading,
      Expanded(child: Text(channelName,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: context.theme.typography.md)),
    ]);
  }
```

- [ ] **Step 3: Implement `_leadingGlyph`** (extract logo resolution from the old `_targetTile`)

```dart
  Widget _leadingGlyph(BuildContext context, ComposeTargetView view, bool isDark) {
    final t = view.target;
    switch (t.kind) {
      case ComposeTargetKind.chat:
        return SvgPicture.asset('assets/plot-icon.svg', width: 16, height: 16);
      case ComposeTargetKind.note:
        // Focus-note handled earlier; this branch is unreached, kept for switch
        // exhaustiveness — show the Plot icon as a safe fallback.
        return SvgPicture.asset('assets/plot-icon.svg', width: 16, height: 16);
      case ComposeTargetKind.connector:
        final lt = t.linkType;
        final logo = lt == null ? null : (isDark ? (lt.logoDark ?? lt.logo) : lt.logo);
        return logo != null
            ? LogoImage(url: logo, size: 16, fallback: const Icon(PlotIcon.link, size: 16))
            : const Icon(PlotIcon.link, size: 16);
      case ComposeTargetKind.twist:
        final tw = t.connection;
        final logo = tw == null ? null : (isDark ? (tw.logoUrlDark ?? tw.logoUrl) : tw.logoUrl);
        return logo != null
            ? LogoImage(url: logo, size: 16, fallback: const Icon(PlotIcon.twist, size: 16))
            : const Icon(PlotIcon.twist, size: 16);
    }
  }
```

- [ ] **Step 4: Add the `FocusLabel` import** (from `lib/widget/priority.dart`, likely surfaced via `widget.dart`; verify and import the right path). Confirm `FocusLabel` takes `priority:` + `muted:`.

- [ ] **Step 5: Verify it compiles**

Run: `cd apps/plot && flutter analyze lib/widget/compose/target_picker_list.dart`
Expected: No errors (info OK).

- [ ] **Step 6: Commit**

```bash
git commit --no-verify -- apps/plot/lib/widget/compose/target_picker_list.dart -m "feat(compose): two-line rows (header + people/channel/focus/twist)"
```

---

### Task 14: Row-level hover tooltip (names + full emails)

**Files:**
- Modify: `apps/plot/lib/widget/compose/target_picker_list.dart`

- [ ] **Step 1: Implement `_withRecipientTooltip`**

```dart
  /// Wrap the people content in an FTooltip listing every recipient as
  /// "Name — email", satisfying "on hover, show the full list of names and
  /// email addresses".
  Widget _withRecipientTooltip(
    BuildContext context, ComposeTargetView view, Widget child) {
    final lines = view.recipients.map((r) {
      final email = r.email;
      return (email != null && email.isNotEmpty && email != r.name)
          ? '${r.name} — $email'
          : r.name;
    }).join('\n');
    if (lines.isEmpty) return child;
    return FTooltip(
      tipBuilder: (context, _) => Text(lines),
      child: child,
    );
  }
```

> Confirm the `FTooltip` API in this forui version (`tipBuilder` vs `tip`); match an existing usage in the app (e.g. `lib/widget/avatar.dart`). Mind the thread-panel tooltip-clipping note — not an issue for the inline step-1 page, which uses the root overlay.

- [ ] **Step 2: Verify it compiles**

Run: `cd apps/plot && flutter analyze lib/widget/compose/target_picker_list.dart`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git commit --no-verify -- apps/plot/lib/widget/compose/target_picker_list.dart -m "feat(compose): hover tooltip with full names + emails"
```

---

## Phase D — Step-2 hand-off

### Task 15: Pre-select the focus for a focus-note target

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart` (`_suggestFocusForTarget` ~885-920; `onSelect`/`_applyTarget` call sites)

- [ ] **Step 1: `onSelect` already receives a `ComposeTarget`** (the picker unwraps `view.target` in Task 12), so `_applyTarget(target)` is unchanged.

- [ ] **Step 2: Pre-select the focus when present**

At the top of `_suggestFocusForTarget(ComposeTarget target)`:

```dart
    if (target.priorityId != null) {
      final priorities = await Priority.get(order: PriorityOrder.nested);
      final p = priorities.where((x) => x.id == target.priorityId).firstOrNull;
      if (p != null) {
        if (!mounted) return;
        setState(() => _focusSuggestionOrder = [p]);
        await _switchToPriority(p);
        return;
      }
    }
```

(Keep the existing roster/global MRU logic below for all other targets.)

- [ ] **Step 3: Verify it compiles**

Run: `cd apps/plot && flutter analyze lib/page/new_thread.dart`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git commit --no-verify -- apps/plot/lib/page/new_thread.dart -m "feat(compose): focus-note target pre-selects its focus in step 2"
```

---

## Phase E — Server: named contacts from `Name <email>`

### Task 16: Parse the invite name before `upsert_contacts`

**Files:**
- Modify: `workers/api/src/app/sync/threads.ts` (~776-784)
- Test: nearest unit test for this module (create `workers/api/src/app/sync/threads.invite.test.ts` if none — exclude from the integration pool by keeping it outside `__tests__/`).

- [ ] **Step 1: Write a failing unit test for a `parseInviteAddress` helper**

```ts
// workers/api/src/app/sync/threads.invite.test.ts
import { describe, it, expect } from "vitest";
import { parseInviteAddress } from "./threads";

describe("parseInviteAddress", () => {
  it("parses Name <email>", () => {
    expect(parseInviteAddress("Kris Braun <kris@plot.day>")).toEqual({
      email: "kris@plot.day",
      name: "Kris Braun",
    });
  });
  it("parses bare email", () => {
    expect(parseInviteAddress("kris@plot.day")).toEqual({ email: "kris@plot.day" });
  });
  it("lowercases the email", () => {
    expect(parseInviteAddress("Kris <KRIS@Plot.Day>").email).toBe("kris@plot.day");
  });
  it("unquotes the name", () => {
    expect(parseInviteAddress('"Braun, Kris" <k@x.com>').name).toBe("Braun, Kris");
  });
});
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd workers/api && timeout 120 pnpm test -- threads.invite`
Expected: FAIL (`parseInviteAddress` not exported).

- [ ] **Step 3: Implement + export the helper and use it at the call site**

Add near the top of `threads.ts` (exported for the test):

```ts
/** Parse a pending invite entry that may be `"Name <email>"` or a bare email. */
export function parseInviteAddress(raw: string): { email: string; name?: string } {
  const m = raw.match(/^(.*)<([^>]+)>$/);
  if (m) {
    const email = m[2].trim().toLowerCase();
    let name = m[1].trim();
    if (name.length >= 2 && name.startsWith('"') && name.endsWith('"')) {
      name = name.slice(1, -1).trim();
    }
    return name ? { email, name } : { email };
  }
  return { email: raw.trim().toLowerCase() };
}
```

Change the `upsert_contacts` call (~781) from:

```ts
contacts: JSON.stringify(inviteEmails.map((email: string) => ({ email: email.toLowerCase() }))),
```

to:

```ts
contacts: JSON.stringify(inviteEmails.map((raw: string) => parseInviteAddress(raw))),
```

`upsert_contacts` already stores `name` via `COALESCE(EXCLUDED.name, contact.name)`, so a named invite creates/updates a named contact; a bare email is unchanged.

- [ ] **Step 4: Run, verify it passes**

Run: `cd workers/api && timeout 120 pnpm test -- threads.invite`
Expected: PASS.

- [ ] **Step 5: Lint the worker**

Run: `cd workers/api && pnpm lint`
Expected: no **new** `error TS` (two pre-existing errors may remain — see project notes).

- [ ] **Step 6: Commit**

```bash
git commit -- workers/api/src/app/sync/threads.ts workers/api/src/app/sync/threads.invite.test.ts -m "feat(sync): create named contacts from Name<email> invites"
```

> Backwards-compat: old clients send bare emails (unchanged behaviour). New clients sending `"Name <email>"` require this server change to have shipped first — guaranteed by the enforced workers-before-app deploy ordering. Note this in the finalize step.

---

## Phase F — Finalize

### Task 17: Docs, full analyze, back-compat, manual verification

**Files:**
- Modify: `docs/updates.md`, `docs/features.md`

- [ ] **Step 1: Run `/finalize`-equivalent checks**

```bash
cd apps/plot && flutter analyze
cd ../../workers/api && pnpm lint
cd apps/plot && flutter test test/widget/compose test/state/compose_targets_test.dart
cd ../../workers/api && timeout 120 pnpm test -- threads.invite
```

Expected: analyze clean (info OK); worker lint no new errors; all listed tests PASS.

- [ ] **Step 2: Confirm `captureException` on any new `catch`**

The only new `catch`-adjacent code is server-side; the `inviteEmails` processing block already wraps errors with `c.var.tracker.captureException`. The bloc's new work runs inside the existing `_buildSearchContext`/`search` paths whose `catchError`/`Tracker.captureException` already cover failures (`_runSearch` catches in `target_picker_list.dart`). Add `Tracker.captureException` to any new bloc catch you introduced.

- [ ] **Step 3: `docs/updates.md`** — add a top bullet (plain language):

```markdown
- The new-thread picker now shows each option as a connection with its people or channel below, tinted by the focus you most often use it for. You can paste several email addresses at once (separated by spaces, commas, or semicolons) and use the "Name <email>" form to invite someone by name. When two people share a name, the picker shows the email that tells them apart, and hovering any row reveals everyone's full name and address.
```

- [ ] **Step 4: `docs/features.md`** — update the new-thread/compose section to describe the two-line picker rows, focus tinting, multi-recipient + named invites, and email disambiguation.

- [ ] **Step 5: Manual verification (run-app skill)** — checklist:
  - Rows render two-line for each kind: connector channel, connector DM (avatars + names), Plot chat (Plot icon + avatars + names), focus-note (focus icon + name in focus colour), twist (twist logo + name).
  - Headers are tinted; a work team's Plot rows differ in colour from Personal.
  - Names truncate with `…`; AvatarGroup overflows to "+N".
  - Hover a people row → tooltip lists every name + full email.
  - Type `kris@plot.day dana@acme.co` → one chat row carrying both; type `Kris Braun <new@x.com>` → chat with a named invite chip "Kris Braun"; submit → a contact named "Kris Braun" exists (check local DB / sync).
  - Two contacts with the same display name on one connection → primary bare, secondary shows the email.
  - Keyboard nav (↑/↓/Enter), the clear button, and the "Add a connection…" row still work; scroll-to-highlight lands correctly with the taller rows.

- [ ] **Step 6: Commit**

```bash
git commit --no-verify -- docs/updates.md docs/features.md -m "docs: new-thread picker rows, focus tint, multi-recipient invites"
```

- [ ] **Step 7: Finishing the branch** — use `superpowers:finishing-a-development-branch` to open the PR (single PR; no `public/` submodule changes, so no separate submodule PR; no changeset needed — Twister types untouched).

---

## Self-review notes (author)

- **Spec coverage:** two-line rows (T12–14), focus tint + caching (T6–8), drop Note/Chat → focus-notes + twists (T9), people AvatarGroup + names (T13), channel (T13), focus-note via FocusLabel (T13), twist row (T9/T13), multi-recipient + separators + `Name<email>` (T1, T10), named contact create (T16), hover full names+emails (T14), exception-only inline emails (T5, T13), focus pre-select (T15), per-scope `plot:{scope}` tint key (T7), quieter account rule (T8 `_headerFor`). All §1–§8 + §9 decisions mapped.
- **Verify-before-coding flags (not placeholders — real lookups the engineer must do):** the twist source/predicate in T9 (must match step-2's source), the `Actor` by-ids batch fetch in T7, the `FocusLabel` and `FTooltip` constructor shapes (T13/T14), and whether `ThemeColor`/`Priority` are re-exported by `store.dart` (T5). Each cites where to confirm.
- **Type consistency:** `ComposeTargetView`/`RecipientDisplay`/`RecipientInput` used consistently across T5/T7/T8/T12/T13; `parseRecipients`/`InviteAddress`/`parseInviteAddress` names stable across T1/T2/T10/T16; `connectionColorKey`/`_topByCount`/`_topScope` stable across T7/T8/T11.
