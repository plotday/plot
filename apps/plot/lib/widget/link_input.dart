import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/url_title.dart' show fetchUrlMetadata;
import 'package:plot/widget/widget.dart' hide Link;

/// Result from the link modal: an existing thread to navigate to, a link to
/// attach, or a request to create a new external item via a connector.
class LinkModalResult {
  final String? url;
  final String? title;
  final String? favicon;
  final Thread? existingThread;
  final CreateLinkUserAction? createAction;

  LinkModalResult.link({
    required String this.url,
    this.title,
    this.favicon,
  })  : existingThread = null,
        createAction = null;

  LinkModalResult.thread(Thread this.existingThread)
      : url = null,
        title = null,
        favicon = null,
        createAction = null;

  LinkModalResult.create(CreateLinkUserAction this.createAction)
      : url = null,
        title = null,
        favicon = null,
        existingThread = null;

  bool get isThread => existingThread != null;
  bool get isLink => url != null;
  bool get isCreateAction => createAction != null;
}

/// A connector link type the current user can create from Plot.
class _CreateTarget {
  final TwistInstance twist;
  final Channel channel;
  final LinkTypeConfig linkType;
  final LinkStatus defaultStatus;
  final String connectorName;
  final String? accountName;

  _CreateTarget({
    required this.twist,
    required this.channel,
    required this.linkType,
    required this.defaultStatus,
  })  : connectorName = CreateLinkUserAction.parseTwistName(twist.name).connectorName,
        accountName = CreateLinkUserAction.parseTwistName(twist.name).accountName;

  String get title =>
      'Create new $connectorName ${linkType.label.toLowerCase()}';
  String get subtitle =>
      accountName == null ? channel.title : '${channel.title} ($accountName)';
  String get searchText =>
      '$connectorName ${linkType.label} ${channel.title} ${accountName ?? ''}'
          .toLowerCase();
}

/// A modal for searching or pasting a link, using the standard SelectModal pattern.
class LinkModal {
  LinkModal._();

  /// Opens the link modal and returns the result.
  static Future<LinkModalResult?> open(BuildContext context) async {
    // Cache for URL metadata fetched during search
    String? fetchedTitle;
    String? fetchedFavicon;

    // Enabled channels whose link types declare a `createDefault` status
    // become "Create new …" picker entries. Loaded on first items() call.
    List<_CreateTarget>? createTargets;

    final result = await SelectModal.open<_LinkItem>(
      context,
      items: (search) async {
        createTargets ??= await _loadCreateTargets();
        final text = search?.trim() ?? '';
        final groups = <SelectGroup<_LinkItem>>[];

        if (text.isEmpty) {
          if (createTargets!.isNotEmpty) {
            groups.add(SelectGroup(
              title: 'Create new',
              items: createTargets!
                  .map((t) => _LinkItem.createExternal(t))
                  .toList(),
            ));
          }
          final recentLinks = await Link.listRecent();
          final recentResults = await _loadThreadsForLinks(recentLinks);
          if (recentResults.isNotEmpty) {
            groups.add(SelectGroup(
              title: 'Recent',
              items: recentResults
                  .map((r) => _LinkItem.existing(r))
                  .toList(),
            ));
          }
          return groups;
        }

        // Include any matching create targets above other results.
        final matchingCreate = createTargets!
            .where((t) => t.searchText.contains(text.toLowerCase()))
            .toList();
        if (matchingCreate.isNotEmpty) {
          groups.add(SelectGroup(
            title: 'Create new',
            items: matchingCreate
                .map((t) => _LinkItem.createExternal(t))
                .toList(),
          ));
        }

        final isUrl = _checkIsUrl(text);

        if (isUrl) {
          final links = await Link.findBySourceUrl(text);
          final results = await _loadThreadsForLinks(links);
          if (results.isNotEmpty) {
            groups.add(SelectGroup(
              title: null,
              items: results.map((r) => _LinkItem.existing(r)).toList(),
            ));
          } else {
            // Fetch metadata for the URL
            final metadata = await fetchUrlMetadata(text);
            fetchedTitle = metadata.title;
            fetchedFavicon = metadata.favicon;
            groups.add(SelectGroup(
              title: null,
              items: [
                _LinkItem.create(
                  url: text,
                  title: fetchedTitle,
                  favicon: fetchedFavicon,
                ),
              ],
            ));
          }
        } else {
          final links = await Link.searchByTitle(text);
          final results = await _loadThreadsForLinks(links);
          if (results.isNotEmpty) {
            groups.add(SelectGroup(
              title: null,
              items: results.map((r) => _LinkItem.existing(r)).toList(),
            ));
          }
        }

        return groups;
      },
      itemBuilder: (item, isLoading) {
        if (item.isCreateExternal) {
          final target = item.createTarget!;
          final isDark = context.read<ThemeBloc>().isDarkMode(context);
          final logo = isDark
              ? (target.linkType.logoDark ?? target.linkType.logo)
              : target.linkType.logo;
          return ListTile(
            leadingBuilder: logo != null
                ? (_, _) => Builder(
                    builder: (context) => Padding(
                      padding: EdgeInsets.only(
                        left: context.theme.spacing.lg,
                        right: 8,
                      ),
                      child: LogoImage(
                        url: logo,
                        size: 16,
                        fallback: const Icon(PlotIcon.add, size: 16),
                      ),
                    ),
                  )
                : null,
            icon: logo == null ? PlotIcon.add : null,
            title: target.title,
            subtitle: target.subtitle,
          );
        }
        if (item.isCreate) {
          return ListTile(
            icon: item.favicon == null ? PlotIcon.add : null,
            leadingBuilder: item.favicon != null
                ? (_, _) => Builder(
                    builder: (context) => Padding(
                      padding: EdgeInsets.only(
                        left: context.theme.spacing.lg,
                        right: 8,
                      ),
                      child: LogoImage(
                        url: item.favicon!,
                        size: 16,
                        fallback: const Icon(PlotIcon.add, size: 16),
                      ),
                    ),
                  )
                : null,
            title: item.title ?? item.url!,
            subtitle: item.title != null ? item.url : null,
          );
        }

        final link = item.linkResult!.link;
        final logoUrl = link.logoForBrightness(Brightness.light);
        return ListTile(
          leadingBuilder: logoUrl != null
              ? (_, _) => Builder(
                  builder: (context) => Padding(
                    padding: EdgeInsets.only(
                      left: context.theme.spacing.lg,
                      right: 8,
                    ),
                    child: LogoImage(
                      url: logoUrl,
                      size: 16,
                      fallback: const Icon(PlotIcon.link, size: 16),
                    ),
                  ),
                )
              : null,
          icon: logoUrl == null ? PlotIcon.link : null,
          title: link.title ?? link.sourceUrl ?? 'Link',
        );
      },
      prompt: 'Search or paste a link',
      emptyMessage: 'No links found',
      showFilter: true,
    );

    if (!result.present) return null;

    final item = result.value;
    if (item.isCreateExternal) {
      final target = item.createTarget!;
      return LinkModalResult.create(
        CreateLinkUserAction(
          twistInstanceId: target.twist.id.toString(),
          channelId: target.channel.channelId,
          linkType: target.linkType.type,
          status: target.defaultStatus.status,
          connectorName: target.connectorName,
          linkTypeLabel: target.linkType.label,
          channelName: target.channel.title,
          accountName: target.accountName,
          logo: target.linkType.logo,
          logoDark: target.linkType.logoDark,
        ),
      );
    }
    if (item.isCreate) {
      return LinkModalResult.link(
        url: item.url!,
        title: item.title,
        favicon: item.favicon,
      );
    }

    final linkResult = item.linkResult!;
    if (linkResult.thread != null) {
      return LinkModalResult.thread(linkResult.thread!);
    } else if (linkResult.link.sourceUrl != null) {
      return LinkModalResult.link(
        url: linkResult.link.sourceUrl!,
        title: linkResult.link.title,
        favicon: linkResult.link.logo,
      );
    }

    return null;
  }

