/**
 * Importance bands. The LLM (and the deterministic failure-path fallback) pick
 * one of these four labels; `bandToImportance` maps to the 0..100 column the
 * notification gate (`importance >= 50 OR urgent`) and the feed ordering read.
 *
 * Why an ordinal, not a 0..100 number: a 70B model asked for a calibrated float
 * anchors on the example value and refuses the low end, so in prod importance
 * collapsed to ~50 (only 2 rows <50 in 21 days) and the suppression path never
 * fired. A four-way label is a task the model performs reliably.
 */
export type ImportanceBand = "suppress" | "low" | "normal" | "elevated";

const BAND_TO_IMPORTANCE: Record<ImportanceBand, number> = {
  suppress: 15, // below gate — no push/email/badge, sorts lowest
  low: 45, // below gate — exists, won't surface proactively
  normal: 60, // above gate — ordinary mail the recipient wants surfaced
  elevated: 85, // above gate — personal/direct/time-sensitive, sorts high
};

export function bandToImportance(band: ImportanceBand): number {
  return BAND_TO_IMPORTANCE[band];
}

export function parseBand(raw: unknown): ImportanceBand | null {
  if (typeof raw !== "string") return null;
  const v = raw.trim().toLowerCase();
  return v === "suppress" || v === "low" || v === "normal" || v === "elevated"
    ? v
    : null;
}

/**
 * Signals available without the LLM. Used only on the failure path (AI disabled,
 * quota exhausted, parse failure) — NOT to override a band the LLM returned.
 */
export type FallbackSignals = {
  facetAutomation: "human" | "automated" | null;
  facetReach: "direct" | "list" | null;
  facetFormat: string | null;
  senderEmailAutomated: boolean;
  senderKnown: boolean;
};

/**
 * Deterministic band when the LLM produced no usable band. Obvious bulk mail
 * stops notifying even on the failure path; everything else defaults to normal
 * (surfaces), preserving today's notify-by-default behaviour for real mail.
 */
export function fallbackBand(s: FallbackSignals): ImportanceBand {
  const automatedList = s.facetAutomation === "automated" && s.facetReach === "list";
  const promo = s.facetFormat === "promotion";
  const coldNoReply = s.senderEmailAutomated && !s.senderKnown;
  return automatedList || promo || coldNoReply ? "low" : "normal";
}

/** Prompt fragment: the four-band rubric. Keyed on the injected feature block. */
export const IMPORTANCE_RUBRIC = `importance — pick exactly one band:
- "suppress": promotional / mass-distribution / automated bulk the recipient consistently ignores. Strong signals: automation=automated AND reach=list; or historical read rate below ~15% over several prior threads; or a no-reply sender the recipient has no history with.
- "low": automated or FYI mail that isn't junk but needs no proactive surfacing (newsletters they open occasionally, non-skip receipts).
- "normal": ordinary correspondence the recipient would want surfaced proactively. This is the default when nothing points up or down.
- "elevated": personal or direct messages from known contacts, direct asks, time-sensitive items. Signals: high historical read/reply rate, reach=direct, a known sender.
Anything you mark urgent or active MUST be "normal" or "elevated".`;

