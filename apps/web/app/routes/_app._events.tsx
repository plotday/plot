import { useMemo } from "react";

import type { UIMatch } from "@remix-run/react";
import { useMatches } from "@remix-run/react";

import { ScrollArea } from "@mantine/core";

import classes from "css/event.module.css";
import add from "date-fns/add";
import { typedjson, useTypedLoaderData } from "remix-typedjson";
import { promiseHash } from "remix-utils/promise";

import type { DbEvent } from "@plotday/db";
import { Event } from "@plotday/db";

import { EventDetails } from "app/components/event-details";
import { EventList } from "app/components/event-list";
import { Scheduler } from "app/components/scheduler";
import { ErrorPage } from "app/error";
import { useEventOptimist } from "app/event";
import { useTz } from "app/hooks";
import { getLabels } from "app/labels";
import { getExpenditures, getTargets } from "app/target";
import { privateLoader } from "app/util";

export type EventFilter = {
  review?: boolean;
  showGaps?: boolean;
  match?: (event: DbEvent) => boolean;
  config?: {
    name: string;
    label: string;
  }[];
};

export const loader = privateLoader(async ({ supabase, response, user }) => {
  const tz = user.timezone || "America/New_York";

  const start = new Date();
  const end = add(new Date(), { months: 2 });

  return typedjson(
    {
      ...(await promiseHash({
        targets: getTargets(supabase, user.id),
        expenditures: getExpenditures(supabase, user.id, tz, start, end),
        labels: getLabels(supabase, user.id),
      })),
    },
    { headers: response.headers }
  );
});

export function ErrorBoundary() {
  return <ErrorPage />;
}

export default function Events() {
  const matches = useMatches() as UIMatch<
    { events: DbEvent[]; event: DbEvent },
    { eventFilter: EventFilter }
  >[];

  const filter = useMemo(
    () =>
      matches.find((match) => !!match.handle && "eventFilter" in match.handle)
        ?.handle?.eventFilter ?? {},
    [matches]
  );

  const { targets, expenditures, labels } = useTypedLoaderData<typeof loader>();
  const tz = useTz();

  const { overrides } = useEventOptimist();
  const dbEvents = useMemo(() => {
    return (
      (
        matches.find((match) => !!match.data && "events" in match.data)?.data
          ?.events as DbEvent[]
      )
        .map((e) =>
          e.id && e.id in overrides ? { ...e, ...overrides[e.id] } : e
        )
        .filter((e) => filter.match?.(e) ?? true) ?? []
    );
  }, [matches, overrides, filter]);
  const events = useMemo(
    () => dbEvents.map((e) => Event.Hydrate(e, tz, labels)),
    [dbEvents, tz, labels]
  );

  const event = useMemo(() => {
    const match = matches.find((match) => !!match.data && "event" in match.data)
      ?.data?.event as DbEvent;
    if (!match) return null;
    const dbEvent =
      match.id && match.id in overrides
        ? { ...match, ...overrides[match.id] }
        : match;
    return Event.Hydrate(dbEvent, tz, labels);
  }, [matches, overrides, tz, labels]);

  return (
    <div className={classes.layout}>
      <ScrollArea className={event ? classes.mobileSecondary : undefined}>
        <EventList
          review={filter.review}
          showGaps={filter.showGaps}
          events={events}
          targets={targets}
          expenditures={expenditures}
        />
      </ScrollArea>
      <ScrollArea className={event ? undefined : classes.mobileSecondary}>
        {event && <EventDetails event={event} />}
        {!event && <Scheduler />}
      </ScrollArea>
    </div>
  );
}
