import 'package:plot/api/twist_api.dart';
import 'package:plot/store/store.dart' show Priority, PriorityOrder;

/// Suggested defaults for which channels to enable.
class ChannelDefaultSuggestion {
  final Set<String> enabledChannels;

  const ChannelDefaultSuggestion({this.enabledChannels = const {}});
}

/// Common personal email domains that should not match teams.
const _personalDomains = {
  'gmail.com',
  'googlemail.com',
  'outlook.com',
  'hotmail.com',
  'live.com',
  'yahoo.com',
  'icloud.com',
  'me.com',
  'mac.com',
  'aol.com',
  'protonmail.com',
  'proton.me',
  'hey.com',
  'fastmail.com',
  'zoho.com',
  'mail.com',
  'yandex.com',
  'gmx.com',
  'gmx.net',
};

/// Negative signal words in channel titles — likely not user's own content.
final _negativePatterns = RegExp(
  r'\b(other|shared|group|all\s+staff)\b',
  caseSensitive: false,
);

/// Low-value email labels that are rarely useful to sync.
final _lowValueEmailPatterns = RegExp(
  r'^(SENT|DRAFT|UNREAD|SPAM|TRASH|CATEGORY_\w+)$|^\[.+\]|^receipt',
  caseSensitive: false,
);

/// Informational/read-only channel patterns.
final _informationalPatterns = RegExp(
  r'(holidays?\s+in\b|public\s+holidays?|national\s+holidays?|birthdays?|contacts?\b|^phases\s+of\s+the\s+moon)',
  caseSensitive: false,
);

/// Computes smart default channel selections and priority assignments.
class ChannelDefaultSuggester {
  /// Suggest which channels to enable.
  ///
  /// [channels] — available channels from the source.
  /// [accounts] — connected accounts with email info.
  /// [teamDomains] — teamId → list of email domains from the API.
  static Future<ChannelDefaultSuggestion> suggest({
    required List<TwistChannel> channels,
    required List<TwistAccount> accounts,
    required Map<int, List<String>>? teamDomains,
  }) async {
    if (channels.isEmpty) return const ChannelDefaultSuggestion();

    // Load all priorities from local store
    final priorities = await Priority.get(order: PriorityOrder.nested);
    if (priorities.isEmpty) return const ChannelDefaultSuggestion();

    final defaultPriority = await Priority.getDefault();

    // Phase 1: Map account email domains → team priorities
    final domainToPriority = _buildDomainPriorityMap(
      accounts,
      teamDomains,
      priorities,
      defaultPriority,
    );

    // Flatten channels for scoring
    final flat = _flattenChannels(channels);
    if (flat.isEmpty) return const ChannelDefaultSuggestion();

    // Phase 2: Score each channel
    final scored = <_ScoredChannel>[];
    for (var i = 0; i < flat.length; i++) {
      final channel = flat[i];
      final score = _scoreChannel(
        channel: channel,
        index: i,
        accounts: accounts,
        priorities: priorities,
        domainToPriority: domainToPriority,
      );
      scored.add(score);
    }

    // Phase 3: Select
    final enabledChannels = <String>{};

    // Enable channels with score >= 3
    for (final s in scored) {
      if (s.score >= 3) {
        enabledChannels.add(s.key);
      }
    }

    // Guarantee: enable at least one channel (highest scored)
    if (enabledChannels.isEmpty && scored.isNotEmpty) {
      scored.sort((a, b) => b.score.compareTo(a.score));
      enabledChannels.add(scored.first.key);
    }

    return ChannelDefaultSuggestion(enabledChannels: enabledChannels);
  }

