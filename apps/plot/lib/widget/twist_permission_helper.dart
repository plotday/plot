import '../api/twist_permission.dart';

/// Groups permissions by category and returns user-friendly descriptions
class PermissionDescriptions {
  final Map<String, List<String>> categories;

  PermissionDescriptions(this.categories);

  static PermissionDescriptions fromTwistPermissions(
    TwistPermissions permissions,
  ) {
    final Map<String, List<String>> categories = {};

    permissions.permissions.forEach((domain, entities) {
      final categoryName = _getDomainCategoryName(domain);
      final descriptions = _getDescriptionsForDomain(domain, entities);

      if (descriptions.isNotEmpty) {
        categories[categoryName] = descriptions;
      }
    });

    return PermissionDescriptions(categories);
  }

  /// Maps technical domain names to user-friendly category names
  static String _getDomainCategoryName(String domain) {
    switch (domain) {
      case 'plot':
        return 'Plot Data';
      case 'network':
        return 'Internet Access';
      default:
        // Capitalize first letter for unknown domains
        return domain.isEmpty
            ? domain
            : domain[0].toUpperCase() + domain.substring(1);
    }
  }

  /// Generates user-friendly descriptions for entities within a domain
  static List<String> _getDescriptionsForDomain(
    String domain,
    Map<String, List<PermissionFlag>> entities,
  ) {
    if (domain == 'plot') {
      return _getPlotDescriptions(entities);
    } else if (domain == 'network') {
      return _getNetworkDescriptions(entities);
    } else {
      // For unknown domains, show entity names as-is
      return entities.keys.toList();
    }
  }

  /// Maps entity + flags combinations to specific descriptions
  static const _plotPermissionDescriptions = {
    'activity:new|write': 'Create threads with notes',
    'activity:mentioned|read,write,update': 'Respond to mentions in threads',
    'priority|write': 'Create priorities',
    'priority|read,write,update': 'Read, create, and update priorities',
    'contact|read': 'Read contacts',
    'contact|read,write,update': 'Read and update contacts',
  };

  /// Generates descriptions for each entity based on flags
  static List<String> _getPlotDescriptions(
    Map<String, List<PermissionFlag>> entities,
  ) {
    final List<String> descriptions = [];

    entities.forEach((entity, flags) {
      // Create key from entity and sorted flags
      final flagsKey = flags.map((f) => f.name).toList()..sort();
      final key = '$entity|${flagsKey.join(',')}';

      // Try to get specific description, otherwise build generic one
      final description =
          _plotPermissionDescriptions[key] ??
          _buildGenericPlotDescription(entity, flags);

      descriptions.add(description);
    });

    return descriptions;
  }

  /// Builds a generic description for unknown entity/flag combinations
  static String _buildGenericPlotDescription(
    String entity,
    List<PermissionFlag> flags,
  ) {
    // Format entity: "some:thing" → "some thing"
    final friendlyEntity = entity.replaceAll(':', ' ');

    // Build action verbs from flags
    final hasRead = flags.contains(PermissionFlag.read);
    final hasWrite = flags.contains(PermissionFlag.write);
    final hasUpdate = flags.contains(PermissionFlag.update);

    String action;
    if (hasRead && hasWrite && hasUpdate) {
      action = 'Read, create, and update';
    } else if (hasWrite && hasUpdate) {
      action = 'Create and update';
    } else if (hasWrite) {
      action = 'Create';
    } else if (hasUpdate) {
      action = 'Update';
    } else if (hasRead) {
      action = 'Read';
    } else {
      action = 'Access';
    }

    return '$action $friendlyEntity';
  }

  /// Formats network URL patterns for display
  static List<String> _getNetworkDescriptions(
    Map<String, List<PermissionFlag>> entities,
  ) {
    return entities.keys.map((url) => 'Access $url').toList();
  }
}
