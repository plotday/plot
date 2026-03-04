/// Represents a syncable entity with its dependencies and sync operations.
///
/// Each entity has:
/// - A debug name for logging
/// - A list of dependencies (other SyncEntity instances)
/// - Push and pull functions
/// - Optional group parent for related entities
class SyncEntity {
  /// Debug name for logging and error messages
  final String debugName;

  /// List of entities this entity depends on
  /// For pull: dependencies are pulled first (parent → child)
  /// For push: dependencies are pushed last (child → parent)
  final List<SyncEntity> dependsOn;

  /// Function to push local changes to server
  /// Returns true if push succeeded, false otherwise
  final Future<bool> Function() pushFn;

  /// Function to pull remote changes from server
  final Future<void> Function() pullFn;

  /// Optional group parent for related entities that sync together
  /// e.g., Schedules and ThreadTags have Thread as groupParent
  final SyncEntity? groupParent;

  const SyncEntity({
    required this.debugName,
    this.dependsOn = const [],
    required this.pushFn,
    required this.pullFn,
    this.groupParent,
  });

  @override
  String toString() => 'SyncEntity($debugName)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncEntity && debugName == other.debugName;

  @override
  int get hashCode => debugName.hashCode;
}
