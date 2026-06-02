/// Builds the channel breadcrumb shown in a thread's header for threads whose
/// primary link is channel-sharing — e.g. `Acme Co › #general` (Slack) or
/// `Acme Co › Project X` (Linear).
///
/// [workspace] is the connection/workspace name (from the link's twist
/// instance); [channel] is the channel/project title. Either may be absent
/// (a legacy link without a channel, or a cache miss): whichever parts
/// resolve are shown, the ` › ` separator appears only when both are present,
/// and the breadcrumb is null when neither resolves.
String? formatChannelBreadcrumb({String? workspace, String? channel}) {
  final w = workspace?.trim();
  final c = channel?.trim();
  final hasWorkspace = w != null && w.isNotEmpty;
  final hasChannel = c != null && c.isNotEmpty;

  if (hasWorkspace && hasChannel) return '$w › $c';
  if (hasChannel) return c;
  if (hasWorkspace) return w;
  return null;
}
