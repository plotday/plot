import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/url_title.dart' show fetchUrlMetadata;
import 'package:plot/widget/widget.dart' hide Link;

/// Result from the link modal: either link data or an existing thread to navigate to.
class LinkModalResult {
  final String? url;
  final String? title;
  final String? favicon;
  final Thread? existingThread;

  LinkModalResult.link({
    required String this.url,
    this.title,
    this.favicon,
  }) : existingThread = null;

  LinkModalResult.thread(Thread this.existingThread)
      : url = null,
        title = null,
        favicon = null;

  bool get isThread => existingThread != null;
  bool get isLink => url != null;
}

/// A modal for searching or pasting a link, using the standard SelectModal pattern.
class LinkModal {
  LinkModal._();

  /// Opens the link modal and returns the result.
  static Future<LinkModalResult?> open(BuildContext context) async {
    // Cache for URL metadata fetched during search
    String? fetchedTitle;
    String? fetchedFavicon;

    final result = await SelectModal.open<_LinkItem>(
      context,
      items: (search) async {
        final text = search?.trim() ?? '';
        if (text.isEmpty) return [];

        final isUrl = _checkIsUrl(text);
        final groups = <SelectGroup<_LinkItem>>[];

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
  final String? url;
  final String? title;
  final String? favicon;

  _LinkItem.existing(this.linkResult)
      : url = null,
        title = null,
        favicon = null;

  _LinkItem.create({required this.url, this.title, this.favicon})
      : linkResult = null;

  bool get isCreate => linkResult == null;
}

class _LinkSearchResult {
  final Link link;
  final Thread? thread;

  _LinkSearchResult({required this.link, this.thread});
}
