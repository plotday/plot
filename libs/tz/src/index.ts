import {
  toDate as _toDate,
  formatInTimeZone,
  utcToZonedTime,
  zonedTimeToUtc,
} from "date-fns-tz";
import differenceInMinutes from "date-fns/differenceInMinutes";
import _eachDayOfInterval from "date-fns/eachDayOfInterval";
import _endOfDay from "date-fns/endOfDay";
import _endOfMonth from "date-fns/endOfMonth";
import _endOfWeek from "date-fns/endOfWeek";
import _isSameDay from "date-fns/isSameDay";
import _startOfDay from "date-fns/startOfDay";
import _startOfMonth from "date-fns/startOfMonth";
import _startOfWeek from "date-fns/startOfWeek";

function zoned<T>(
  date: Date,
  tz: string,
  fn: (date: Date, options?: T) => Date,
  options?: T
): Date {
  const inputZoned = utcToZonedTime(date, tz);
  const fnZoned = options ? fn(inputZoned, options) : fn(inputZoned);
  return zonedTimeToUtc(fnZoned, tz);
}

function zoned2<T>(
  d1: Date,
  d2: Date,
  tz: string,
  fn: (d1: Date, d2: Date) => T
): T {
  const d1z = utcToZonedTime(d1, tz);
  const d2z = utcToZonedTime(d2, tz);
  return fn(d1z, d2z);
}

function zonedInterval<T1>(
  interval: Interval,
  tz: string,
  fn: (date: Interval, options?: T1) => Date[],
  options?: T1
): Date[] {
  const inputZoned = {
    start: utcToZonedTime(interval.start, tz),
    end: utcToZonedTime(interval.end, tz),
  };
  const fnZoned = options ? fn(inputZoned, options) : fn(inputZoned);
  return fnZoned.map((d) => zonedTimeToUtc(d, tz));
}

export const toDate = (date: string, tz: string) => {
  return _toDate(date, { timeZone: tz });
};

export function formatDate(date: Date, tz: string, format: string) {
  return formatInTimeZone(date, tz, format);
}

export const formatDay = (start: Date, tz: string) => {
  return formatDate(start, tz, "cccc, MMMM d, yyyy");
};

export const formatTime = (start: Date, tz: string) => {
  return `${formatDate(start, tz, "h:mm aaa")}`;
};

export const formatTimes = (start: Date, end: Date, tz: string) => {
  return `${formatTime(start, tz)} - ${formatTime(end, tz)}`;
};

export const formatDuration = (
  length: number,
  alwaysMinutes: boolean = false
) => {
  length = Math.round(length);
  const hours = Math.floor(length / 60);
  const minutes = Math.abs(length % 60);
  const showMinutes = minutes > 0 || alwaysMinutes;
  return (
    (hours ? `${hours}h` : "") +
    (hours && showMinutes ? " " : "") +
    (showMinutes ? `${String(minutes).padStart(hours ? 2 : 0, "0")}m` : "")
  );
};

export const formatDifference = (
  start: Date,
  end: Date,
  alwaysMinutes: boolean = false
) => {
  return formatDuration(differenceInMinutes(end, start), alwaysMinutes);
};

export const toTz = (date: Date, tz: string) => {
  return zonedTimeToUtc(date, tz);
};

export const fromTz = (date: Date, tz: string) => {
  return utcToZonedTime(date, tz);
};

export function startOfDay(date: Date, tz: string) {
  return zoned(date, tz, _startOfDay);
}
export function endOfDay(date: Date, tz: string) {
  return zoned(date, tz, _endOfDay);
}

export function startOfMonth(date: Date, tz: string) {
  return zoned(date, tz, _startOfMonth);
}
export function endOfMonth(date: Date, tz: string) {
  return zoned(date, tz, _endOfMonth);
}

export function startOfWeek(
  date: Date,
  tz: string,
  options?: Parameters<typeof _startOfWeek>[1]
) {
  return zoned(date, tz, _startOfWeek, options);
}
export function endOfWeek(
  date: Date,
  tz: string,
  options?: Parameters<typeof _endOfWeek>[1]
) {
  return zoned(date, tz, _endOfWeek, options);
}

export function eachDayOfInterval(
  interval: Parameters<typeof _eachDayOfInterval>[0],
  tz: string,
  options?: Parameters<typeof _eachDayOfInterval>[1]
) {
  return zonedInterval(interval, tz, _eachDayOfInterval, options);
}

export function isSameDay(d1: Date, d2: Date, tz: string) {
  return zoned2(d1, d2, tz, _isSameDay);
}
