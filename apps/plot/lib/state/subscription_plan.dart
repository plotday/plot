/// Pure plan-tier policy used to decide whether a subscription change is an
/// upgrade worth a toast, and what to say. No I/O and no BuildContext so it is
/// trivially unit-testable.
///
/// `effectivePlan` values come from the server: 'free' | 'core' | 'pro' | 'team'.
/// `pro` and `team` are co-top: they grant equivalent capability (unlimited /
/// pooled connections incl. Pro connectors), so a lateral pro<->team move is
/// not an "upgrade".
library;

/// Rank of an effective plan. Higher = more entitlement.
/// free(0) < core(1) < pro(2) == team(2). Unknown/empty is treated as free.
int planRank(String plan) {
  switch (plan) {
    case 'core':
      return 1;
    case 'pro':
    case 'team':
      return 2;
    default:
      return 0;
  }
}

/// Message to toast when the effective plan increases, or null for no toast.
///
/// Fires only when [newRank] > [prevRank]. Names the plan for the purchasable
/// tiers (core/pro). For `team` it uses neutral wording — we never surface
/// "Team" as a buyable plan anywhere in the app.
String? planUpToastMessage({
  required int prevRank,
  required int newRank,
  required String newEffectivePlan,
}) {
  if (newRank <= prevRank) return null;
  switch (newEffectivePlan) {
    case 'core':
      return "You're now on Plot Core";
    case 'pro':
      return "You're now on Plot Pro";
    case 'team':
      return 'You can now add more connections';
    default:
      return null;
  }
}
