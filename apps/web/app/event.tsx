import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
} from "react";

import { useRevalidator } from "@remix-run/react";

import { useThrottledCallback } from "use-debounce";

import type { DbEvent } from "@plotday/db";

import { useSupabase } from "app/hooks";

export function useEventWatch(_start?: Date, _end?: Date) {
  const supabase = useSupabase();
  const { revalidate } = useRevalidator();
  const throttledRevalidate = useThrottledCallback(
    () => {
      revalidate();
    },
    10_000,
    { leading: true, trailing: true }
  );
  useEffect(() => {
    if (!supabase) return;
    const channel = supabase
      .channel("table-db-changes")
      .on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "event",
        },
        (_payload) => {
          throttledRevalidate();
        }
      )
      .on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "response",
        },
        (_payload) => {
          throttledRevalidate();
        }
      )
      .on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "invitee",
        },
        (_payload) => {
          throttledRevalidate();
        }
      )
      .subscribe();
    return () => {
      channel.unsubscribe();
    };
  }, [supabase, throttledRevalidate]);
}

type EventOverrides = Record<number, Partial<DbEvent>>;

const EventOptimistContext = createContext<{
  overrides: EventOverrides;
  setOverrides: React.Dispatch<React.SetStateAction<EventOverrides>>;
}>({ overrides: {}, setOverrides: (prev) => prev });

export function EventOptimistProvider({
  children,
}: {
  children: React.ReactNode;
}) {
  const [overrides, setOverrides] = useState<Record<number, Partial<DbEvent>>>(
    {}
  );
  return (
    <EventOptimistContext.Provider value={{ overrides, setOverrides }}>
      {children}
    </EventOptimistContext.Provider>
  );
}

export function useEventOptimist() {
  const { overrides, setOverrides } = useContext(EventOptimistContext);
  const setOverride = useCallback(
    (id: number, override: Partial<DbEvent>) => {
      setOverrides((prev) => ({
        ...prev,
        [id]: {
          ...prev[id],
          ...override,
        },
      }));
    },
    [setOverrides]
  );
  const clearOverride = useCallback(
    (id: number, clear: (keyof DbEvent)[]) => {
      setOverrides((prev) => {
        let { [id]: e, ...rest } = prev;
        e = { ...e };
        for (const key of clear) {
          delete e[key];
        }
        if (Object.keys(e).length === 0) {
          return rest;
        }
        return {
          ...rest,
          [id]: e,
        };
      });
    },
    [setOverrides]
  );
  return { overrides, setOverride, clearOverride };
}
