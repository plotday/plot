export type Activity = {
  id: string;
  doOn?: string; // date string (e.g. '2025-07-10')
  doneAt?: Date;
  note?: string;
  title?: string;
  parentId?: string;
  pinned: boolean;
};

export type NewActivity = Omit<Activity, "id" | "pinned"> &
  Partial<Pick<Activity, "pinned">> & {priorityId?: string;};

export type NewPriority = {
  title: string;
  parentId?: string;
}

export interface Priority {
  createActivity(activity: NewActivity): Promise<any>;
  createPriority(priority: NewPriority): Promise<any>;
}