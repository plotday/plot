export type Activity = {
  id: string;
  createdBy: string;
  doAt?: string; // date string (e.g. '2025-07-10')
  doneAt?: Date;
  note?: string;
  title?: string;
  parentId?: string;
  priorityId: string;
  path: string;
  pinned: boolean;
};

export type NewActivity = Omit<
  Activity,
  "id" | "createdBy" | "pinned" | "path"
> &
  Partial<Pick<Activity, "pinned">> & { priorityId?: string };

export type Priority = {
  id: string;
  title: string;
};

export type NewPriority = Omit<Priority, "id"> & {
  parentId?: string;
};

export type LlmMessage = {
  role: "user" | "assistant" | "system";
  content: string;
};

export interface Plot {
  config: any;
  createActivity(activity: NewActivity): Promise<Activity>;
  createPriority(priority: NewPriority): Promise<Priority>;
  getRelatedActivities(activity: Activity): Promise<Activity[]>;
  promptLlm(
    messages: LlmMessage[],
    options?: { schema?: object }
  ): Promise<any>;
}

export interface Agent {
  activate(plot: Plot): Promise<void>;

  activity(plot: Plot, activity: Activity): Promise<void>;
}
