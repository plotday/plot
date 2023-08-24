import { useEffect } from "react";

import { useRevalidator } from "@remix-run/react";

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
