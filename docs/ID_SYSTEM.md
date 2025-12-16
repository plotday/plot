# Plot ID System Architecture

## Overview

Plot uses two distinct ID spaces that serve different purposes. Understanding the difference is critical for correct implementation.

## The Two ID Spaces

### 1. Auth User ID (`UserId`)

- **Source**: Supabase `auth.users` table
- **Access**: `auth.uid()` in SQL, `supabase.auth.getUser()` in TypeScript
- **Purpose**: Authentication and session management
- **Usage**: ONLY for auth-related operations (login, permissions checks, etc.)

### 2. Contact/Actor ID (`ActorId`)

- **Source**: Plot's `contact` table
- **Access**: `user_contact_id()` in SQL (reads from JWT `app_metadata.contact_id`)
- **Purpose**: Identifying people and entities within Plot's domain model
- **Usage**: ALL Plot entities (activities, tags, mentions, etc.)

## The Relationship

```
┌──────────────┐         ┌─────────────┐
│  auth.users  │         │   contact   │
│              │         │             │
│  id (UUID)   │◄────────┤  user_id    │
│              │         │  id (UUID)  │◄─── This is the ActorId
└──────────────┘         └─────────────┘
                               ▲
                               │
                         ┌─────┴─────┐
                         │    JWT    │
                         │           │
                         │ app_      │
                         │ metadata. │
                         │ contact_id│
                         └───────────┘
```

### For Authenticated Users

Every authenticated user has BOTH IDs:

1. **Auth User ID**: Their identity in `auth.users`
2. **Contact ID**: Their actor record in `contact` table
   - This is what's stored in activities, tags, mentions
   - Accessible via `user_contact_id()` SQL function
   - Stored in JWT as `app_metadata.contact_id`

The `contact.user_id` field links back to the auth user.

### For External Contacts

People who don't have Plot accounts (e.g., email senders, event attendees):

- **No Auth User ID**: Not in `auth.users`
- **Contact ID only**: Still have a record in `contact` table
- `contact.user_id` is `NULL`

### For Twists

Automated integrations/plugins:

- **No Auth User ID**: Not users
- **Twist ID**: From `priority_twist` table
- Also considered an `ActorId` in the type system

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

Currently uses generic `Uuid` type for all IDs except ActorId, which uses Dart 3.0+ extension types for type safety:

```dart
extension type ActorId(Uuid value) {}
```

## Database Schema

### Key Tables

#### `contact`

```sql
CREATE TABLE contact (
    id uuid PRIMARY KEY,           -- This is the ContactId/ActorId
    email text NOT NULL,
    user_id uuid REFERENCES auth.users(id),  -- Links to auth user
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

#### `user_contact_id()`

Returns the authenticated user's Contact ID from their JWT:

```sql
CREATE FUNCTION user_contact_id() RETURNS uuid AS $$
BEGIN
    RETURN (auth.jwt() -> 'app_metadata' ->> 'contact_id')::uuid;
END;
$$ LANGUAGE plpgsql;
```

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

## RLS Policies

### Correct Pattern

```sql
-- ✅ CORRECT: Check actor_id against user's contact ID
CREATE POLICY "policy_name" ON activity_tag
    FOR SELECT
    USING (actor_id = user_contact_id() OR ...);
```

### Incorrect Pattern (Bug)

```sql
-- ❌ WRONG: Checking actor_id against auth user ID
CREATE POLICY "policy_name" ON activity_tag
    FOR SELECT
    USING (actor_id = auth.uid() OR ...);
```

**Why it fails**: `actor_id` stores Contact IDs, but `auth.uid()` returns Auth User IDs. These are different UUIDs!

## Common Pitfalls

### 1. Using auth.uid() for ActorId Fields

```typescript
// ❌ WRONG
const userId = await supabase.auth.getUser();
await insert({ actor_id: userId.id });

// ✅ CORRECT
const contactId = await getContactIdFromJwt();
await insert({ actor_id: contactId });
```

### 2. Assuming User ID = Contact ID

```typescript
// ❌ WRONG: These are different UUIDs!
const actorId = authUserId as ActorId;

// ✅ CORRECT: Query the mapping
const contact = await supabase
  .from("contact")
  .select("id")
  .eq("user_id", authUserId)
  .single();
const actorId = contact.id as ActorId;
```

### 3. RLS Policy Mismatches

```sql
-- ❌ WRONG
WHERE actor_id = auth.uid()

-- ✅ CORRECT
WHERE actor_id = user_contact_id()
```

## Migration Path

### Recent Fixes (December 2024)

1. **RLS Policies**: Fixed tag policies to use `user_contact_id()` instead of `auth.uid()`
2. **Function Parameters**: Renamed `p_user_id` → `p_actor_id` for clarity
3. **Type System**: Added branded types in Twister SDK
4. **Documentation**: This document!

### Migration File

See: `libs/db/supabase/migrations/20251211185521_fix_actor_id_params.sql`

This migration:

- Updates all tag RLS policies
- Renames function parameters
- Maintains backward compatibility

## Best Practices

### In SQL

1. Use `auth.uid()` ONLY for:

   - Session authentication
   - `user_has_priority_access()` checks
   - Linking to `auth.users` table

2. Use `user_contact_id()` for:
   - Activity authors/assignees
   - Tag actor_id
   - Mentions
   - Any ActorId field

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

| Context                 | Use                  | Function/Access     |
| ----------------------- | -------------------- | ------------------- | ----------------------------- |
| Authentication          | `UserId`             | `auth.uid()`        |
| Activity author         | `ActorId`            | `user_contact_id()` |
| Activity assignee       | `ActorId`            | `user_contact_id()` |
| Tag actor               | `ActorId`            | `user_contact_id()` |
| Mentions                | `ActorId`            | `user_contact_id()` |
| RLS access checks       | `UserId`             | `auth.uid()`        |
| Twist identity          | `ActorId` (TwistId)  | `priority_twist.id` |
| Contact without account | `ActorId` (ContactId | )                   | `contact.id` (user_id = NULL) |

## Summary

**Golden Rule**: If it represents an entity in Plot's domain (person, twist), use **ActorId**. If it's for authentication/authorization, use **UserId**.

Most Plot entities should use ActorId. UserId is primarily an internal implementation detail of the auth system.
