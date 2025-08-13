export class Agent {
  constructor(protected tools: Tools) {}

  activate(_priority: Pick<Priority, "id">): Promise<void> {
    return Promise.resolve();
  }
  activity(_activity: Activity): Promise<void> {
    return Promise.resolve();
  }
}

export class Tool {
  constructor(protected tools: Tools) {}
}

export interface Tools {
  get<T>(id: string): T;
}

export type Priority = {
  id: string;
  title: string;
};

export type Activity = {
  id: string;
  createdBy: string;
  doOn?: string; // date string (e.g. '2025-07-10')
  doneAt?: Date;
  note?: string;
  title?: string;
  parentId?: string;
  priorityId: string;
  path: string;
  pinned: boolean;
};
