import { BaseTransport } from "@amplitude/analytics-core";
import type { Payload, Response, Transport } from "@amplitude/analytics-types";

// Workers only have Fetch, not HTTP, so we need a custom transport
export class Fetch extends BaseTransport implements Transport {
  constructor() {
    super();
  }
  send(serverUrl: string, payload: Payload): Promise<Response | null> {
    return new Promise((resolve) => {
      fetch(serverUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      })
        .then((response) => {
          if (response.ok) {
            return response.json() as Record<string, any>;
          } else {
            return response.text().then((text) => {
              throw new Error(text);
            });
          }
        })
        .then((parsedResponsePayload) => {
          const result = this.buildResponse(parsedResponsePayload);
          resolve(result);
        })
        .catch((e) => {
          console.error("Amplitude error:", e);
          resolve(null);
        });
    });
  }
}
