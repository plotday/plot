/**
 * Wilson score interval for a binomial proportion (default z = 1.96, 95%).
 * n = 0 returns the uninformative [0, 1].
 */
export function wilsonInterval(successes: number, n: number, z = 1.96): { lo: number; hi: number } {
  if (n === 0) return { lo: 0, hi: 1 };
  const p = successes / n;
  const z2 = z * z;
  const denom = 1 + z2 / n;
  const center = (p + z2 / (2 * n)) / denom;
  const half = (z * Math.sqrt((p * (1 - p)) / n + z2 / (4 * n * n))) / denom;
  return { lo: Math.max(0, center - half), hi: Math.min(1, center + half) };
}

/**
 * Two-sided exact McNemar test on the discordant pair counts (b, c):
 * p = min(1, 2 * P(X <= min(b,c))) for X ~ Binomial(b + c, 0.5).
 * b + c = 0 (no discordant pairs) returns 1 — no evidence of difference.
 */
export function mcnemarExact(b: number, c: number): number {
  const n = b + c;
  if (n === 0) return 1;
  const k = Math.min(b, c);
  let cum = 0;
  for (let i = 0; i <= k; i++) cum += binomPmf(n, i);
  return Math.min(1, 2 * cum);
}

function binomPmf(n: number, k: number): number {
  let logC = 0;
  for (let i = 1; i <= k; i++) logC += Math.log(n - k + i) - Math.log(i);
  return Math.exp(logC + n * Math.log(0.5));
}
