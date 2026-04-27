import 'package:flutter/widgets.dart';
import 'package:super_editor/super_editor.dart';

/// Custom [ComponentBuilder] for image nodes that guards against unsupported
/// URL schemes (e.g. `cid:` content-id references found in email-derived
/// markdown), which would otherwise cause [Image.network] to throw an
/// [ArgumentError] from `_HttpClient._openUrl` when no host is present.
class PlotImageComponentBuilder implements ComponentBuilder {
  const PlotImageComponentBuilder();

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    return const ImageComponentBuilder().createViewModel(document, node);
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! ImageComponentViewModel) {
      return null;
    }

    return ImageComponent(
      componentKey: componentContext.componentKey,
      imageUrl: componentViewModel.imageUrl,
      expectedSize: componentViewModel.expectedSize,
      selection: componentViewModel.selection?.nodeSelection
          as UpstreamDownstreamNodeSelection?,
      selectionColor: componentViewModel.selectionColor,
      opacity: componentViewModel.opacity,
      imageBuilder: _buildImage,
    );
  }

  Widget _buildImage(BuildContext context, String imageUrl) {
    final uri = Uri.tryParse(imageUrl);
    final isNetworkUrl =
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    if (!isNetworkUrl) {
      return const SizedBox.shrink();
    }
    return Image.network(
      imageUrl,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
    );
  }
}
