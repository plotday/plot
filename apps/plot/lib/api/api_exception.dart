/// Exception thrown by API calls with structured error information
class ApiException implements Exception {
  final int statusCode;
  final String endpoint;
  final String title;
  final String description;

  /// PostgreSQL error code from the API (e.g. '42501', '23503')
  final String? pgCode;

  /// Machine-readable error code from the API (e.g. 'plan_limit_exceeded')
  final String? code;

  /// The type of limit that was exceeded (e.g. 'connections', 'twists')
  final String? limitType;

  /// Whether the limit applies to a team (true) or personal account (false)
  final bool? isTeam;

  /// Whether the current user is an admin of the affected team
  final bool? isAdmin;

  /// The team ID associated with the limit, if applicable
  final String? teamId;

  /// The reason the limit was exceeded (e.g. 'addon_required', 'connection_limit')
  final String? reason;

  /// The automation capacity weight of the candidate twist that would be
  /// installed (populated when reason == 'twist_addon_required').
  final int? candidateWeight;

  /// The Stripe checkout URL returned when reason == 'needs_card'.
  final String? checkoutUrl;

  ApiException({
    required this.statusCode,
    required this.endpoint,
    required this.title,
    required this.description,
    this.pgCode,
    this.code,
    this.limitType,
    this.isTeam,
    this.isAdmin,
    this.teamId,
    this.reason,
    this.candidateWeight,
    this.checkoutUrl,
  });

  /// Returns true if this exception represents a plan limit being exceeded
  bool get isPlanLimitExceeded => code == 'plan_limit_exceeded';

  /// Returns true if this exception indicates an add-on connection is required
  bool get isAddonRequired =>
      code == 'plan_limit_exceeded' && reason == 'addon_required';

  /// Returns true if this exception indicates a twist add-on is required
  bool get isTwistAddonRequired =>
      code == 'plan_limit_exceeded' && reason == 'twist_addon_required';

  /// Returns true when the team's shared capacity block (connections + twists)
  /// is full. Admins should open web team billing to buy a 50-slot block;
  /// non-admin members should be told to ask their admin.
  bool get isTeamBlockRequired =>
      code == 'plan_limit_exceeded' && reason == 'team_block_required';

  /// Returns true when the user consented to an add-on charge but has no
  /// payment method on file (status 402, reason == 'needs_card').
  bool get needsCard => statusCode == 402 && reason == 'needs_card';

  @override
  String toString() =>
      'ApiException($statusCode $endpoint): $title - $description'
      '${pgCode != null ? ' [pg:$pgCode]' : ''}'
      '${code != null ? ' [code:$code]' : ''}';
}
