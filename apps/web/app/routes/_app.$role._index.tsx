import type { ReactNode } from "react";
import { useEffect, useMemo, useState } from "react";

import { Form, Link, useParams, useSearchParams } from "@remix-run/react";

import { Box, Button, Group, Stack, TextInput, rem } from "@mantine/core";
import { useListState } from "@mantine/hooks";

import { DragDropContext, Draggable, Droppable } from "@hello-pangea/dnd";
import { IconGripVertical } from "@tabler/icons-react";
import cx from "clsx";
import { typedjson, useTypedLoaderData } from "remix-typedjson";
import { promiseHash } from "remix-utils/promise";

import {
  getCategoriesWithTotals,
  getCategory,
  pathToUrl,
  urlToPath,
} from "@plotday/db";

import { getWeek } from "app/components/select-week";
import { WeeklyGoal } from "app/components/weekly-goal";
import { privateLoader } from "app/util";

import classes from "./dnd.module.css";

export const loader = privateLoader(
  async ({ url, params, response, user, supabase }) => {
    const { week } = getWeek(url.searchParams, user.timezone);
    let role = params.role && urlToPath(params.role.slice(1));
    if (!role) throw new Response("Not found", { status: 404 });
    return typedjson(
      {
        ...(await promiseHash({
          category: getCategory(supabase, user.id, role),
          insights: getCategoriesWithTotals(supabase, user.id, week),
        })),
        week,
      },
      { headers: response.headers }
    );
  }
);

export default function Main() {
  const params = useParams();
  const [search] = useSearchParams();
  const role = urlToPath(params.role?.slice(1) ?? "");
  const { insights, week } = useTypedLoaderData<typeof loader>();
  const [newCategory, setNewCategory] = useState("");
  const filtered = useMemo(
    () =>
      Object.values(insights ?? {}).filter(
        (category) =>
          category.path === role || category.path.startsWith(`${role}.`)
      ),
    [role, insights]
  );
  const width = (category: string, margin = 1) =>
    Math.max(
      (insights?.[category]?.insights?.[week]?.meeting?.minutes ?? 0) +
        (insights?.[category]?.insights?.[week]?.task?.minutes ?? 0),
      Math.round((insights?.[category]?.budget_weekly ?? 0) * margin)
    );
  const max = Math.max(...filtered.map((c) => Math.max(width(c.path, 1.2))));

  const [listState, listHandlers] = useListState(filtered);
  const setListState = listHandlers.setState;
  useEffect(() => {
    setListState(filtered);
  }, [setListState, filtered]);

  const items = listState.map((c, index) => (
    <Draggable key={c.id} index={index} draggableId={c.id.toString()}>
      {(provided, snapshot) => (
        <div
          className={cx(classes.item, {
            [classes.itemDragging]: snapshot.isDragging,
          })}
          ref={provided.innerRef}
          {...provided.draggableProps}
        >
          <Group w="100%">
            <div {...provided.dragHandleProps} className={classes.dragHandle}>
              <IconGripVertical
                style={{ width: rem(18), height: rem(18) }}
                stroke={1.5}
              />
            </div>
            <Button
              variant="subtle"
              w="12rem"
              justify="left"
              key={c.id}
              component={Link}
              prefetch="intent"
              to={`${pathToUrl(
                c.path === role ? `${c.path}.other` : c.path
              )}?${search}`}
              relative="path"
            >
              {c.path === role ? "Other" : c.name}
            </Button>
            <Box style={{ flexGrow: 1 }}>
              <WeeklyGoal
                category={c}
                insights={insights?.[c.path]?.insights?.[week]}
                relativeWidth={(width(c.path) / max) * 100}
              />
            </Box>
          </Group>
        </div>
      )}
    </Draggable>
  ));

  return (
    <Stack>
      <DragDropContext
        onDragEnd={({ destination, source }) =>
          listHandlers.reorder({
            from: source.index,
            to: destination?.index || 0,
          })
        }
      >
        <Droppable droppableId="dnd-list" direction="vertical">
          {(provided) => (
            <div {...provided.droppableProps} ref={provided.innerRef}>
              {items}
              {provided.placeholder as ReactNode}
            </div>
          )}
        </Droppable>
      </DragDropContext>
      <Form method="post" action="new">
        <TextInput
          name="name"
          w="18rem"
          value={newCategory}
          onChange={(event) => setNewCategory(event.currentTarget.value)}
          placeholder="+ New priority"
          rightSection={
            !newCategory ? null : <Button type="submit">Add priority</Button>
          }
        />
      </Form>
    </Stack>
  );
}
