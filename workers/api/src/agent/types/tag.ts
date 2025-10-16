/**
 * Tag enumeration matching the Flutter app tag definitions.
 *
 * Tag IDs are immutable and correspond to the Dart Tag enum in apps/plot/lib/store/tag.dart
 * - IDs 1-99: Compute tags (automatic system tags)
 * - IDs 100-999: Toggle tags (user-selectable toggles)
 * - IDs 1000+: Count tags (reaction counters)
 */
export enum Tag {
  // Compute tags (1-99)
  Now = 1,
  Later = 2,
  Done = 3,
  Archived = 4,

  // Toggle tags (100-999)
  Pinned = 100,
  Urgent = 101,
  Todo = 102,
  Goal = 103,
  Decision = 104,
  Waiting = 105,
  Blocked = 106,
  Warning = 107,
  Question = 108,
  Star = 110,
  Idea = 111,
  Attachment = 112,
  Link = 113,

  // Count tags (1000+)
  Yes = 1000,
  No = 1001,
  Volunteer = 1002,
  Tada = 1003,
  Fire = 1004,
  Totally = 1005,
  Looking = 1006,
  Love = 1007,
  Rocket = 1008,
  Sparkles = 1009,
  Thanks = 1010,
  Smile = 1011,
  Wave = 1012,
  Praise = 1013,
  Joy = 1014,
  Admiration = 1015,
  Applause = 1016,
  Cool = 1017,
  Sad = 1018,
}
