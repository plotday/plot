import { useUser } from "@clerk/react-router";
import { useEffect, useRef } from "react";

export function PostHogIdentify() {
  const { user } = useUser();
  const lastUserId = useRef<string | null>(null);

  useEffect(() => {
    if (user && user.id !== lastUserId.current) {
      window.posthog?.identify(
        user.id,
        {
          email: user.primaryEmailAddress?.emailAddress,
          name: user.fullName,
        },
        { signed_up_time: user.createdAt?.toISOString() }
      );
      lastUserId.current = user.id;
    }
    if (!user && lastUserId.current) {
      window.posthog?.reset();
      lastUserId.current = null;
    }
  }, [user]);

  return null;
}
