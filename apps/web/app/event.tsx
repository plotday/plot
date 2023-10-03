import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
} from "react";

import { useRevalidator } from "@remix-run/react";

import type { DbEvent } from "@plotday/db";

import { useSupabase } from "app/hooks";

export function useEventWatch(_start?: Date, _end?: Date) {
  const supabase = useSupabase();
  const revalidator = useRevalidator();
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
          revalidator.revalidate();
        }
      )
      .subscribe();
    return () => {
      channel.unsubscribe();
    };
  }, [supabase, revalidator]);
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
