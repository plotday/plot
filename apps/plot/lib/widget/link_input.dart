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

/// A modal for searching or pasting a link, using the standard SelectModal pattern.
class LinkModal {
  LinkModal._();

  /// Opens the link modal and returns the result.
  static Future<LinkModalResult?> open(BuildContext context) async {
    // Cache for URL metadata fetched during search
    String? fetchedTitle;
    String? fetchedFavicon;

    // Enabled channels whose link types declare a `compose` block become
    // "Create new …" picker entries. Loaded on first items() call.
    List<CreateTarget>? createTargets;

    final result = await SelectModal.open<_LinkItem>(
      context,
      items: (search) async {
        createTargets ??= await loadCreateTargets();
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
        }

        return groups;
      },
      itemBuilder: (item, isLoading) {
        if (item.isCreateExternal) {
          return createTargetTile(context, item.createTarget!);
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
      return LinkModalResult.create(item.createTarget!.toUserAction());
    }
    if (item.isCreate) {
      return LinkModalResult.link(
        url: item.url!,
        title: item.title,
        favicon: item.favicon,
      );
    }

    final link = item.linkResult!.link;
    // Links that point at a Plot thread navigate to it; resolve the Thread
    // lazily here (instead of eagerly for every Recent row at modal-open
    // time) so the modal opens immediately. Fall through to the URL form
    // if the thread has been deleted locally.
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
  final CreateTarget? createTarget;
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

  _LinkSearchResult({required this.link});
}
