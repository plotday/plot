# Plot ID System Architecture

## Overview

Plot uses two distinct ID spaces that serve different purposes. Understanding the difference is
critical for correct implementation.

## The Two ID Spaces

### 1. Auth User ID (`UserId`)

- **Source**: `public."user"` table (with `clerk_id` linking to Clerk)
- **Access**: Clerk JWT verification in the API layer (`workers/api/src/utils/auth.ts`)
- **Purpose**: Authentication and session management
- **Usage**: ONLY for auth-related operations (login, permissions checks, etc.)

### 2. Contact/Actor ID (`ActorId`)

- **Source**: Plot's `contact` table
- **Access**: `user_contact_id(p_user_id)` SQL function (takes a user ID parameter)
- **Purpose**: Identifying people and entities within Plot's domain model
- **Usage**: ALL Plot entities (activities, tags, mentions, etc.)

## The Relationship

```text
┌──────────────┐         ┌─────────────┐
│ public.user  │         │   contact   │
│              │         │             │
│  id (UUID)   │◄────────┤  user_id    │
│  clerk_id    │         │  id (UUID)  │◄─── This is the ActorId
└──────────────┘         └─────────────┘
       ▲
       │
┌──────┴──────┐
│  Clerk JWT  │
│             │
│  sub =      │
│  clerk_id   │
│  external_  │
│  id = user  │
│  .id (UUID) │
└─────────────┘
```

### For Authenticated Users

Every authenticated user has BOTH IDs:

1. **Auth User ID**: Their `id` in `public."user"` (UUID), linked to Clerk via `clerk_id`
2. **Contact ID**: Their actor record in `contact` table
   - This is what's stored in activities, tags, mentions
   - Accessible via `user_contact_id(user_id)` SQL function
   - The API resolves the user ID from the Clerk JWT, then looks up the contact

The `contact.user_id` field links back to `public."user".id`.

### For External Contacts

People who don't have Plot accounts (e.g., email senders, event attendees):

- **No Auth User ID**: Not in `public."user"`
- **Contact ID only**: Still have a record in `contact` table
- `contact.user_id` is `NULL`

### For Twists

Automated integrations/plugins:

- **No Auth User ID**: Not users
- **Twist ID**: From `priority_twist` table
- Also considered an `ActorId` in the type system

## Authentication Architecture

Authentication uses Clerk:

1. **JWT Verification**: Clerk JWTs are verified using `verifyToken()` from `@clerk/backend`
2. **User Lookup**: The API looks up the user in `public."user"` by `external_id` (fast path) or
   `clerk_id` (fallback)
3. **No RLS**: Row-Level Security is disabled on all tables. Authorization is enforced at the API
   layer.
4. **No `auth.uid()`**: User identity comes from the API's JWT verification, not from a
   database-resident auth schema.

```typescript
// Authentication flow (workers/api/src/utils/auth.ts)
const claims = await verifyToken(token, { jwtKey });
const clerkId = claims.sub;
const userId = claims.external_id; // UUID from public."user".id

// Look up user in public."user" table
const user = await db.selectFrom("user").where("id", "=", userId).executeTakeFirst();
```

## Type System

### TypeScript (Twister SDK)

Located in `public/twister/src/common/id.ts`:

```typescript
// Branded types for compile-time safety
type UserId = string & { readonly __brand: "UserId" };
type ContactId = string & { readonly __brand: "ContactId" };
type TwistId = string & { readonly __brand: "TwistId" };

// ActorId is a union: ContactId OR TwistId (never UserId directly!)
type ActorId = ContactId | TwistId;
```

#### Helper Functions

```typescript
// Validation + conversion
toUserId(value: unknown): UserId
toContactId(value: unknown): ContactId
toTwistId(value: unknown): TwistId
toActorId(value: unknown): ActorId

// Type-safe conversions
contactIdToActorId(contactId: ContactId): ActorId
twistIdToActorId(twistId: TwistId): ActorId

// UNSAFE: Only use when you're certain of the mapping
userIdToContactIdUnsafe(userId: UserId): ContactId
```

### Dart (Flutter App)

Currently uses generic `Uuid` type for all IDs except ActorId, which uses Dart 3.0+ extension types
for type safety:

```dart
extension type ActorId(Uuid value) {}
```

## Database Schema

### Key Tables

#### `public."user"`

```sql
CREATE TABLE public."user" (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),  -- This is the UserId
    clerk_id text UNIQUE,                           -- Links to Clerk user
    email text NOT NULL UNIQUE,
    name text,
    avatar_url text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
```

#### `contact`

```sql
CREATE TABLE contact (
    id uuid PRIMARY KEY,           -- This is the ContactId/ActorId
    email text NOT NULL,
    user_id uuid REFERENCES public."user"(id),  -- Links to auth user
    ...
);
```

#### `activity`

```sql
CREATE TABLE activity (
    author_id uuid NOT NULL,       -- ActorId: who gets credit
    created_by uuid NOT NULL,      -- UserId/TwistId: who actually created it
    assignee_id uuid,              -- ActorId: who it's assigned to
    ...
);
```

