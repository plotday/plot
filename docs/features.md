# Plot Product Features

Internal source document for the marketing team. Organized by benefit pillar: scan the pillar intros for the story, dig into the subsections for specifics. Descriptions are accurate to the shipping product but written at the user level — this is source material, not user-facing copy.

## Positioning

Plot is a unified workspace for human collaboration, focused on supporting you in making things happen and staying on top of what others need from you. It pulls together every conversation that needs a thoughtful human reply — email, team chat, and collaboration from the tools you use (Linear, Docs, etc.) — and organizes it by your projects, roles, and activities.

### Messaging guidance

- **Lead with collaboration and momentum**: make things happen, carry on, keep moving, nothing slips, end the day on something that mattered.
- **Imply identity without naming it**: the reader is a high-agency collaborator whose important work lives outside their inbox.
- **Supporting capabilities stay supporting**: the agenda, scheduling, and to-dos enable the story; they are not the headline.
- **Avoid administrative words** like "filed", "triage", or "inbox zero" framing. Plot is about momentum, not paperwork.
- **Use current product terminology** (below). Older terms — "priority", "activity", "connector" (in user copy) — no longer appear in the product.

### Terminology

| Term | Meaning |
| --- | --- |
| **Thread** | A single conversation or item in Plot — an email thread, a Slack conversation, a Linear issue, or a plain Plot note. Made up of notes. Never "activity". |
| **Note** | One message or piece of content on a thread. |
| **Focus** | A user's own grouping for threads — a project, role, or area (e.g. Customers, Recruiting). Flat list, per-user. Never "priority". |
| **Inbox** | The catch-all for threads not yet in any focus. |
| **Everything** | A single unscoped view of all threads across the Inbox and every focus. |
| **Connection** | One external account linked to Plot (e.g. one Gmail account, one Slack workspace login). "Connector" is the internal/developer term for the package behind it. |
| **Twist** | An optional extension — automation, AI agent, or custom workflow — installed into Plot. |
| **Topic** | A Plot-only shared channel that owns a stream of threads (e.g. "#eng-standup"). |
| **Group** | A reusable, named set of contacts. |
| **Agenda** | The chronological day view: calendar events plus scheduled threads. |
| **To do / Done / Do later** | The thread actions: flag it as yours to do, finish it, or push it to a later day. |
| **Team** | A shared scope on an organization: threads can belong to a team or stay Personal. |

---

## 1. Everything that needs you, in one place

Email, team chat, and the comment threads inside your work tools all arrive as threads in Plot — one place to keep up, with the noise kept out. Plot's AI recognizes what each thread actually needs from you, so newsletters, receipts, and cold outreach never interrupt the conversations that matter.

### Connections

- One connection = one account linked to Plot (e.g. one Gmail account, one Slack user in one workspace, one Linear account).
- Available today: Google (Gmail, Calendar, Chat, Contacts, Drive), Microsoft (Outlook Calendar, Teams channels + DMs), Slack, Linear, Notion (pages and comments), PostHog, Apple Calendar.
- Pro connections: WhatsApp (two-way DMs and group chats), Instagram (two-way DMs and message requests), LinkedIn (two-way messages and connection requests) — read, reply, react, and start new conversations.
- Each connection describes what you can actually do with it (e.g. "See your schedule, respond to invites, and add notes and to-dos to events") when you add it.
- Smart defaults on connect: Plot turns on the channels you'd want (your own calendars, your inbox and sent mail) and leaves the noise off (holiday calendars, other people's shared calendars); big containers like a whole GitHub org wait for you to pick. Everything is toggleable.
- Connections sync quietly in the background, recover automatically if interrupted, and prompt you to reconnect if a permission is missing — no silent failures.
- Removing a connection cleanly clears its items from all devices; re-adding brings them back without duplicates.

### Upcoming connections

- 65+ upcoming connections browsable in-app, across categories from project management and CRM to design, finance, and support.
- Vote for the connections you want (votes show on the website) and get notified when they ship.

### Threads, unified

