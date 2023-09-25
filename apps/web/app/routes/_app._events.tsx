import { useMemo } from "react";

import type { LoaderFunctionArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";
import type { UIMatch } from "@remix-run/react";
import { useMatches, useSearchParams } from "@remix-run/react";

import { ActionIcon, Box, Popover, Portal, Stack, Switch } from "@mantine/core";

import { IconAdjustments } from "@tabler/icons-react";
import add from "date-fns/add";
import { typedjson, useTypedLoaderData } from "remix-typedjson";
import { promiseHash } from "remix-utils/promise";

import type { DbEvent } from "@plotday/db";
import { Event } from "@plotday/db";

import { getUser } from "app/auth";
import { EventList } from "app/components/event";
import { createServerClient } from "app/db";
import { useTz } from "app/hooks";
import { getExpenditures, getTargets } from "app/target";

export type EventFilter = {
  review?: boolean;
  showGaps?: boolean;
  config?: {
    name: string;
    label: string;
  }[];
};

export const loader = async ({ context, request }: LoaderFunctionArgs) => {
  const { response, supabase } = createServerClient(request, context);
  let user = await getUser(supabase);
  if (!user?.id) throw redirect("/login");
  const tz = user.timezone || "America/New_York";

  const start = new Date();
  const end = add(new Date(), { months: 2 });

  return typedjson(
    {
      ...(await promiseHash({
        targets: getTargets(supabase, user.id),
        expenditures: getExpenditures(supabase, user.id, tz, start, end),
      })),
    },
    { headers: response.headers }
  );
};

export default function Events() {
  const matches = useMatches() as UIMatch<
    { events: DbEvent[] },
    { eventFilter: EventFilter }
  >[];

  const filter =
    matches.find((match) => !!match.handle && "eventFilter" in match.handle)
      ?.handle?.eventFilter ?? {};

  const dbEvents = useMemo(
    () =>
      (matches.find((match) => !!match.data && "events" in match.data)?.data
        ?.events as DbEvent[]) ?? [],
    [matches]
  );
  const { targets, expenditures } = useTypedLoaderData<typeof loader>();
  const tz = useTz();
  const events = useMemo(() => Event.Hydrate(dbEvents, tz), [dbEvents, tz]);

  const [params, setParams] = useSearchParams();

  return (
    <>
      {filter.config && (
        <Portal>
          <Box pos="fixed" p="md" style={{ top: 0, right: 0, zIndex: 101 }}>
            <Popover width={200} position="bottom" withArrow shadow="md">
              <Popover.Target>
                <ActionIcon variant="subtle" aria-label="Settings">
                  <IconAdjustments
                    style={{ width: "85%", height: "85%" }}
                    stroke={1.5}
                  />
                </ActionIcon>
              </Popover.Target>
              <Popover.Dropdown>
                <Stack>
                  {filter.config.map((config) => (
                    <Switch
                      key={config.name}
                      label={config.label}
                      checked={params.get(config.name) === "true"}
                      onChange={(event) =>
                        setParams({
                          ...params,
                          [config.name]: event.currentTarget.checked,
                        })
                      }
                    />
                  ))}
                </Stack>
              </Popover.Dropdown>
            </Popover>
          </Box>
        </Portal>
      )}
      <EventList
        review={filter.review}
        showGaps={filter.showGaps}
        events={events}
        targets={targets}
        expenditures={expenditures}
      />
    </>
  );
}
