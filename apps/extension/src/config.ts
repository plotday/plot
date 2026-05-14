// Production endpoints by default. Set PLOT_API_BASE / PLOT_APP_BASE via WXT
// env (.env.local in apps/extension) to point a local build at a dev worker.
const apiBase =
  (import.meta as any).env?.WXT_PLOT_API_BASE ??
  (import.meta as any).env?.PLOT_API_BASE ??
  "https://api.plot.day";

const appBase =
  (import.meta as any).env?.WXT_PLOT_APP_BASE ??
  (import.meta as any).env?.PLOT_APP_BASE ??
  "https://app.plot.day";

export const PLOT_API_BASE: string = apiBase;
export const PLOT_APP_BASE: string = appBase;
