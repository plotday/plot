import { ITool } from "..";

/**
 * Built-in tool for reading files attached to notes in Plot.
 *
 * Files are uploaded by clients via POST /files which creates an
 * ActionType.file entry on a note. Connectors call read() during outbound
 * (e.g. onNoteCreated) to retrieve those bytes and send them to the source
 * system.
 *
 * For inbound attachments, connectors emit ActionType.fileRef actions and
 * implement Connector.downloadAttachment — no upload tool is needed because
 * inbound bytes never enter Plot's R2 storage.
 */
export abstract class Files extends ITool {
  /**
   * Read a file uploaded by a client and attached to a note on a thread
   * in one of the twist owner's focuses.
   *
   * @param fileId The id from an ActionType.file action.
   * @returns Bytes plus original metadata.
   * @throws FileNotFoundError if the file is missing or out of scope.
   */
  abstract read(fileId: string): Promise<{
    data: Uint8Array;
    fileName: string;
    mimeType: string;
    fileSize: number;
  }>;
}

export class FileNotFoundError extends Error {
  constructor(fileId: string) {
    super(`File not found or out of scope: ${fileId}`);
    this.name = "FileNotFoundError";
  }
}
