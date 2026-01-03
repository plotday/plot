/**
 * Activity tags. Three types:
 * 1. Special tags, which trigger other behaviors
 * 2. Toggle tags, which anyone can toggle a shared value on or off
 * 3. Count tags, where everyone can add or remove their own
 */
export enum Tag {
  // Special tags
  Now = 1,
  Later = 2,
  Done = 3,
  Archived = 4,
  Someday = 7,

  // Toggle tags
  Pinned = 100,
  Urgent = 101,
  Inbox = 102,
  Goal = 103,
  Decision = 104,
  Waiting = 105,
  Blocked = 106,
  Warning = 107,
  Question = 108,
  Twist = 109,
  Star = 110,
  Idea = 111,

  // Count tags
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
  Praise = 1015,
  Applause = 1016,
  Cool = 1017,
  Sad = 1018,
  Attend = 1019,
  Skip = 1020,
  Undecided = 1021,
}
