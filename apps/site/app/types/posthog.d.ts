declare global {
  interface Window {
    posthog?: {
      identify: (
        distinctId: string,
        properties?: Record<string, unknown>,
        propertiesSetOnce?: Record<string, unknown>
      ) => void;
      reset: () => void;
    };
  }
}
export {};
