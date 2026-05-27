import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/emoji.dart';
import 'package:plot/widget/emoji_data.g.dart';
import 'package:plot/widget/select_modal.dart';

/// Grid-shaped emoji picker built on top of [SelectModal] in grid mode.
///
/// Replaces the bespoke `ReactionPicker`: gets full keyboard navigation
/// (arrow keys move 2-D across the grid, Enter selects, Escape closes,
/// type-to-search), MRU "Recent" group when provided, and the same
/// `allowed`-set filtering used by `reactionCapabilitiesForLinkSource`.
///
/// Open via [EmojiPicker.pick] which resolves to the chosen emoji string
/// (Unicode grapheme cluster), or `null` if the user dismissed.
class EmojiPicker {
  EmojiPicker._();

  /// Number of recent emoji shown in the "Recent" group at the top.
  static const int _maxRecent = 16;

  /// Grid width inside the picker. The modal is 360 wide; 8 × 36 cells +
  /// spacing fits within the 12px horizontal padding applied by
  /// [SelectModal] in grid mode.
  static const int _columns = 8;

  /// Open the picker and return the chosen emoji, or null if dismissed.
  ///
  /// [allowed] enforces the link's reaction capabilities (e.g. LinkedIn's
  /// fixed-7 set). [mru] seeds the "Recent" group; pass the current
  /// `LocalPreferencesBloc.state.reactionMru`.
  static Future<Reaction?> pick(
    BuildContext context, {
    Set<Reaction>? allowed,
    List<Reaction>? mru,
  }) async {
    bool isAllowed(Reaction e) => allowed == null || allowed.contains(e);

    // Fall back to the curated default set when the user hasn't reacted
    // yet — the top group is never empty.
    final hasRealMru = mru != null && mru.isNotEmpty;
    final effectiveMru = hasRealMru ? mru : kDefaultReactionMru;
    final topGroupTitle = hasRealMru ? 'Recent' : 'Quick picks';

    List<SelectGroup<Reaction>> buildGroups(String? search) {
      final query = search?.trim().toLowerCase() ?? '';
      final groups = <SelectGroup<Reaction>>[];

      // Top group: only on empty search so search results don't duplicate
      // the chosen emoji across two visible groups.
      if (query.isEmpty) {
        final top = effectiveMru
            .where(isAllowed)
            .take(_maxRecent)
            .toList(growable: false);
        if (top.isNotEmpty) {
          groups.add(
            SelectGroup<Reaction>(title: topGroupTitle, items: top),
          );
        }
      }

      for (final entry in kUnicodeEmojiCategories.entries) {
        final filtered = entry.value
            .where(isAllowed)
            .where((e) {
              if (query.isEmpty) return true;
              final labels = kUnicodeEmojiLabels[e];
              if (labels == null) return false;
              return labels.any((l) => l.contains(query));
            })
            .toList(growable: false);
        if (filtered.isEmpty) continue;
        groups.add(SelectGroup<Reaction>(title: entry.key, items: filtered));
      }
      return groups;
    }

    final result = await SelectModal.open<Reaction>(
      context,
      items: (search) async => buildGroups(search),
      itemBuilder: (emoji, _) {
        return FTooltip(
          tipBuilder: (ctx, _) => Text(emojiDisplayName(emoji)),
          child: EmojiText(emoji, size: 22),
        );
      },
      gridColumns: _columns,
      gridCellSize: 36,
      gridCellSpacing: 4,
      prompt: 'Search emoji',
      emptyMessage: 'No emoji match',
      showFilter: true,
      constraints: const BoxConstraints(maxHeight: 480, maxWidth: 360),
    );
    return result.present ? result.value : null;
  }
}