- Every conversation is a thread: an email exchange, a Slack discussion, a Linear issue, a calendar event, or a plain Plot note — all with the same reading, replying, and organizing experience.
- Threads show who started the conversation first, the faces of everyone on it, and a clean preview line (invisible newsletter spacer-text is stripped).
- Rich notes: full Markdown with live rendering, links, @-mentions of people and twists, speech dictation, and extensive keyboard shortcuts.
- AI-generated titles when a thread doesn't have one.
- Private notes on any shared thread, visible only to you.

### The noise stays out

- Plot's AI reads each incoming thread and recognizes what it needs from you: a reply, an action, time to read, or nothing at all.
- Genuinely passive records — receipts, sign-in confirmations, system acknowledgements — never show an unread indicator or send a notification.
- Low-importance material (promotions, unsolicited pitches, cold outreach) is kept available but never pings you, never lands in a digest, and never lights up a focus.
- Truly time-sensitive threads are flagged urgent and notify you right away — even outside your normal notification hours.
- You stay in control: drag a thread to reclassify it, and Plot honors the correction.

### Getting set up

- Guided first-run flow connects your tools in minutes, grouped into Messaging, Calendars, and Apps.
- Inline OAuth for Google and Microsoft — sign in from the same brand-styled button, no detours.
- Plan-aware: the setup flow shows your plan's connection limits and offers an upgrade when you hit them.

## 2. Organized around what you're trying to do

Threads land in the focuses they belong to — your projects, roles, and areas — sorted by what's important. You always know where to look and what to move forward next.

### Focuses

- Each user has their own flat list of focuses, each with a name, color, and icon. Your focuses are yours — collaborators on the same threads organize them their own way.
- The Inbox catches anything not yet in a focus; Everything shows it all in one view.
- Unread indicators per focus, drag to reorder, and a "More" affordance that collapses a long list down to the active ones.
- Merge one focus into another in a single step, or archive a focus to tuck it away without touching its threads — un-archive any time.

### Roles

- Group your focuses under roles — Work, Personal, Volunteering, and so on — each with its own color and notification settings. Setup asks where you'll use Plot first and names your starting role from the answer.
- Focuses follow their role's color and notifications; override either on a focus and it simply stops following — there's no "inherit" switch to manage. Change a focus's role from its edit form and its look updates to match.
- Every role has its own Inbox — the catch-all for that role. Plot files each thread into the right focus, or that role's Inbox when nothing fits.
- One role keeps the sidebar a simple flat list. With more, focuses nest under collapsible role headers, and only the role you're working in is expanded; a collapsed role still shows bold or an unread dot when a focus inside it would.
- Drag to reorder both roles and the focuses within them. Manage a role's name, color, and notifications from its "…" menu; add a role inline while assigning a focus.

### AI sorting that learns from you

- Describe what a focus is for and Plot matches threads to it — by meaning, not just keywords.
- Two-step creation: describe the focus, then review the threads Plot proposes and deselect any that don't fit. Your deselections teach the matcher.
- Plot sorts by the *kind* of message and who it's from, not just topic: newsletters and long reads stay clear of app notifications, receipts, and promotions; a people-focused focus can favor those you actually correspond with over cold outreach.
- Threads route by the account they arrived through, too — a receipt to your work email lands in your work focus; the same receipt to your personal email lands in your personal one.
- Move a thread into a focus and that sender is welcome there from then on. Every correction makes the sorting better.
- Focus suggestions: adding a focus offers curated starting points (Customers, Recruiting, Reading, Social, …) you can create with one tap, pre-filled and ready to adjust.

### Your list, your order

- Within a focus, threads group by when they need you: today, the coming days, new arrivals, and done.
- Drag a thread between groups to make it a to-do, schedule it for a day, mark it unread, or finish it — and reorder within a day by hand.

### Search

- Truly global search: same results from anywhere, with one tap to narrow to a single focus and back to Everything.
- Full-text across titles and content, with tag and type filters.

## 3. Act without switching apps

Plot isn't a read-only digest. Reply to an email, comment on a Linear issue, answer a Slack thread, change a status, reassign a task — from Plot, and it lands back in the source tool as if you'd done it there.

