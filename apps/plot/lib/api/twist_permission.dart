/// Permission flags that can be combined for a given domain/entity
enum PermissionFlag {
  read,
  write,
  update,
  use;

  static PermissionFlag fromString(String value) {
    switch (value.toLowerCase()) {
      case 'read':
        return PermissionFlag.read;
      case 'write':
        return PermissionFlag.write;
      case 'update':
        return PermissionFlag.update;
      case 'use':
        return PermissionFlag.use;
      default:
        throw ArgumentError('Unknown permission flag: $value');
    }
  }

  String toJson() => name;
}

/// Agent permissions with nested structure
/// Format: { domain: { entity: flags[] } }
/// Example: { "network": { "https://api.example.com/*": ["use"] } }
class TwistPermissions {
  final Map<String, Map<String, List<PermissionFlag>>> permissions;

  const TwistPermissions(this.permissions);

  factory TwistPermissions.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const TwistPermissions({});
    }

    final result = <String, Map<String, List<PermissionFlag>>>{};

    for (final domainEntry in json.entries) {
      final domain = domainEntry.key;
      final entities = domainEntry.value as Map<String, dynamic>;

      final entityMap = <String, List<PermissionFlag>>{};
      for (final entityEntry in entities.entries) {
        final entity = entityEntry.key;
        final flagsList = entityEntry.value as List<dynamic>;

        final flags = flagsList
            .map((flag) => PermissionFlag.fromString(flag as String))
            .toList();

        entityMap[entity] = flags;
      }

      result[domain] = entityMap;
    }

    return TwistPermissions(result);
  }

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{};

    for (final domainEntry in permissions.entries) {
      final domain = domainEntry.key;
      final entities = domainEntry.value;

      final entityMap = <String, dynamic>{};
      for (final entityEntry in entities.entries) {
        final entity = entityEntry.key;
        final flags = entityEntry.value;

        entityMap[entity] = flags.map((f) => f.toJson()).toList();
      }

      result[domain] = entityMap;
    }

    return result;
  }

  /// Get permissions for a specific domain
  Map<String, List<PermissionFlag>>? forDomain(String domain) {
    return permissions[domain];
  }

  /// Get permissions for a specific domain and entity
  List<PermissionFlag>? forEntity(String domain, String entity) {
    return permissions[domain]?[entity];
  }

  /// Check if a specific flag is granted for a domain and entity
  bool hasPermission(String domain, String entity, PermissionFlag flag) {
    return permissions[domain]?[entity]?.contains(flag) ?? false;
  }

  /// Get a human-readable description of permissions for a domain
  String getDisplayText(String domain) {
    final domainPerms = permissions[domain];
    if (domainPerms == null || domainPerms.isEmpty) {
      return 'No permissions';
    }

    final entries = domainPerms.entries.map((e) {
      final entity = e.key;
      final flags = e.value.map((f) => f.name).join(', ');
      return '$entity: $flags';
    }).join('\n');

    return entries;
  }
}