#### `activity_tag` & `note_tag`

```sql
CREATE TABLE activity_tag (
    actor_id uuid NOT NULL,        -- ActorId: who added the tag
    activity_id uuid NOT NULL,
    tag_id integer NOT NULL,
    ...
);
```

### Key Functions

#### `user_contact_id(p_user_id)`

Returns the user's Contact ID by looking up the contact table:

```sql
CREATE FUNCTION "user".user_contact_id(p_user_id uuid) RETURNS uuid AS $$
    SELECT c.id FROM contact c WHERE c.user_id = p_user_id LIMIT 1;
$$ LANGUAGE sql STABLE;
```

**Note**: This function takes an explicit `p_user_id` parameter. The user ID is passed from the API
layer (resolved from the Clerk JWT), not from a database session variable.

#### `update_activity_tags()` & `update_note_tags()`

```sql
CREATE FUNCTION update_activity_tags(
    p_activity_id uuid,
    p_actor_id uuid,    -- NOTE: ActorId, not user_id!
    p_client_id integer,
    p_tag_updates jsonb
) ...
```

**Important**: Parameter is named `p_actor_id` (not `p_user_id`) for clarity.

## Common Pitfalls

### 1. Confusing UserId and ActorId

```typescript
// ❌ WRONG: These are different UUIDs!
const actorId = authUserId as ActorId;

// ✅ CORRECT: Query the mapping
const contact = await db
  .selectFrom("contact")
  .select("id")
  .where("user_id", "=", userId)
  .executeTakeFirstOrThrow();
const actorId = toActorId(contact.id);
```

### 2. Using UserId Where ActorId Is Expected

```typescript
// ❌ WRONG
await insert({ actor_id: user.id }); // user.id is a UserId

// ✅ CORRECT
const contactId = await getContactId(user.id);
await insert({ actor_id: contactId });
```

## Migration History

### Clerk Migration (February 2026)

1. **Removed Supabase Auth**: Replaced `auth.users` with `public."user"` table
2. **Removed RLS**: Authorization moved entirely to the API layer
3. **Removed `auth.uid()`/`auth.jwt()`**: User identity now comes from Clerk JWT verification at the
   API layer
4. **Updated `user_contact_id()`**: Changed from reading JWT claims to taking an explicit
   `p_user_id` parameter
5. **Foreign keys**: All references to `auth.users(id)` changed to `public."user"(id)`

### ID System Fixes (December 2024)

1. **RLS Policies**: Fixed tag policies to use `user_contact_id()` instead of `auth.uid()`
2. **Function Parameters**: Renamed `p_user_id` → `p_actor_id` for clarity
3. **Type System**: Added branded types in Twister SDK

## Best Practices

### In SQL

1. User identity is always passed as a parameter from the API layer — there is no session-level user
   context in the database.

2. Use `user_contact_id(p_user_id)` to resolve a user's Contact/Actor ID when needed.

3. Access control is enforced at the API layer, not via RLS policies.

### In TypeScript

1. Import types from Twister SDK:

   ```typescript
   import {
     type ActorId,
     type ContactId,
     type UserId,
     toActorId,
   } from "@plotday/twister/common/id";
   ```

2. Use conversion functions instead of raw casts:

   ```typescript
   // ❌ Avoid
   const actorId = dbValue as ActorId;

   // ✅ Better (validates UUID format)
   const actorId = toActorId(dbValue);
   ```

3. Keep UserId and ActorId separate:

   ```typescript
   function processActivity(authorId: ActorId, userId: UserId) {
     // Types prevent accidental mixing
   }
   ```

### In Dart

Currently no type-level distinction. Rely on:

1. Naming conventions (`authorId`, `userId`)
2. Code comments
3. Runtime validation
4. Future: Consider extension types

## Quick Reference

| Context                 | Use                   | Access                                      |
| ----------------------- | --------------------- | ------------------------------------------- |
| Authentication          | `UserId`              | Clerk JWT → `public."user".id`              |
| Activity author         | `ActorId`             | `user_contact_id(user_id)` or direct lookup |
| Activity assignee       | `ActorId`             | `user_contact_id(user_id)` or direct lookup |
| Tag actor               | `ActorId`             | `user_contact_id(user_id)` or direct lookup |
| Mentions                | `ActorId`             | `user_contact_id(user_id)` or direct lookup |
| Access checks           | `UserId`              | API layer (no RLS)                          |
| Twist identity          | `ActorId` (TwistId)   | `priority_twist.id`                         |
| Contact without account | `ActorId` (ContactId) | `contact.id` (user_id = NULL)               |

## Summary

**Golden Rule**: If it represents an entity in Plot's domain (person, twist), use **ActorId**. If
it's for authentication/authorization, use **UserId**.

Most Plot entities should use ActorId. UserId is primarily an internal implementation detail of the
auth system.
