/**
 * Validates AI provider API keys with a lightweight API call.
 */

type AiProvider = "openai" | "anthropic" | "google" | "custom";

type ValidationResult = {
  valid: boolean;
  error?: string;
};

/**
 * Validate an AI API key by making a lightweight request to the provider.
 * 200 = valid, 401/403 = invalid key, other = validation error (key still saved with warning).
 *
 * @param baseUrl - Required for custom providers. The base URL of the OpenAI-compatible endpoint.
 */
export async function validateAiKey(
  provider: AiProvider,
  key: string,
  baseUrl?: string
): Promise<ValidationResult> {
  try {
    const response = await fetchProvider(provider, key, baseUrl);

    if (response.ok) {
      return { valid: true };
    }

    if (response.status === 401 || response.status === 403) {
      return { valid: false, error: "Invalid API key" };
    }

    // Other errors (rate limit, server error, etc.) — don't block saving
    return {
      valid: true,
      error: `Validation returned status ${response.status} — key saved but may not work`,
    };
  } catch (err) {
    // Network error — don't block saving
    return {
      valid: true,
      error: `Could not validate key: ${err instanceof Error ? err.message : "unknown error"}`,
    };
  }
}

async function fetchProvider(
  provider: AiProvider,
  key: string,
  baseUrl?: string
): Promise<Response> {
  switch (provider) {
    case "openai":
      return fetch("https://api.openai.com/v1/models", {
        method: "GET",
        headers: { Authorization: `Bearer ${key}` },
      });

    case "anthropic":
      return fetch("https://api.anthropic.com/v1/models", {
        method: "GET",
        headers: {
          "x-api-key": key,
          "anthropic-version": "2023-06-01",
        },
      });

    case "google":
      return fetch(
        `https://generativelanguage.googleapis.com/v1beta/models?key=${encodeURIComponent(key)}`,
        { method: "GET" }
      );

    case "custom": {
      if (!baseUrl) {
        throw new Error("Base URL is required for custom provider validation");
      }
      // Normalize: strip trailing slash
      const url = baseUrl.replace(/\/+$/, "");
      return fetch(`${url}/models`, {
        method: "GET",
        headers: { Authorization: `Bearer ${key}` },
      });
    }
  }
}