### Replies that post back

- Reply to any connected thread and the reply goes out through the source — email recipients, Slack channels and threads, Linear comments, Teams chats.
- Email replies give you a labelled **Reply all** (with a count of who's on it) and a plain **Reply** to the original sender, plus per-message recipient editing.
- Threads you start from Plot into a connected channel keep working both ways — follow-up replies post back just like the first message.
- Reactions sync two-way too, including the full standard emoji set with skin tones and Slack workspace custom emoji.

### Status and assignment, two-way

- A thread from a tool that tracks status (a Linear issue, a calendar event) shows one clear status icon — in the header and on the row — and tapping it changes the status right from Plot.
- Assign any thread to yourself or a teammate from the header or hover actions, and filter your list by assignee. For connected tools with assignees (like Linear), changes sync both directions.
- Meeting threads show a **Join** button in the header; every connected thread has an **Open in [app]** action when you do want the source.

### Start anything from one place

- One searchable "Start a thread" picker covers everything: a private note in a focus, a shared Plot thread, a message to a person on whatever connection reaches them, a Slack channel, an email, a Linear issue, a topic, or a chat with a twist — ordered by what you use most.
- Type a name to see the recent ways you've reached that person; type email addresses (even several at once) to message or invite anyone, with unknown addresses becoming pending invites.
- Pick a person and Plot asks how you'd like to reach them, most-used connection first; pick a channel or focus and you're straight into writing.

### To-dos from your messages

- Flagging any note or thread **To do** puts it on your list; **Done** clears it — one consistent language across Plot threads, emails, and connected tools.
- AI task detection (via twists) creates to-dos automatically when someone asks you to do something in Gmail, Slack, or Google Chat.
- Starring a message in Gmail still adds it to your to-dos; unstarring clears it.

### Many at once

- Multi-select your threads the standard way — Cmd/Ctrl-click to pick individual threads, Shift-click for a range — and the header becomes a bulk action bar: to do, done, do later, mark read, move, mute, or assign every selected thread in one tap.

## 4. Your time stays yours

Plot bounds your inbox time to deliberate windows so you can respond, then carry on with the work only you can do. Urgent things still surface; the rest waits its turn.

### Notifications on your schedule

- You set when interruptions are allowed and how long a thread can wait before you see it; Plot holds everything else to those windows. No manual do-not-disturb rules to maintain.
- Genuinely urgent threads — direct requests, deadlines — bypass the windows and notify immediately.
- Batched updates arrive as one AI-summarized digest grouped by focus, instead of a flood of pings.
- Low-importance material never triggers a push, a digest, or an unread dot on its own.
- Native desktop notifications on macOS and Windows, auto-suppressed when the app is focused and respectful of OS Focus/DnD modes.

### Time to respond, on the calendar

- Turn on "Schedule time to respond" for a focus and Plot places short response blocks in your agenda — inside your chosen hours, around your existing events — sized to the threads waiting for a reply.
- Notifications can wait for the block instead of interrupting you mid-flow.

### Agenda and do later

- The Agenda shows your day chronologically: calendar events and scheduled threads together. (It stays hidden until you connect a calendar.)
- Do later: send any thread to a later day; schedule with a date or a specific time.
- Recurring events just work — including editing a single occurrence without touching the series.

## 5. Built for working together

Collaboration in Plot is free — no per-seat fees, ever. Share a thread with anyone, and each person organizes it into their own focuses while the conversation stays one conversation.

### Shared threads

- Share a thread by adding people when you create it, or send anyone its link — thread URLs are globally shareable.
- Each participant files the thread into their own focuses; your organization never dictates theirs.
- On a team, every thread is either team-scoped or Personal. Team threads follow team membership — leave the team, lose access — while explicitly added outsiders (like a customer) keep theirs.
- Step away from any thread with **Leave thread**; the sharing count shows the actual people involved (not you, and groups counted by their members).

### Topics

- Topics are shared channels that live entirely in Plot — "#eng-standup" without needing Slack.
- Create one where you start a thread: name it, scope it to a team if you have one, and pick the people and groups who belong.
- Post to a topic and it reaches everyone in it — no per-thread recipient picking.

### Contacts and groups

- Add a contact or create a named group right where you start a thread; picked several people together? Name them once and they're a reusable group.
- Contact renames are per-user — your label for someone never changes what others see — and names from new connections only ever get more complete, never clobbered.
- Groups work over email connections: address a group via Gmail and Plot expands it to every member's address on send.

### Working as a team

- Assign threads to teammates and filter by assignee (two-way with connected tools — see pillar 3).
- @-mentions notify the right person; per-user read tracking means your "read" never marks it read for anyone else.
- Self-assigned note tasks: each person can mark a shared note as their own to-do, and everyone sees who's on it.
- Real-time sync across all users and devices.

## 6. Yours to trust and extend

Plot is local-first, runs everywhere, keeps private things private, and is built to be extended — from picking your own AI models to installing or building twists.

### Local-first and everywhere

- Fully functional offline: read, write, organize, and complete with no connection; everything syncs when you're back online, across all your devices, with cloud backup.
- Web, macOS, Windows, iOS, and Android — a consistent experience with platform-native touches.
- Share into Plot from other apps via the system share sheet (iOS, Android).
- Fast, calm UI: keyboard-driven command modal, swipe actions on mobile, drag-and-drop everywhere, light/dark/system themes that follow you across devices.

### Private and secure

- Private threads and notes are visible only to you — even on shared threads.
- Connections use standard OAuth; data is encrypted in transit; access control is enforced at the database level.

### Plot AI

- A built-in AI assistant: chat with it like ChatGPT or Claude, mention @Plot on any thread, or start a Plot AI chat.
- It searches the web with cited sources, reads and reasons over your own workspace (threads, notes, focuses) to answer questions, and can propose organization plans — moves, renames, archives — for your approval.
- Choose your models: Claude (Anthropic), ChatGPT (OpenAI), or Gemini (Google), with bring-your-own-key support and custom OpenAI-compatible endpoints (local models, proxies).

### Twists

- Twists are optional extensions — automations, AI agents, and custom workflows — that run securely inside Plot with granular, per-permission consent.
- Built-in twists handle calendar sync, AI task detection from messages, project sync, contacts, and chat.
- Twists can present interactive buttons on threads and update items in place instead of duplicating them.

### Build your own

- The Twist Creator (Twister) is a fully typed TypeScript SDK with CLI tooling, real-time logs, and an open marketplace — anyone can build and publish a twist or connector.
- A no-code twist builder is included on Pro and Team plans.

---

## Plans and pricing

- Simple pricing, no per-seat fees: everyone collaborates in Plot for free; you pay only for the connections that bring your conversations together.
- **Free** — 2 connections, 1 twist. For individuals and teams using a few core tools.
- **Core** — 5 connections, 2 twists. $15/mo, or $12/mo billed annually.
- **Pro** — unlimited connections and twists, no-code twist builder. $25/mo, or $20/mo annually.
- **Team** — shared org connections (per 50), unlimited twists, no-code twist builder. $124/mo, or $99/mo annually; scales per 50 connections.
- 30-day Core trial for new signups, with reminders and a graceful downgrade.
- Annual billing saves 20%. Stripe-powered checkout and self-service subscription management.
- Plan changes propagate instantly to all devices.

### Organizations

- Create an organization for team billing and shared limits, with admin and member roles.
- Invite by email (pending invites auto-apply on signup) or let anyone with your email domain join automatically.
- Members get the highest plan across their personal subscription and org memberships.

---

## In the product, not yet in the story

Real, shipping features the team hasn't yet decided how (or whether) to market. Don't lead with these; don't deny them either.

- **Sessions and time tracking** — A focus timer (pomodoro-style, customizable length) with a progress ring in the header; time tracked per focus, including automatic accrual from calendar events you attended; manual adjustment of a day's tracked time. Fits the "your time stays yours" story but the team is still deciding if/where it belongs in marketing copy.
