/**
 * Server-Sent Events (SSE) client utilities
 */

export interface SSEEvent {
  event: string;
  data: any;
  id?: string;
}

export interface SSEHandlers {
  onProgress?: (message: string) => void;
  onResult?: (data: any) => void;
  onError?: (error: string) => void;
  onEvent?: (event: string, data: any) => void;
}

/**
 * Parse and handle SSE response stream
 */
export async function handleSSEStream(
  response: Response,
  handlers: SSEHandlers
): Promise<any> {
  if (!response.body) {
    throw new Error("Response has no body");
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let result: any = null;

  try {
    while (true) {
      const { done, value } = await reader.read();

      if (done) {
        break;
      }

      // Decode chunk and add to buffer
      buffer += decoder.decode(value, { stream: true });

      // Process complete messages in buffer
      const lines = buffer.split("\n");

      // Keep incomplete message in buffer
      buffer = lines.pop() || "";

      let currentEvent: Partial<SSEEvent> = {};

      for (const line of lines) {
        // Empty line marks end of event
        if (line.trim() === "") {
          if (currentEvent.event && currentEvent.data !== undefined) {
            // Parse data if it's JSON
            let parsedData = currentEvent.data;
            try {
              parsedData = JSON.parse(currentEvent.data);
            } catch {
              // Not JSON, use as-is
            }

            // Handle event based on type
            switch (currentEvent.event) {
              case "progress":
                handlers.onProgress?.(parsedData.message);
                break;
              case "result":
                result = parsedData;
                handlers.onResult?.(parsedData);
                break;
              case "error":
                handlers.onError?.(parsedData.error);
                throw new Error(parsedData.error);
              default:
                // Handle custom events via onEvent handler
                if (handlers.onEvent) {
                  handlers.onEvent(currentEvent.event, parsedData);
                }
            }
          }

          // Reset for next event
          currentEvent = {};
          continue;
        }

        // Skip comment lines (lines starting with ":")
        if (line.startsWith(":")) {
          continue;
        }

        // Parse SSE field
        const colonIndex = line.indexOf(":");
        if (colonIndex === -1) {
          continue;
        }

        const field = line.slice(0, colonIndex);
        let value = line.slice(colonIndex + 1);

        // Trim leading space from value (SSE spec)
        if (value.startsWith(" ")) {
          value = value.slice(1);
        }

        switch (field) {
          case "event":
            currentEvent.event = value;
            break;
          case "data":
            currentEvent.data = value;
            break;
          case "id":
            currentEvent.id = value;
            break;
        }
      }
    }

    return result;
  } finally {
    reader.releaseLock();
  }
}