  /// Build a map from email domain → best matching priority.
  static Map<String, Priority> _buildDomainPriorityMap(
    List<TwistAccount> accounts,
    Map<int, List<String>>? teamDomains,
    List<Priority> priorities,
    Priority defaultPriority,
  ) {
    final result = <String, Priority>{};
    if (teamDomains == null) return result;

    // Invert: domain → teamId
    final domainToOrgId = <String, int>{};
    for (final entry in teamDomains.entries) {
      for (final domain in entry.value) {
        domainToOrgId[domain.toLowerCase()] = entry.key;
      }
    }

    // For each account email, find matching org priority
    for (final account in accounts) {
      final domain = _extractDomain(account.email);
      if (domain == null || _personalDomains.contains(domain)) continue;

      final orgId = domainToOrgId[domain];
      if (orgId == null) continue;

      // Find the root priority for this org
      final orgPriority = priorities.firstWhere(
        (p) => p.teamId == orgId && p.root,
        orElse: () =>
            priorities.firstWhere(
              (p) => p.teamId == orgId,
              orElse: () => defaultPriority,
            ),
      );

      result[domain] = orgPriority;
    }

    return result;
  }

  /// Score a channel for auto-enablement.
  static _ScoredChannel _scoreChannel({
    required _FlatChannel channel,
    required int index,
    required List<TwistAccount> accounts,
    required List<Priority> priorities,
    required Map<String, Priority> domainToPriority,
  }) {
    var score = 0;
    Priority? matchedPriority;

    final titleLower = channel.title.toLowerCase();

    // Signal: channel title matches account email (primary calendar)
    for (final account in accounts) {
      if (account.email != null &&
          titleLower == account.email!.toLowerCase()) {
        score += 10;
        // Assign to the org priority for this account's domain
        final domain = _extractDomain(account.email);
        if (domain != null && domainToPriority.containsKey(domain)) {
          matchedPriority = domainToPriority[domain];
        }
        break;
      }
    }

    // Signal: account email domain matched a team
    if (matchedPriority == null) {
      for (final account in accounts) {
        final domain = _extractDomain(account.email);
        if (domain != null && domainToPriority.containsKey(domain)) {
          score += 5;
          matchedPriority = domainToPriority[domain];
          break;
        }
      }
    }

    // Signal: channel title substring-matches a priority name
    if (matchedPriority == null) {
      for (final priority in priorities) {
        final priorityLower = priority.title.toLowerCase();
        if (priorityLower.length >= 3 &&
            titleLower.contains(priorityLower)) {
          score += 3;
          matchedPriority = priority;
          break;
        }
      }
    }

    // Signal: first in list (providers often list primary first)
    if (index == 0) {
      score += 1;
    }

    // Negative: shared/other/group channels
    if (_negativePatterns.hasMatch(titleLower)) {
      score -= 5;
    }

    // Negative: informational channels
    if (_informationalPatterns.hasMatch(titleLower)) {
      score -= 3;
    }

    // Negative: low-value email labels (SENT, DRAFT, app-specific, etc.)
    if (_lowValueEmailPatterns.hasMatch(titleLower)) {
      score -= 5;
    }

    return _ScoredChannel(
      key: channel.key,
      score: score,
      matchedPriority: matchedPriority,
    );
  }

  /// Flatten a channel tree into a list with provider:id keys.
  static List<_FlatChannel> _flattenChannels(List<TwistChannel> channels) {
    final result = <_FlatChannel>[];
    for (final channel in channels) {
      result.add(_FlatChannel(
        key: '${channel.providerKey}:${channel.id}',
        title: channel.title,
        providerKey: channel.providerKey,
      ));
      if (channel.children.isNotEmpty) {
        result.addAll(_flattenChannels(channel.children));
      }
    }
    return result;
  }

  /// Extract email domain (lowercase).
  static String? _extractDomain(String? email) {
    if (email == null) return null;
    final atIndex = email.lastIndexOf('@');
    if (atIndex < 0 || atIndex == email.length - 1) return null;
    return email.substring(atIndex + 1).toLowerCase();
  }
}

class _ScoredChannel {
  final String key;
  final int score;
  final Priority? matchedPriority;

  const _ScoredChannel({
    required this.key,
    required this.score,
    this.matchedPriority,
  });
}

class _FlatChannel {
  final String key;
  final String title;
  final String providerKey;

  const _FlatChannel({
    required this.key,
    required this.title,
    required this.providerKey,
  });
}
