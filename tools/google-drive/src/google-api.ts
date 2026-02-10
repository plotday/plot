export type GoogleDriveFile = {
  id: string;
  name: string;
  mimeType: string;
  description?: string;
  webViewLink?: string;
  iconLink?: string;
  createdTime?: string;
  modifiedTime?: string;
  owners?: Array<{
    emailAddress?: string;
    displayName?: string;
  }>;
  parents?: string[];
};

export type GoogleDriveComment = {
  id: string;
  content: string;
  htmlContent?: string;
  author: {
    displayName?: string;
    emailAddress?: string;
  };
  createdTime: string;
  modifiedTime: string;
  resolved: boolean;
  replies?: GoogleDriveReply[];
};

export type GoogleDriveReply = {
  id: string;
  content: string;
  htmlContent?: string;
  author: {
    displayName?: string;
    emailAddress?: string;
  };
  createdTime: string;
  modifiedTime: string;
};

export type SyncState = {
  folderId: string;
  pageToken?: string;
  changesToken?: string;
  more?: boolean;
  sequence?: number;
  timeMin?: Date;
};

export class GoogleApi {
  constructor(public accessToken: string) {}

  public async call(
    method: string,
    url: string,
    params?: { [key: string]: any },
    body?: { [key: string]: any }
  ) {
    // Filter out undefined/null values from params
    const filteredParams: Record<string, string> = {};
    if (params) {
      for (const [key, value] of Object.entries(params)) {
        if (value !== undefined && value !== null) {
          filteredParams[key] = String(value);
        }
      }
    }

    const query = Object.keys(filteredParams).length > 0
      ? `?${new URLSearchParams(filteredParams)}`
      : "";
    const headers = {
      Authorization: `Bearer ${this.accessToken}`,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
    };
    const response = await fetch(url + query, {
      method,
      headers,
      ...(body ? { body: JSON.stringify(body) } : {}),
    });

    switch (response.status) {
      case 400:
        const responseBody = await response.json();
        if ((responseBody as any).status === "FAILED_PRECONDITION") {
          return null;
        }
        throw new Error("Invalid request", { cause: responseBody });
      case 401:
        throw new Error("Authentication failed - token may be expired");
      case 410:
        return null;
      case 200:
        return await response.json();
      default:
        throw new Error(await response.text());
    }
  }
}

const DRIVE_API = "https://www.googleapis.com/drive/v3";

/**
 * List folders accessible by the user.
 */
export async function listFolders(api: GoogleApi): Promise<GoogleDriveFile[]> {
  const folders: GoogleDriveFile[] = [];
  let pageToken: string | undefined;

  do {
    const data = (await api.call("GET", `${DRIVE_API}/files`, {
      q: "mimeType='application/vnd.google-apps.folder' and trashed=false",
      fields: "nextPageToken,files(id,name,description,parents)",
      pageSize: 100,
      pageToken,
    })) as { files: GoogleDriveFile[]; nextPageToken?: string } | null;

    if (!data) break;
    folders.push(...data.files);
    pageToken = data.nextPageToken;
  } while (pageToken);

  return folders;
}

/**
 * List files in a folder (non-folder items only).
 */
export async function listFilesInFolder(
  api: GoogleApi,
  folderId: string,
  pageToken?: string
): Promise<{ files: GoogleDriveFile[]; nextPageToken?: string }> {
  const data = (await api.call("GET", `${DRIVE_API}/files`, {
    q: `'${folderId}' in parents and mimeType!='application/vnd.google-apps.folder' and trashed=false`,
    fields:
      "nextPageToken,files(id,name,mimeType,description,webViewLink,iconLink,createdTime,modifiedTime,owners,parents)",
    pageSize: 50,
    pageToken,
  })) as { files: GoogleDriveFile[]; nextPageToken?: string } | null;

  return data || { files: [] };
}

/**
 * List comments on a file, including replies.
 */
export async function listComments(
  api: GoogleApi,
  fileId: string
): Promise<GoogleDriveComment[]> {
  const comments: GoogleDriveComment[] = [];
  let pageToken: string | undefined;

  do {
    const data = (await api.call(
      "GET",
      `${DRIVE_API}/files/${fileId}/comments`,
      {
        fields:
          "nextPageToken,comments(id,content,htmlContent,author,createdTime,modifiedTime,resolved,replies(id,content,htmlContent,author,createdTime,modifiedTime))",
        pageSize: 100,
        includeDeleted: false,
        pageToken,
      }
    )) as { comments: GoogleDriveComment[]; nextPageToken?: string } | null;

    if (!data) break;
    comments.push(...data.comments);
    pageToken = data.nextPageToken;
  } while (pageToken);

  return comments;
}

/**
 * Create a comment on a file.
 */
export async function createComment(
  api: GoogleApi,
  fileId: string,
  content: string
): Promise<GoogleDriveComment> {
  return (await api.call(
    "POST",
    `${DRIVE_API}/files/${fileId}/comments`,
    { fields: "id,content,author,createdTime,modifiedTime,resolved" },
    { content }
  )) as GoogleDriveComment;
}

/**
 * Create a reply to an existing comment on a file.
 */
export async function createReply(
  api: GoogleApi,
  fileId: string,
  commentId: string,
  content: string
): Promise<GoogleDriveReply> {
  return (await api.call(
    "POST",
    `${DRIVE_API}/files/${fileId}/comments/${commentId}/replies`,
    { fields: "id,content,author,createdTime,modifiedTime" },
    { content }
  )) as GoogleDriveReply;
}

/**
 * Get the changes start page token for incremental sync.
 */
export async function getChangesStartToken(
  api: GoogleApi
): Promise<string> {
  const data = (await api.call(
    "GET",
    `${DRIVE_API}/changes/startPageToken`
  )) as { startPageToken: string };
  return data.startPageToken;
}

/**
 * List changes since a given token, filtered to a specific folder.
 */
export async function listChanges(
  api: GoogleApi,
  pageToken: string
): Promise<{
  changes: Array<{
    fileId: string;
    removed: boolean;
    file?: GoogleDriveFile;
  }>;
  nextPageToken?: string;
  newStartPageToken?: string;
}> {
  const data = (await api.call("GET", `${DRIVE_API}/changes`, {
    pageToken,
    fields:
      "nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,description,webViewLink,iconLink,createdTime,modifiedTime,owners,parents))",
    pageSize: 100,
    includeRemoved: true,
  })) as {
    changes: Array<{
      fileId: string;
      removed: boolean;
      file?: GoogleDriveFile;
    }>;
    nextPageToken?: string;
    newStartPageToken?: string;
  } | null;

  return data || { changes: [] };
}
