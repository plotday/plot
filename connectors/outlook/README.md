# @plotday/connector-outlook

Combined Outlook connector for Plot. Syncs Outlook Mail, Calendar, and Contacts using a single Microsoft OAuth connection, with per-product scope groups the user can toggle at connect time.

Connecting grants access to all three products by default. Users can decline individual scope groups — for example, connect Mail only without Calendar — and Plot will sync only what was approved. Contacts is enrichment-only: it recognises people by name across your mail and calendar threads without creating a separate import; users can opt out of the people scope group if they prefer not to share their address book.
