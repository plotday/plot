part of 'priorities.dart';

@immutable
class PrioritiesState extends Equatable {
  PrioritiesState({
    List<Priority> priorities = const [],
    List<Role> roles = const [],
    this.root,
    this.archivedFilter = false,
    this.search = '',
  }) : priorities = priorities.isNotEmpty
           ? List.unmodifiable(priorities)
           : priorities,
       roles = roles.isNotEmpty ? List.unmodifiable(roles) : roles;

  final Priority? root;
  final List<Priority> priorities;

  /// The user's roles (the flat, single-level grouping above focuses). Driven
  /// by [Role.watch]; the sidebar groups focuses by [Priority.roleId] under
  /// these. Empty until the first roles sync lands.
  final List<Role> roles;

  /// Archived filter state: false = active only, null = show all
  final bool? archivedFilter;

  final String search;

  PrioritiesState copyWith({
    List<Priority>? priorities,
    List<Role>? roles,
    Priority? root,
    bool? archivedFilter,
    String? search,
  }) {
    return PrioritiesState(
      priorities: priorities ?? this.priorities,
      roles: roles ?? this.roles,
      root: root ?? this.root,
      archivedFilter: archivedFilter ?? this.archivedFilter,
      search: search ?? this.search,
    );
  }

  /// Non-archived focuses filed under [roleId], sorted purely by order then
  /// creation time. Mirrors the sidebar ordering ([Order.between] writes the
  /// `order` column). The Inbox and FYI are ordinary focuses that default to
  /// the bottom two via large server-seeded sentinel orders, not a sort pin.
  List<Priority> focusesForRole(RoleId roleId) {
    final list =
        priorities
            .where((p) => p.roleId == roleId && p.archivedAt == null)
            .toList()
          ..sort((a, b) {
            final c = a.order.value.compareTo(b.order.value);
            return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
          });
    return list;
  }

  /// Live roles sorted for the sidebar — by [Role.order] (nulls sort first as
  /// 0), then creation time. [Role.order] is nullable, so compare its numeric
  /// value rather than the [Order] wrapper.
  List<Role> get sortedRoles {
    final live = roles.where((r) => r.archivedAt == null).toList()
      ..sort((a, b) {
        final c = (a.order?.value ?? 0).compareTo(b.order?.value ?? 0);
        return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
      });
    return live;
  }

  @override
  List<Object?> get props => [priorities, roles, root, archivedFilter, search];
}
