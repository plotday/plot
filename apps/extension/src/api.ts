import { PLOT_API_BASE } from "./config";

export type CaptureResult = {
  thread_id: string;
  short_id: string;
  created: boolean;
};

export class AuthRequiredError extends Error {
  constructor(message = "Auth required") {
    super(message);
    this.name = "AuthRequiredError";
  }
}

export async function capturePage(
  token: string,
  input: { source_url: string; title?: string; preview?: string }
): Promise<CaptureResult> {
  const response = await fetch(`${PLOT_API_BASE}/app/sync/capture`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(input),
  });

  if (response.status === 401) {
    throw new AuthRequiredError();
  }
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new Error(`Capture failed (${response.status}): ${text}`);
  }
  return (await response.json()) as CaptureResult;
}
