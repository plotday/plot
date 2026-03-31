---
name: decode-plot-url
description: Decode a Plot app URL (app.plot.day or localhost:8788) to extract priority and thread UUIDs, then look them up in the database.
---

# Decode Plot App URL

When the user shares a Plot app URL, decode the base58 path segments to UUIDs and look them up.

## Step 1: Parse the URL

Extract path segments from the URL. Recognized hosts:
- `app.plot.day` (production)
- `localhost:8788` (dev)

The first path segment is the **priority ID**, the second (optional) is the **thread ID**.

## Step 2: Decode base58 segments to UUIDs

For each segment, run:

```bash
python3 -c "
A='123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
s='SEGMENT_HERE'; n=0
for c in s: n=n*58+A.index(c)
h=format(n,'032x'); print(f'{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}')
"
```

Replace `SEGMENT_HERE` with each base58 segment. Run both decodes in parallel if there are two segments.

## Step 3: Query the database

Choose the database based on the URL host:

**Dev (localhost):**
```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c "SELECT id, title, path FROM priority WHERE id = '<priority_uuid>'"
```

**Production (app.plot.day):**
```bash
# Ensure proxy is running
nc -z 127.0.0.1 5433 2>/dev/null || pnpm prod-db-connect && sleep 2

psql -h 127.0.0.1 -p 5433 -U readonly -d plot -c "SELECT id, title, path FROM priority WHERE id = '<priority_uuid>'"
```

If a thread segment was present:
```bash
# Use the same connection pattern as above
psql ... -c "SELECT t.id, a.title FROM thread t JOIN activity a ON a.id = t.activity_id WHERE t.id = '<thread_uuid>'"
```

## Step 4: Report results

Output the decoded UUIDs and the entity names found in the database. Example:

```
Priority: My Project (uuid: 01234567-89ab-cdef-0123-456789abcdef)
Thread: Fix login bug (uuid: fedcba98-7654-3210-fedc-ba9876543210)
```