  /// Build the list of "Create new X" targets from enabled channels whose
  /// link types opt in to Plot-initiated creation.
  ///
  /// A link type opts in by declaring a status with `createDefault: true`.
  /// Channel-level linkTypes (dynamic, per-team) take precedence for the
  /// picker's status list, but if the channel-level config has no
  /// `createDefault` status (typical for connections set up before a
  /// connector added the marker), the twist-level linkTypes are consulted
  /// for a default. The connector's `onCreateLink` must accept the
  /// resulting status id (Linear, for example, resolves a category like
  /// "unstarted" to a team-specific state UUID).
  static Future<List<_CreateTarget>> _loadCreateTargets() async {
    final channels = await Channel.getAllEnabled();
    final result = <_CreateTarget>[];
    for (final channel in channels) {
      final twist = TwistInstance.fromCache(channel.twistInstanceId);
      if (twist == null) continue;
      final channelConfigs = channel.parsedLinkTypes;
      final twistConfigs = twist.parsedLinkTypes;
      if (channelConfigs == null && twistConfigs == null) continue;

      final primaryConfigs = channelConfigs ?? twistConfigs!;
      for (final linkType in primaryConfigs) {
        var defaultStatus = linkType.statuses
            ?.where((s) => s.createDefault)
            .firstOrNull;
        // Fall back to twist-level createDefault when the channel's own
        // linkTypes are stale (saved before the connector declared
        // createDefault).
        if (defaultStatus == null && channelConfigs != null) {
          defaultStatus = twistConfigs
              ?.where((c) => c.type == linkType.type)
              .firstOrNull
              ?.statuses
              ?.where((s) => s.createDefault)
              .firstOrNull;
        }
        if (defaultStatus == null) continue;
        result.add(_CreateTarget(
          twist: twist,
          channel: channel,
          linkType: linkType,
          defaultStatus: defaultStatus,
        ));
      }
    }
    return result;
  }

  static bool _checkIsUrl(String text) {
    final uri = Uri.tryParse(text);
    return uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }

  static Future<List<_LinkSearchResult>> _loadThreadsForLinks(
    List<Link> links,
  ) async {
    final results = <_LinkSearchResult>[];
    for (final link in links) {
      if (link.threadId == null) {
        results.add(_LinkSearchResult(link: link, thread: null));
        continue;
      }
      try {
        final thread = await Thread.getOne(link.threadId!);
        results.add(_LinkSearchResult(link: link, thread: thread));
      } catch (_) {
        // Thread not found — skip
      }
    }
    return results;
  }
}

/// Internal item type for the SelectModal.
class _LinkItem {
  final _LinkSearchResult? linkResult;
  final _CreateTarget? createTarget;
  final String? url;
  final String? title;
  final String? favicon;

  _LinkItem.existing(this.linkResult)
      : createTarget = null,
        url = null,
        title = null,
        favicon = null;

  _LinkItem.create({required this.url, this.title, this.favicon})
      : linkResult = null,
        createTarget = null;

  _LinkItem.createExternal(this.createTarget)
      : linkResult = null,
        url = null,
        title = null,
        favicon = null;

  bool get isCreate => linkResult == null && createTarget == null;
  bool get isCreateExternal => createTarget != null;
}

class _LinkSearchResult {
  final Link link;
  final Thread? thread;

  _LinkSearchResult({required this.link, this.thread});
}
