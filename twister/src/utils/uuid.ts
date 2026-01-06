import { v7 as uuidv7 } from "uuid";

export type Uuid = string & { readonly __brand: "UuidV7" };

export namespace Uuid {
  export function Generate(): Uuid {
    return uuidv7() as Uuid;
  }
}
