import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/widget/emoji.dart';
import 'package:plot/widget/emoji_data.g.dart';
import 'package:plot/widget/modal.dart';

/// A picker that lets the user choose an emoji reaction. Shows a quick-picks
/// row at the top and a categorized scrollable grid below.
///
/// Open via [ReactionPicker.pick] which resolves to the chosen emoji string
/// (Unicode grapheme cluster), or `null` if the user dismissed without
/// picking.
///
/// When [allowed] is non-null the grid is filtered to that set — used for
/// connectors with `reactionCapabilities.mode === 'fixed'` (e.g. LinkedIn).
class ReactionPicker extends Modal {
  ReactionPicker({
    this.allowed,
    super.key,
  }) : super(
         constraints: const BoxConstraints(maxHeight: 480, maxWidth: 360),
         padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
         builder: (context) => _ReactionPickerContent(allowed: allowed),
       );

  /// When set, only these emoji are selectable. Used to enforce the
  /// connector's `reactionCapabilities`.
  final Set<Reaction>? allowed;

  Future<Reaction?> run(BuildContext context) {
    return super
        .show<Reaction>(context)
        .then((value) => value.present ? value.value : null);
  }

  /// Convenience entry point: opens the picker and returns the chosen emoji.
  static Future<Reaction?> pick(
    BuildContext context, {
    Set<Reaction>? allowed,
  }) {
    return ReactionPicker(allowed: allowed).run(context);
  }
}

class _ReactionPickerContent extends StatefulWidget {
  const _ReactionPickerContent({this.allowed});

  final Set<Reaction>? allowed;

  @override
  State<_ReactionPickerContent> createState() => _ReactionPickerContentState();
}

class _ReactionPickerContentState extends State<_ReactionPickerContent> {
  late final TextEditingController _searchController;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchController.addListener(() {
      setState(() {
        _query = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _isAllowed(Reaction emoji) {
    final allow = widget.allowed;
    if (allow == null) return true;
    return allow.contains(emoji);
  }

  @override
  Widget build(BuildContext context) {
    final quickPicks = kReactionQuickPicks.where(_isAllowed).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Search input
        FTextField(
          control: .managed(controller: _searchController),
          hint: 'Search emoji',
          autocorrect: false,
        ),
        const SizedBox(height: 12),

        // Quick picks
        if (quickPicks.isNotEmpty && _query.isEmpty) ...[
          const _Heading('Quick picks'),
          const SizedBox(height: 6),
          _EmojiGrid(
            emoji: quickPicks,
            onPick: (e) => Modal.pop<Reaction>(context, Value<Reaction>(e)),
          ),
          const SizedBox(height: 12),
        ],

        // Full set, by category
        Expanded(
          child: _CategorisedEmojiList(
            query: _query,
            isAllowed: _isAllowed,
            onPick: (e) => Modal.pop<Reaction>(context, Value<Reaction>(e)),
          ),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: context.theme.typography.sm.copyWith(
        color: context.colour.muted,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// A scrollable list of (category, emoji) sections.
class _CategorisedEmojiList extends StatelessWidget {
  const _CategorisedEmojiList({
    required this.query,
    required this.isAllowed,
    required this.onPick,
  });

  final String query;
  final bool Function(Reaction) isAllowed;
  final void Function(Reaction) onPick;

  @override
  Widget build(BuildContext context) {
    // Optionally filter the categorized set to the query. The "shortcode"
    // search is a simple substring match on the curated label-per-emoji map.
    final sections = <_EmojiSection>[];
    for (final entry in _kEmojiCategories.entries) {
      final filtered = entry.value
          .where(isAllowed)
          .where((e) {
            if (query.isEmpty) return true;
            // Compare against any label substring for the emoji.
            final labels = _kEmojiLabels[e];
            if (labels == null) return false;
            return labels.any((l) => l.contains(query));
          })
          .toList(growable: false);
      if (filtered.isEmpty) continue;
      sections.add(_EmojiSection(name: entry.key, emoji: filtered));
    }

    if (sections.isEmpty) {
      return Center(
        child: Text(
          'No emoji match',
          style: context.theme.typography.sm.copyWith(
            color: context.colour.muted,
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: sections.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        final section = sections[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Heading(section.name),
            const SizedBox(height: 6),
            _EmojiGrid(emoji: section.emoji, onPick: onPick),
          ],
        );
      },
    );
  }
}

class _EmojiSection {
  const _EmojiSection({required this.name, required this.emoji});

  final String name;
  final List<Reaction> emoji;
}

class _EmojiGrid extends StatelessWidget {
  const _EmojiGrid({required this.emoji, required this.onPick});

  final List<Reaction> emoji;
  final void Function(Reaction) onPick;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final e in emoji)
          _EmojiButton(emoji: e, onTap: () => onPick(e)),
      ],
    );
  }
}

class _EmojiButton extends StatelessWidget {
  const _EmojiButton({required this.emoji, required this.onTap});

  final Reaction emoji;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: context.colour.muted.withValues(alpha: 0.3),
        ),
        child: EmojiText(emoji, size: 20),
      ),
    );
  }
}

/// Full Unicode 15.1 emoji set, sourced from
/// `apps/plot/lib/widget/emoji_data.g.dart` (generated from
/// `https://unicode.org/Public/emoji/15.1/emoji-test.txt`; regenerate via
/// `apps/plot/scripts/gen_emoji_data.py`).
const Map<String, List<Reaction>> _kEmojiCategories = kUnicodeEmojiCategories;

/// Search keywords for every emoji in [_kEmojiCategories], from CLDR
/// names + subgroup labels. Misses fall back to "no match" in the picker.
const Map<Reaction, List<String>> _kEmojiLabels = kUnicodeEmojiLabels;
