import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/url_title.dart' show fetchUrlMetadata;
import 'package:plot/widget/widget.dart' hide Link;

/// Result from the link modal: an existing thread to attach as a reference,
/// or a plain URL link to attach.
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
        final groups = <SelectGroup<_LinkItem>>[];

        if (text.isEmpty) {
          final recentLinks = await Link.listRecent();
          if (recentLinks.isNotEmpty) {
            groups.add(SelectGroup(
              title: 'Recent',
              items: recentLinks
                  .map((l) => _LinkItem.existing(_LinkSearchResult(link: l)))
                  .toList(),
            ));
          }
          return groups;
        }

        final isUrl = _checkIsUrl(text);

        if (isUrl) {
          final links = await Link.findBySourceUrl(text);
          if (links.isNotEmpty) {
            groups.add(SelectGroup(
              title: null,
              items: links
                  .map((l) => _LinkItem.existing(_LinkSearchResult(link: l)))
                  .toList(),
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
          if (links.isNotEmpty) {
            groups.add(SelectGroup(
              title: null,
              items: links
                  .map((l) => _LinkItem.existing(_LinkSearchResult(link: l)))
                  .toList(),
            ));
          }

          // Surface Plot threads (incl. notes-only threads with no Link row),
          // which only appear via remote search. Network-backed; offline this
          // silently yields nothing. Network failures are expected here, so
          // swallow them rather than reporting to error tracking.
          List<Thread> threads = const [];
          try {
            threads = await Thread.searchRemote(text, archived: false);
          } catch (_) {
            threads = const [];
          }
          if (threads.isNotEmpty) {
            groups.add(SelectGroup(
              title: 'Threads',
              items: threads.map((t) => _LinkItem.thread(t)).toList(),
            ));
          }
        }

        return groups;
      },
      itemBuilder: (item, isLoading) {
        if (item.isThread) {
          return ListTile(
            icon: PlotIcon.inbox,
            title: item.thread!.title ?? 'Untitled',
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
    if (item.isThread) {
      return LinkModalResult.thread(item.thread!);
    }
    if (item.isCreate) {
      return LinkModalResult.link(
        url: item.url!,
        title: item.title,
        favicon: item.favicon,
      );
    }

    final link = item.linkResult!.link;
    // Links that point at a Plot thread attach a reference to that thread;
    // resolve the Thread lazily here (instead of eagerly for every Recent row
    // at modal-open time) so the modal opens immediately. Fall through to the
    // URL form if the thread has been deleted locally.
    if (link.threadId != null) {
      try {
        final thread = await Thread.getOne(link.threadId!);
        return LinkModalResult.thread(thread);
      } catch (_) {
        // Thread not found — treat as a plain URL.
      }
    }
    if (link.sourceUrl != null) {
      return LinkModalResult.link(
        url: link.sourceUrl!,
        title: link.title,
        favicon: link.logo,
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
}

/// Internal item type for the SelectModal.
class _LinkItem {
  final _LinkSearchResult? linkResult;
  final Thread? thread;
  final String? url;
  final String? title;
  final String? favicon;

  _LinkItem.existing(this.linkResult)
      : thread = null,
        url = null,
        title = null,
        favicon = null;

  _LinkItem.thread(this.thread)
      : linkResult = null,
        url = null,
        title = null,
        favicon = null;

  _LinkItem.create({required this.url, this.title, this.favicon})
      : linkResult = null,
        thread = null;

  bool get isThread => thread != null;
  bool get isCreate => linkResult == null && thread == null;
}

class _LinkSearchResult {
  final Link link;

  _LinkSearchResult({required this.link});
}
