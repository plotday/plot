import { useEffect, useRef } from "react";

interface Props {
  user: {
    id: string;
    email?: string;
    name?: string;
    createdAt?: string;
  } | null;
}

export function PostHogIdentify({ user }: Props) {
  const lastUserId = useRef<string | null>(null);

  useEffect(() => {
    if (user && user.id !== lastUserId.current) {
      window.posthog?.identify(
        user.id,
        { email: user.email, name: user.name },
        { signed_up_time: user.createdAt }
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
