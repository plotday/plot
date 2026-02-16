import { toDate } from "@plotday/tz";

export type { Database, Json } from "./types";

export function parseDateRange(range: string | unknown) {
  const [start, end] = (range as string).replaceAll(/["[\]()]/g, "").split(",");
  return {
    start,
    end,
  };
}

export function parseDatetimeRange(range: string | unknown, tz?: string) {
  const { start, end } = parseDateRange(range);
  return {
    start: tz ? toDate(start, tz) : new Date(start),
    end: tz ? toDate(end, tz) : new Date(end),
  };
}

export function formatDatetimeRange(start: Date, end: Date) {
  return `[${start.toISOString()},${end.toISOString()})`;
}

export { DbError, type DbErrorContext } from "./query";
export * from "./path";
