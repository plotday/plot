import type { ReactNode } from "react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import {
  Form,
  Link,
  useFetcher,
  useNavigation,
  useParams,
  useSearchParams,
} from "@remix-run/react";

import { Box, Button, Group, Stack, TextInput, rem } from "@mantine/core";
import { useListState } from "@mantine/hooks";

import { DragDropContext, Draggable, Droppable } from "@hello-pangea/dnd";
import { IconGripVertical } from "@tabler/icons-react";
import cx from "clsx";
import { typedjson, useTypedLoaderData } from "remix-typedjson";
import { promiseHash } from "remix-utils/promise";

import type { DbCategory } from "@plotday/db";
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

function between(str1: string | null, str2: string | null): string {
  if (str1 === null) {
    if (str2 === null) return "O";
    str1 = String.fromCharCode(Math.max(32, str2.charCodeAt(0) - 1));
  } else if (str2 === null) {
    str2 = String.fromCharCode(Math.min(126, str1.charCodeAt(0) + 1));
  }

  let newStr = "";
  for (let i = 0; true; i++) {
    const c1 = i < str1.length ? str1.charCodeAt(i) : 32;
    const c2 = i < str2.length ? str2.charCodeAt(i) : 126;
    const cn = Math.floor((c1 + c2) / 2);

    if (c1 === cn || c2 === cn) {
      newStr += str1[i];
      continue;
    }

    newStr += String.fromCharCode(cn);
    break;
  }
  return newStr;
}

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

  const fetcher = useFetcher();
  const fetcherSubmit = fetcher.submit;
  const saveOrder = useCallback(
    (
      target: DbCategory,
      after: DbCategory | null,
      before: DbCategory | null
    ) => {
      let path = target.path as string;
      if (path.indexOf(".") === -1) path = `${path}.other`;
      fetcherSubmit(
        {
          priority: between(after?.priority ?? null, before?.priority ?? null),
        },
        { method: "PATCH", action: pathToUrl(path) }
      );
    },
    [fetcherSubmit]
  );

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

  const addFetcher = useFetcher({ key: "add-priority" });
  const isAdding = addFetcher.state == "submitting";
  const formRef = useRef<HTMLFormElement>(null);
  useEffect(() => {
    console.log("isAdding", isAdding, formRef.current);
    if (!isAdding) {
      setNewCategory("");
    }
  }, [isAdding]);

  return (
    <Stack>
      <DragDropContext
        onDragEnd={({ destination, source }) => {
          if (!destination || source.index == destination.index) return;
          listHandlers.reorder({
            from: source.index,
            to: destination.index,
          });
          saveOrder(
            listState[source.index],
            listState[
              destination.index + (source.index < destination.index ? 0 : -1)
            ] ?? null,
            listState[
              destination.index + (source.index < destination.index ? 1 : 0)
            ] ?? null
          );
        }}
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
      <Form
        method="post"
        action="new"
        ref={formRef}
        navigate={false}
        fetcherKey="add-priority"
      >
        <input
          type="hidden"
          name="priority"
          value={between(
            listState[listState.length - 1]?.priority ?? null,
            null
          )}
        />
        <input type="hidden" name="no-redirect" value="true" />
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
