# HubSpot Connector

Syncs HubSpot CRM records into Plot:

- **Contacts**, **companies**, and **deals** become threads. Deals carry the
  portal's pipeline stages as statuses (prefixed with the pipeline name when
  the portal has more than one) and show the deal owner as the assignee.
- **Note engagements** appear as notes on each associated record's thread,
  attributed to the HubSpot user who created them.
- **Task engagements** sync by where they naturally sit:
  - Tasks associated with a record become **to-do notes** on that record's
    thread — tagged to-do for the assignee (so they land on their list) and
    checked off when completed. Checking one done in Plot completes the task
    in HubSpot, un-checking reopens it, and reassigning the to-do moves the
    task to the new owner.
  - Standalone tasks (created in HubSpot's Tasks queue with no associated
    record) become their own threads, with statuses mirroring HubSpot's
    (To do / In progress / Waiting / Deferred / Done) that write back on
    change.
- **Notes you add in Plot** are written back to HubSpot as note engagements
  on the record, and edits to notes sync back too.
- **Deal stage changes in Plot** are written back to HubSpot.

## Authentication

OAuth via HubSpot with granular CRM scopes: contacts (read/write — HubSpot
gates note engagements on the contacts scopes), companies (read), deals
(read/write), and owners (read, for author/assignee attribution).

## Sync strategy

The initial crawl pages every object type through the CRM list endpoints.
Incremental updates poll the CRM search API every few minutes for recently
modified objects, because HubSpot only offers app-level webhooks (one
endpoint shared by every portal that installed the app) — there is no
per-account subscription API a connector could register against. Each object
type keeps its own high-water mark, held back by a small buffer to absorb
HubSpot's search-index lag.

## Known limitations

- Records deleted or archived in HubSpot are not detected (the search API
  only returns live records), so their threads remain in Plot.
- Editing a task note's *text* in Plot is not written back (the note folds
  the task's subject and body into one block that can't be split apart
  reliably); completion and assignee changes are. The next sync restores
  HubSpot's wording.
- New records can't be created from Plot yet.
