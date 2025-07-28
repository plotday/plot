import type { Activity, Priority } from "@plotday/sdk";

export interface Plot {
  createActivity(activity: NewActivity): Promise<Activity>;
  createPriority(priority: NewPriority): Promise<Priority>;
  getActivities(activity: Activity): Promise<Activity[]>;
}

export type NewPriority = Omit<Priority, "id"> & {
  parentId?: string;
};

export type NewActivity = Omit<
  Activity,
  "id" | "createdBy" | "pinned" | "path"
> &
  Partial<Pick<Activity, "pinned">> & { priorityId?: string };
