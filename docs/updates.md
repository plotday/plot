## Next release

### Threads

- On your phone or tablet, swipe left or right while reading a thread to jump to the next or previous
  one in your list — like flipping through email.
- When you move a thread to another focus, Plot now puts the focuses you usually send threads to from
  its current focus at the top of the list — and remembers that across your devices, so the focus you
  reach for most is right there.

### Notifications

- Plot now explains how notifications help and asks to turn them on once you're set up, instead of
  springing the system prompt on you. If notifications later get switched off, Plot offers to turn
  them back on — and you can always say no.

### Opening the app

- The app now reopens the focus you last had open, instead of always starting on your Personal
  inbox. A scheduled event or focus block happening right now still takes you straight there.
- Opening a role now reopens the focus you last had open in that role, instead of always its first.

### Fixes

- The back arrow in the header is easier to tap. Its touch area now fills the full height of the
  header and stretches from the screen edge across to the title beside it, so you no longer have to
  land precisely on the small chevron.
- Fixed Android not asking for permission to send notifications on a fresh install. Notifications now
  work out of the box instead of staying silent until you enabled them in system settings yourself.
- Background syncing keeps itself healthy. The periodic checks that keep your connected mail,
  calendars, drive, and chat up to date now recover on their own if one ever stalls — previously a
  single hiccup could quietly stop a connection from updating until you reconnected it.
- Reading or reordering a thread on one device now reliably shows up on your other devices. Previously
  a thread you'd read could keep showing as unread elsewhere, and dragging a to-do to a new spot
  sometimes didn't carry over — now both sync across your devices, and threads that had got out of
  sync this way fix themselves.
- Marking a new thread "To do" now drops it neatly at the bottom of your Active list, right above your
  unread items — instead of jumping to the very top. It also no longer flickers through the Done
  section on its way there; it lands in Active straight away.
- New threads arriving from your connected accounts (email, chat, and the like) now appear in the
  right place straight away. Previously a freshly arrived message could briefly show in Done before
  jumping up to your Active list a moment later.
- Adding a connection now shows a spinner on the connector you tapped while it sets up, so it's clear
  Plot is working during the second or two before the setup screen appears. Previously the tapped
  connector gave no feedback (or the spinner landed on the wrong row), making it look like nothing
  had happened.
- The red "reconnect" dot on the More tab no longer sticks around when there's nothing to reconnect.
  Previously a connection you'd already replaced — for example LinkedIn after reconnecting it — could
  keep the badge lit even though the Connections screen showed everything as fine, with no way to
  clear it.

## 1.5.0+364 — 2026-06-22

### Notifications

- Plot is better at telling promotional and automated mail apart from messages that actually matter, so you get fewer pointless notifications while real conversations still come through.

### Fixes

- Low-signal mail — newsletters, receipts, promotions, and automated notifications — now lands in
  your FYI focus automatically. Previously it only went to FYI if you moved it there yourself, so new
  items ended up scattered across your other focuses; now Plot files them in FYI as they arrive.
- A connection that loses its saved sign-in — for example LinkedIn after reconnecting — no longer gets
  stuck on "Syncing" forever. Plot now notices the credentials are gone and prompts you to reconnect,
  and it gives up and offers "Reconnect" if a first sync simply never finishes.
- Opening Connections is fast again. The screen could take ten seconds or more to appear — especially
  if you had access to a lot of connectors — because it was looking each one up separately. It now
  loads everything in one go and opens almost instantly.
- Signing in is more reliable, especially the first time on a new device. If the server is briefly
  slow during sign-in, Plot now keeps trying for a few moments instead of immediately giving up with
  a "taking too long" error.

## 1.5.0+362 — 2026-06-20

### Fixes

- Keyboard shortcuts on Mac and Windows now keep working after you switch away from Plot and back
  (for example with ⌘-Tab). Previously the desktop app could lose its keyboard focus on return, so
  shortcuts like ⌘K and ⌘/ did nothing and you couldn't start typing until you clicked into the
  window. Plot now restores focus the moment its window comes forward.
- Reordering your list, bumping a thread to the top, or marking something as active no longer makes
  Plot notify you about it again. Push notifications now reappear only when a thread has genuinely new
  activity, so tidying up stays quiet.
- Plot's own automated emails — like "New sign-in to your Plot account" — no longer show up as items,
  or send you notifications, when you connect the email account they were sent to.
- Email summaries no longer arrive when you've already been using Plot. If you opened the app at any
  point after a notification came in, Plot now correctly skips the follow-up email — even if you'd
  since closed the app. Previously closing Plot could make it forget you'd been active, so the email
  went out anyway.
- Roles you add, rename, or reorder now appear on your other devices right away. Previously a new
  role only showed up there after the app was restarted or reconnected.
- A thread you'd already read from a connected account (like Gmail) no longer pops back to unread on
  its own. When the source re-synced a message you'd read, Plot could mark the thread unread again on
  every device; now reading it sticks unless genuinely new content arrives.
- "Skip active for threads like this" now works for incoming emails, messages, and other connected
  items — not just threads you start yourself. Once you skip a kind of recurring notification, future
  ones like it are automatically kept out of your active list instead of resurfacing each time.

## 1.5.0+361 — 2026-06-20

### Drafts

- Your drafts are never lost. Start as many as you like — each one is saved and shown in a new Drafts
  list at the top of the new thread screen, so you can pick up right where you left off. Discard one
  with the ✕, and turn on "show archived items" to see and restore your most recently discarded drafts.

### Attachments

- When you attach a photo or file to a note — from the file picker, the camera, or by pasting — its
  preview now appears instantly instead of waiting for the upload to finish. The file keeps uploading
  in the background while you carry on typing, and sending waits just long enough for any in-progress
  upload to complete.

### Notifications

- Push notifications now show which focus an update belongs to in the notification header — and, if
  you use more than one role, the role as well (for example "Plot › Marketing"). When several updates
  arrive at once from different focuses, you can tell at a glance where each one landed.

### Fixes

- The plan-upgrade screen reads more clearly: the subscription terms are lighter and easier to scan,
  and the Terms of Service and Privacy Policy are now tappable links instead of plain web addresses.
- Plot no longer signs you out — or shows a "Plot signed out" notification — just because your phone
  briefly lost its connection (for example overnight or in a tunnel). It now only asks you to sign in
  again when your session is genuinely no longer valid, and stays signed in through temporary network
  drops.
- Emoji reactions now sit centered in their pills on desktop and mobile instead of sitting a little
  low.
- Starting a new thread by typing an email address and then picking a connection like Gmail now keeps
  that address as the recipient, sends the thread as shared rather than private, and leaves it in the
  focus you were already in instead of jumping to a different one.
- When a focus has nothing unread, the unread-filter button in the header now shows as dimmed and
  inactive instead of looking like a button you can press.
- Merging one focus into another is now instant — the focus you merge away disappears and Plot takes
  you to the destination right away, instead of leaving the old focus sitting in your sidebar for a
  moment.

## 1.5.0+359 — 2026-06-19

### Connections

- Connections that carry a conversation as a run of separate messages — like Slack channels — can
  now group those messages into a single thread instead of starting a new one each time. Turn it on
  per connection with **Group related messages into conversations**: Plot folds a message into the
  ongoing conversation when it's clearly a continuation and starts a fresh thread when the topic
  changes, so one discussion stays in one place instead of scattering across your inbox. Direct
  messages stay as a single running thread.
- The connection setup and edit screens are tidier and easier to follow. The connected account now
  sits at the top as a header, and the list of things to sync gets a clear heading that names them —
  for example **Teams to sync** or **Folders to sync**. Each channel lines up flush on the left with
  the other fields, and every on/off switch sits in a single column down the right, so the list is
  easy to scan.

### Roles & focuses

- Notifications in Settings now open your role's default notification settings. If you have more
  than one role, Plot asks which role first; if you have just one, it goes straight there. You can
  still fine-tune notifications for an individual focus from that focus's menu.
- When you have more than one role, your focuses now show the role they belong to everywhere they
  appear outside the sidebar — in the header, on threads, and in pickers — written as **Role ›
  Focus**, with the role shown in its own colour. That makes it easy to tell, say, a Work focus from
  a Personal one at a glance. The sidebar normally stays as-is since it already groups focuses under
  each role — but when you search, where the results are listed flat, each focus now shows its role
  too, so you can tell apart same-named focuses like each role's Inbox. If you only have one role
  nothing changes.
- When you have more than one role, you can now find a focus by typing its role name in any focus
  picker — switching focuses, moving or merging threads, or choosing where a new thread goes. Typing
  a role surfaces every focus under it, alongside matches on the focus's own name.
- Your browser tab and desktop window title now include the focus you're viewing (and its role when
  you have more than one), so Plot is easy to pick out among your open tabs and windows.
- Low-signal mail — newsletters, receipts, promotions, and service notifications — now gathers in an
  **FYI** focus under each of your roles, shown just below that role's Inbox, so work newsletters
  land under Work and personal ones under Personal. It keeps the quiet stuff out of your Inbox while
  staying one tap away, and it never sends notifications. Otherwise it's an ordinary focus — you can
  reorder it and change its colour. Your role's Inbox is now reorderable the same way.
- The Everything view is now a true cross-focus view rather than being quietly tied to one focus.
  When you're in Everything, focus-specific controls step aside and the header simply reads
  "Everything"; starting a thread there files it into your main Inbox unless you pick a focus (or it
  follows your usual most-recent focus for the people you're messaging).
- Choosing where to start during setup is clearer. Each choice — Work, Project, Personal, School,
  Other — now has an icon, and picking one moves you straight on: when your choice needs a name
  (your workplace or project) Plot asks for it on its own step with the box ready to type, instead
  of a field tucked below the list that was easy to miss. Naming it is required, and you can press
  Enter to continue or use Back to pick a different one.
- In the sidebar, each role now reads clearly as a heading above the focuses it groups: the role
  name shows in small uppercase lettering, the open role's focuses sit just inside a faint line in
  the role's colour, and a collapsed role shows a quiet arrow so it's obvious you can tap to open
  it. The bold text and unread dot still tell you, at a glance, which roles have active or unread
  work inside.
- When you move a thread to a focus, the picker now surfaces the most useful focuses first: the
  focus you most recently moved a thread into rises to the top, then focuses in the same role as the
  thread you're moving, then everything else. Triaging a run of threads is quicker because wherever
  you just sent one is right there for the next. It works the same whether you move a single thread
  or several at once, and your Inbox is now an ordinary focus in this list rather than always pinned
  to the bottom.

### Sending messages

- If a message you send to a connected account — like a reply to a Gmail thread or a new email you
  start from Plot — can't be delivered, Plot no longer drops it silently. Brief network hiccups are
  retried automatically, and if it still can't be sent the thread shows as unread and the message is
  marked **Failed to send** (with the reason when one is available). You can tap **Retry** to send
  it again, or **Discard** to remove it. This works across your connected accounts, not just Gmail.

### Thread swipe actions

- Swiping a thread now follows a simple **right to act on it, left to file it** pattern. A short
  swipe **right** marks a thread **done** (and clears unread updates); a long swipe right starts
  working on it (**To do**), or — if it's already on your list — pushes it to a later day (**Do
  later**). A short swipe **left** **moves** it to another focus, and a long swipe left opens the
  **menu** of more actions. In your Done list, where there's nothing left to clear, a short swipe
  right instead puts the thread back on your list (**To do**) and a long swipe right schedules it
  (**Do later**).

### Agenda

- On a phone, tapping an event in your agenda now opens that focus's list with the event's day laid
  out at the top, so you land in context instead of jumping straight into the event. (On larger
  screens, where the list and the event sit side by side, tapping still opens the event directly.)

### Focuses

- Your active to-dos now stay put at the top of a focus — new and unread items arrive below them, so
  incoming messages no longer push your committed work down. A new envelope toggle in the header
  shows only unread when you want to catch up.

### Subscriptions

- You can now subscribe to Core or Pro right inside the app on iPhone, iPad, and Mac, and your plan
  stays in sync no matter where you signed up — if you started a plan on the web, the apps recognize
  it automatically.

### Dialogs

- The action buttons at the bottom of dialogs are clearer. The main action now stands out and, on
  larger screens, sits beside any quieter secondary actions like Archive or Delete rather than
  stacking with equal weight; on phones the buttons stack neatly, each clearly its own button.
  Destructive actions turn red as you hover or select them, and you can still move between buttons
  with the arrow keys.

### Performance

- Scrolling back through a focus or your full list of threads is now much faster, especially if you've built up a lot of history — loading older threads no longer slows down as your thread count grows.

### Fixes

- When you're viewing a filtered list of threads — only unread, only skipped, or a single focus —
  and mark one done, Plot now moves to the next thread in that same list instead of jumping to a
  thread the filter was hiding. When the filtered list runs out, your finished thread stays open
  rather than dropping you into a new draft.
- Switching on "show only unread" no longer leaves a loading spinner stuck at the bottom of the
  list. The filtered list now knows it's complete instead of trying to load more forever.
- Selecting text in a field now uses the same subtle highlight as the note editor, instead of a
  heavy grey that washed out the selected text. It's easier to read what you've selected in both
  light and dark mode.
- Dialogs you open with the mouse no longer pre-highlight a button. The highlight now follows your
  pointer as you hover and clears when you move away, while opening a dialog from the keyboard still
  focuses its main action so you can press Enter right away.
- On phones, when you have more than one role, the focus list no longer collapses every role at once.
  The role you were last working in stays open — so when you return to the list after viewing
  another tab, you land back where you left off instead of facing a fully collapsed list.
- Accounts with very large numbers of threads (especially heavy use of moving threads between
  focuses) could see the app sync slowly or briefly fail to load. Plot's behind-the-scenes
  filing now does far less redundant work, so syncing stays fast and reliable at that scale.
- A connection could get stuck showing "Syncing…" indefinitely if its first sync was paused partway
  through. Plot now detects these and resumes them automatically, so the spinner clears and your
  messages and items finish loading. And if a first sync genuinely can't finish after several
  automatic retries, the connection now shows a clear "Reconnect" prompt instead of spinning forever.
- When you connect an account like LinkedIn that has a single thing to sync, the setup screen now
  defaults the **Label** to your account name (for example "Kris Braun") instead of "Personal", and
  no longer shows a "Select what you'd like to sync" prompt when there's nothing to choose.
- Connection logos now show correctly for LinkedIn, Apple, and Linear, instead of appearing as a
  blank square in the setup and edit screens.
- On the web app, emoji reactions now sit centered in their pills instead of dropping toward the
  bottom edge.
- When your plan changes to one that doesn't include premium connections — like LinkedIn — those
  connections are now properly disconnected. Previously a premium connection could linger after a
  downgrade or cancellation even though your new plan no longer covered it.
- When a service can't be reached while you're connecting an account, Plot now shows a clear
  "temporarily unavailable — please try again" message instead of a generic "Server Error".
- When you connect an account, the **Continue with…** button now stops spinning as soon as the
  sign-in window opens. Previously, if you closed or stepped away from that window without
  finishing, the button could keep spinning for several minutes; now it returns to normal right away
  so you can try again.
- On the web app, refreshing the page or opening a link to a specific focus or thread now keeps you
  on that page. Previously it would load for a moment and then bounce you to your Personal Inbox;
  now a refresh stays put and a shared link opens exactly the focus or thread it points to.
- The note editor's reply options no longer get cut off when a "Reply to {name}" option has a long
  name — the name now shortens to fit so the other options stay fully visible.
- Notifications now lead with who a message is from and what it's about. A single new thread shows
  the sender's name and the thread's title — for example **Phil Lee · Workshop ideas** — instead of
  the connection it arrived through (no more "Gmail (Plot)" standing in for the sender). When
  someone replies to a thread you've already read, the notification credits the person who replied,
  not whoever started it. The connection name is no longer shown.
- Search and filter boxes now look consistent everywhere. The magnifying-glass icon stays on the
  buttons that open search, and the boxes themselves rely on a clear placeholder — so pickers like
  emoji and link search no longer look different from the rest.
- Showing archived items is now a single command. Where there used to be separate toggles for
  archived focuses and for archived threads and notes, one **Show archived items** command now
  reveals all of them together — archived focuses in your list, plus archived threads and notes
  inside a focus or thread — and stays in sync wherever you turn it on or off.
- Turning off AI in settings is now respected everywhere. With AI off, Plot still sorts incoming
  threads into your focuses using your own past filing — just without the AI step — and skips
  AI-written titles, notification summaries, and focus suggestions entirely. Previously a few of
  these could still run, especially on paid accounts, even with AI switched off.
- Connecting Todoist now works. The button correctly reads "Continue with Todoist" with the Todoist
  logo, instead of showing "Continue with Other" and failing when tapped.
- Connecting LinkedIn, Instagram, or WhatsApp now works. Starting the connection no longer fails
  with an internal error before the sign-in screen could open.
- During setup, the **Pro** label now shows on Pro connections in the "Connect your tools" step, so
  it's clear which ones need a Pro plan before you start connecting them.
- On phones and other single-column layouts, marking a thread done — or changing its state another
  way — while you have it open no longer jumps you to a different thread. The thread stays open so
  you can keep reading or make more changes, and you go back to the list whenever you're ready. On
  wider layouts, where the list stays visible beside the open thread, it still moves you on to the
  next one.
- On thread rows, the status, mute, and assignee icons on the right now line up exactly with the
  date shown above them, instead of sitting a couple of pixels off to the side.
- Focuses no longer disappear from your sidebar when you archive an old, unrelated focus.
  Previously, archiving a focus could silently hide other live focuses that happened to have been
  organised under it in the past, even though they were still active and assigned to a role. Every
  live focus now stays visible regardless of what you archive around it.
- Icons that sit beside text — in the sidebar, menus, pickers, and the new-thread form — are now a
  touch smaller so they sit level with the words next to them instead of looking oversized, and they
  line up in a consistent column. The result is a cleaner, less crowded look throughout.
- Your Personal role's Inbox now shows just like every other role's Inbox — with the inbox icon, its
  role name (**Personal › Inbox**), and the role's colour. Previously it appeared as a plain "Inbox"
  with no role and the wrong colour, making it hard to tell apart from your other roles' Inboxes.
- Opening an older thread you hadn't looked at before now loads its messages faster. Plot fetches
  the thread's messages, tags, and reactions together in a single request instead of three separate
  ones, which cuts the wait — most noticeable on threads with a lot of history.
- Moving a notified message to another focus no longer sends you a second notification for it. The
  "already told you about this" memory now follows the message itself, so re-filing it stays quiet
  unless there's an actual new reply.
- Reading a thread on one device now reliably marks it read on your other devices. Previously, when
  you opened a thread that was in your Doing list, the unread dot cleared on the device you read it
  on but stayed on your other devices.
- Changes you make to a thread — marking it done, reordering it, scheduling it, or reading it — now
  reliably reach your other devices even if your connection drops or hiccups right as you make them.
  Previously a brief network glitch could silently drop the change, leaving that device out of sync.
- New accounts now reliably start in the welcome and setup flow, and stay there until you've chosen
  where to start — previously some new accounts skipped setup entirely and landed in the app with a
  default space they never picked.
- If you quit Plot partway through the welcome and setup flow, it now picks back up the next time
  you open the app instead of disappearing for good. Setup only goes away once you've finished it or
  closed it yourself.
- Text boxes you aren't currently typing in — like the email and password fields on the sign-in
  screen — no longer look greyed-out as if they were disabled. They now match the box you're typing
  in.
- The welcome and getting-started messages now reliably show the Plot logo. Some accounts were
  seeing a generic placeholder icon on these messages instead.
- A "Reconnect" prompt no longer lingers for a connection you've already switched off. Previously,
  if a connection's sign-in expired and you turned all of its syncing off instead of reconnecting,
  the prompt kept nagging with nothing to act on. It now only appears for connections that are still
  active.
- When someone accepts a meeting invitation, the "Accepted" email no longer shows up needing your
  attention — it's treated as a low-signal notification. Declines and tentative replies still come
  through normally, since those may need you to follow up.
- Emoji reactions on a message now line up vertically with the task circle and other icons next to
  them, instead of sitting slightly too high.
- Starting a new thread again shows the "Private notes" section, so you can file a private note
  straight into one of your focuses. The section had gone missing for some accounts when the picker
  loaded before your focuses had finished syncing.
- On a narrow or single-column layout, tapping a role in the Focus list now just opens it to reveal
  its focuses so you can choose one, instead of jumping straight into its first focus — which had
  left no way to pick a different one.
- Plot no longer rebuilds its local data and signs you out every time you open it. A recent change
  left the app re-downloading everything from scratch on each launch — making startup slow and, on a
  large account, occasionally bouncing you to the sign-in screen before it finished. Launches are
  now fast again and your data stays put between sessions.
- Signing in on a new device is much faster, especially on accounts with a long contact history.
  Setup no longer waits to download your entire address book before showing you anything — it loads
  what the first screen needs and fills in the rest in the background. Names on people you don't
  have saved yet may take a moment to appear right after sign-in.
- Opening a private note no longer flashes a faint, empty reply bar above the composer for a split
  second before it vanishes. Private notes have no one to reply to, so that bar is now correctly
  absent from the moment the thread opens.
- On phones, the back gesture now keeps your place instead of dropping you out of Plot. Backing out
  of Search clears your search text first, then leaves the tab; backing out of Agenda, Search, or
  the More menu returns you to the screen you came from rather than closing the app. And in the
  new-thread form, back now steps you back through the form — for example, from choosing how to
  reach someone back to where you started — instead of jumping straight out to your thread list.
- On phones, the **Schedule focus block** form no longer cuts off the date and time — the year and
  the end of "a.m."/"p.m." were getting clipped. The stepper rows now give the date, time, and
  duration more room while keeping the chevron buttons comfortably tappable.

### Fixes

- Thread times now reflect the message's original time (e.g. when an email was sent) instead of when
  Plot received it.

## 1.4.0+354 — 2026-06-15

### Reactions

- Emoji reactions you add to messages from Microsoft Teams, Google Chat, LinkedIn, Instagram, and
  WhatsApp now sync back to the original conversation, posted as you — so the people you're chatting
  with see your reaction where the message lives, not just inside Plot. Each person's reaction is
  attributed to their own account, and removing a reaction in Plot takes it down on the other side
  too.

### Codes & confirmations

- When a one-time verification code or a "confirm your account" email arrives, Plot now pops up a
  quick prompt for five minutes after it was sent — tap to copy the code, or tap a button to confirm
  your account — so you don't have to dig the message out before it expires. If you're not looking
  at Plot, you'll get a notification instead, and a newer code replaces an older one. Plot is
  careful here: it only surfaces confirm links from verified senders, and never "this wasn't me" or
  password-reset links.

### Navigation & layout

- On medium-width windows and tablets — wide enough for two panels but not three — your focuses and
  agenda are reachable again. The top-left button now shows a menu icon that slides them in as a
  panel over your threads; pick a focus, tap away, or press Esc and it slides back. Previously that
  button did nothing at this size, leaving no way to switch focuses without resizing the window.
  Wider windows still keep the sidebar docked as always.
- Plot's phone navigation now has five proper tabs along the bottom — Focus, Agenda, New, Search,
  and More — and each keeps its place as you move between them. **Search** is its own tab now,
  looking across all your threads; open a result and you stay in Search, so going back returns to
  your results. **Starting a thread** keeps the bottom bar like the other tabs, and you can step
  back from the compose screen with a new back arrow. **More** opens your settings as a full page
  instead of a pop-up sheet. And a focus's thread list now shows a back arrow to return to all your
  focuses.
- The item you're viewing now stands out more clearly with a subtle colored outline — the same
  treatment across the sidebar focus list, the agenda, and your thread list.
- On mobile, the system back gesture from a priority's activity feed now returns you to whichever
  bottom-nav tab you came from (Priorities or Agenda) instead of closing the app. Tapping the
  Priorities or Agenda nav itself stays a clean replacement — back from there exits as you'd expect.
- On mobile, opening a focus's thread list now keeps its bottom-nav tab highlighted — Focus or
  Agenda, whichever you came from — so it's always clear where you are, instead of the bar showing
  nothing selected.
- Browser back and the Cmd+[ shortcut now walk only the meaningful navigation steps. Switching
  between priorities on the same feed no longer accumulates one history entry per priority you pass
  through, so a single back lands on the page you actually came from instead of stepping through
  every priority you opened.
- Cleaner top edge on iOS and Android — the priority header now blends into the status bar so they
  read as one strip, and the agenda starts with a clean divider line above the first day instead of
  bleeding into the status bar background.
- On the Mac, the Agenda, Focus, Search, and More tabs no longer tuck their first row under the
  window's red/yellow/green buttons — each now starts in a clear band below them. The Search tab
  also sits on the same background as your thread list, so searching no longer drops you onto a
  mismatched panel.
- Cleaner new-thread page on mobile — the priority header is gone, replaced by a single back button
  above the page, so the focus stays on what you're writing. The back button also appears
  immediately when you tap "New" from the bottom nav, instead of briefly flashing the priority's
  full header during the transition.
- Long lists and forms in pop-up dialogs now fade softly at the top and bottom when there's more to
  scroll, so it's clearer at a glance when content continues past what's visible.

### Focuses

- Low-signal mail now gathers in a new **FYI** focus, sitting just above Everything. Promotions,
  newsletters and long reads, receipts, and routine notifications land there automatically — so your
  Inbox stays focused on messages from people. FYI is quiet by default: it doesn't notify you and
  never lights up the unread count, so you can skim it whenever you like. Move anything out into
  another focus and Plot learns to send similar messages there from then on.
- New to Plot? Setup now asks where you want to use Plot first — Work, Personal, Volunteering,
  School, or Other — and names your first role from your answer (tell it where you work, and that
  becomes the role's name). You can add more roles later.
- Merging one focus into another is now instant and reliable. The merge happens in one step on the
  server — previously each thread moved one by one, which could leave a half-merged focus if
  interrupted and made Plot rethink the sorting of everything in your workspace, slowing things down
  for a while after a merge.
- Creating a focus now starts by choosing which role it belongs to — pick one of your roles or add a
  new one on the spot. Then Plot suggests common focuses (like Customers, Reading, or Social) you
  can create with one tap — pick one to open the create form already filled in, or choose **Other**
  to start from scratch. Once you've made a focus from a suggestion it drops off the list, on every
  device you use. Role is now the first field when you create or edit a focus, and the same quick
  **Add role** option appears anywhere you pick a role.
- Threads now land in the right focus based on which account they arrived through — a receipt to
  your work email goes to your work focus, while the same kind of receipt to your personal email
  goes to your personal one. Plot learns this automatically from how you file threads.
- You can now **archive a focus** from its menu (the **…** next to a focus, just below **Merge
  into…**). Archiving tucks the focus away — it disappears from the sidebar and from the focus
  pickers — without touching its threads, which stay right where they are and keep showing up in
  search and filters. Turn on **Show archived** to bring it back into view, or un-archive it from
  the same menu.
- Focuses now sort threads by the _kind_ of message and who it's from, not just the topic. When you
  describe what a focus is for, Plot uses that description to keep the right things together —
  newsletters and long reads stay clear of app notifications, receipts, and promotions — and a
  people-focused focus can favor those you actually correspond with over cold outreach. If you move
  something in that didn't fit, that sender is welcomed from then on. Existing focuses pick this up
  the next time you edit them.
- Creating a focus now finds the right threads to pull in. When you describe a new focus, Plot looks
  across everything in your account — both by meaning and by keyword — so the threads that genuinely
  belong (your engineering logs, that recurring project, and so on) actually show up. Before, it
  could only ever look at a sliver of your threads, so obvious matches were missed and the
  suggestions felt random.
- Finding matching threads when you create a focus is quicker, and the results open right away with
  a friendly progress indicator while Plot looks — instead of leaving you waiting on a button.
- The matching threads you review when creating a focus now look like they do everywhere else — with
  their source logo, who they're from, the title, and a preview — so you can tell them apart at a
  glance instead of reading a bare list of titles. Near-identical repeats (like a string of
  automated "version packages" notifications from the same sender) are trimmed down, and exact
  duplicates no longer show up twice. Plot now pre-checks only the threads it's confident about and
  leaves the borderline ones for you to opt in, so you spend less time un-checking things that don't
  belong.
- Merge a focus into another: when a focus has threads, its menu now offers "Merge into…" — pick a
  destination and all the threads move there, then the focus is archived. An empty focus still
  archives in one tap.
- Your Inbox now reads "Inbox" everywhere you pick a focus — scheduling a focus block, moving a
  thread, choosing where a new thread goes — instead of occasionally showing its old internal name
  "Everything". It also carries the inbox icon in those pickers, matching the sidebar.
- The focus sidebar now leads each item with its own icon, with the unread dot moved to just after
  the name. Focuses (and your Inbox) that have active threads show in bold so they stand out at a
  glance. Your Inbox is labelled "Inbox" again (it could show as "Everything") and, along with the
  Everything view, now has its own inbox icon — both are fixed tiles, so they aren't editable like a
  focus.
- You can now change a focus's icon when editing it, and pick one from a visual icon grid when
  creating or editing a focus.
- Priorities are now Focuses — a flatter, simpler way to organize. Instead of nested folders, you
  keep a single list of focuses, each with its own icon and color. Everything not sorted into a
  focus lives in your Inbox, and a new Everything view shows all your threads — Inbox and every
  focus — in one place. Creating a focus is now two quick steps: describe what belongs in it, and
  Plot finds the matching threads already in your account so you can pull them in (or uncheck the
  ones that don't fit) before it's created. Archiving a focus tucks its threads back into your Inbox
  and brings them right back if you un-archive it.
- Teams now have firewalled priorities. Threads under a team-tagged top-level priority are visible
  only to current team members. Joining a team automatically creates a priority for the team in your
  tree; archiving your last top-level priority for a team prompts to leave the team.
- A new toggle in each priority's header lets you choose whether the activity feed rolls up threads
  from sub-priorities or stays focused on just this priority. The folder-tree icon sits between the
  title and the timer; tap it to switch between "Hide sub-priorities" (the default — sub-priority
  threads are surfaced inline) and "Show sub-priorities" (only threads filed directly on this
  priority appear in the feed, so the sub-priorities themselves stand on their own). Opening a
  priority from the agenda defaults to the focused view, since the agenda already groups
  sub-priority content under each block.
- Connector channels (calendars, mailboxes, projects) now route their threads to the right priority
  automatically — when you add a priority or a connection, Plot picks a home for each channel based
  on your priority names and channel context, and existing threads from that channel move too. Your
  own moves still override the default.
- Set who to share new threads with by default, per priority — add contacts, teams, and email
  invites in the priority settings and every new thread filed there is pre-shared with them (still
  removable before sending)

### Starting a thread

- Starting a thread is quicker, especially on phones. The list of people, channels, and focuses is
  ready the moment you tap **New** — Plot prepares it in the background while you're working instead
  of building it from scratch on first open, so it no longer pauses for a beat before the options
  appear.
- You can now send a thread to a group through email connections like Gmail — Plot automatically
  expands the group to its members' email addresses. Group members must have an email address.
- The "People" list where you start a thread now shows your groups alongside your contacts, and
  keeps the ones you've used most recently at the top. Add a contact or create a group and it jumps
  straight to the top, ready to message. Search now finds any group by name too.
- You can now add and edit contacts and groups right where you start a thread. In the People and
  twists section, tap **+ Contact** to add someone by name and email, or **+ Group** to gather
  people into a named group. Hover any person or group row — or press ⌘Enter — for a **…** menu to
  edit it: rename a contact, or rename a group and change who's in it. And when you've picked
  several people together, naming them turns the set into a reusable group, so the next thread is
  one tap away.
- You can now create Plot **topics** — shared channels that live entirely in Plot — right where you
  start a thread. In the Channels section, tap **+ Topic**, give it a name, pick a team (if you're
  on one), and choose the people and groups who belong, then it joins your list of channels. Posting
  a thread to a topic sends it to everyone in the topic, so you don't pick recipients each time.
- Starting a thread in a channel (like a Slack channel or a Linear project) now shows the channel
  itself, not a recipient list. The top of the compose screen names the connection, and below it a
  **Channel** field shows where the thread will go — tap it to switch to any other channel on that
  connection. There's no contacts row for channels, since who sees it is decided by the channel's
  membership.
- Starting a thread now opens into clear, calm sections — the people and assistants you talk to,
  your channels (like a Slack channel or a Linear project), and your private notes by focus — each
  shown as simple pills you can find with one "Start a thread" search at the top. Pick a person or
  group and Plot asks how you'd like to reach them (a Plot thread, email, a chat app…), with your
  most-used connection first; pick a channel, assistant, or focus and you go straight to writing.
  The person you picked stays pinned as a removable chip — press Esc or tap its × to step back,
  right where you left off.
- Starting a thread feels calmer and more focused. The first step now opens with a clean, underlined
  prompt that fades into the page, roomier rows that are easier to tell apart, and a list that fills
  the page with soft fading edges. Plot's own threads are simply a Plot thread now — keep one to
  yourself or share it by adding people, even on a thread you started from a focus — and your team
  shows alongside it when you're on one. Click the connection at the top (or press Esc) anytime to
  step back to that first list, right where you left off.
- The new-thread picker now shows each option on two lines: the connection on top — tinted with the
  colour of the focus you use it for most — and the people (with their faces) or the channel below.
  Plot's own items are now your focuses (start a note in any focus), the people you message (a
  shared thread), or a twist, instead of plain "Note" and "Chat" rows. You can paste several email
  addresses at once — separated by spaces, commas, or semicolons — and write them as "Kris Braun
  <kris@plot.day>" to invite someone by name, which creates a named contact for them. When two
  people share a name, the picker shows the email address that tells them apart, and hovering any
  row reveals everyone's full name and address.
- Starting a thread is now a quick two-step flow. First pick what you're making from one searchable
  list — a Plot thread, or a message straight into a connected app (a Slack channel, a Gmail thread,
  a Linear issue, a LinkedIn message, a Google Task, and so on) — ordered by what you use most. Type
  a name to reach someone you've talked to before, or type any email address to start a chat or
  message to that person on whatever connections can reach it. Then you just write, with the editor
  ready, the right focus already chosen, and recipients filled in. Plot's own threads are simply a
  Plot thread — keep it private or share it by adding people — and if you're on a team, you choose
  whether each one belongs to the team or stays personal.
- New threads now remember your last-used connection. When you open the new-thread page, the
  connection field defaults to whatever you used last in that priority — a Slack channel, an email,
  a Plot AI chat, or just a plain Plot thread — instead of always starting on "Plot thread". Sharing
  a link into Plot still starts as a plain Plot thread so nothing gets posted out by accident.
- Contact suggestions when sharing or starting a thread now lead with the people you actually write
  to. From a broad priority like "Everything", the picker used to surface mostly mailing lists and
  newsletters; now the people you've emailed or replied to come first, with mailing lists and
  senders you only receive from below them.
- Redesigned the new-thread compose page to feel like an email composer. The priority, connection,
  contacts, and title rows now sit inside the editor's bordered surface, each as a quiet
  text-field-style row with a small icon you can hover for the field name and keyboard shortcut. On
  desktop, focusing a field opens a dropdown you can navigate with the arrow keys and accept with
  Enter — start typing to filter. Contacts shows your chosen people as inline chips: arrow-left to
  step into the chip list, backspace to remove one, type any character to jump back to autocomplete.
  Click a chip to open a small menu (Remove now; CC/BCC coming later). On touch, the same fields
  open the modal pickers you already know. The lock toggle is gone — an empty contacts row reads
  "Private — only you", and adding anyone makes the thread shared automatically.
- New browser extension for Chrome, Edge, and Firefox saves the page you're on as a new thread in
  Plot with a single click on the toolbar icon. Plot picks the best priority for it automatically
  based on what you've filed there before, so there's no priority picker to think about. The icon
  shows a green check on tabs you've already saved, and clicking it again opens the existing thread
  in Plot rather than creating a duplicate. Sign-in piggybacks on whatever Plot tab you have open —
  no separate login inside the extension.
- Share a link to Plot from another app and save it in one tap — the new-thread page now lets you
  submit as soon as the link is attached, even with no note, and the thread takes its title and icon
  from the page you shared. The same shortcut works for links you add inside Plot via the link
  button. If you set a title or pick a type yourself, Plot keeps your choice.
- Share a thread with a whole group from the share picker — groups you can post to (admins of any
  group, members of any non-broadcast group) now appear alongside contacts when starting or sharing
  a thread.
- New thread drafts stick across a priority chain — start a draft in Work and it follows you as you
  navigate within Work and its sub-priorities, only resetting when you switch to a different branch
- Contact pickers and @mentions no longer suggest notification-only addresses like no-reply@,
  mailer-daemon@, or bounces@ — pick from real people only

### Threads, sharing & reactions

- Select several threads at once and act on them together. On a computer, Cmd-click (⌘ on Mac, Ctrl
  on Windows) threads to pick them out one by one, or Shift-click to grab a whole range — the thread
  you have open joins the selection automatically. The header turns into a count with one-tap
  actions for everything you picked: **To do**, **Done**, **Do later**, **Mark read**, **Move**,
  **Mute**, and **Assign** (only the actions that apply show up). A plain click, the ✕, or Esc
  clears the selection.
- Changing a thread's state — to do, done, do later, move, or mute — now moves it to its new spot in
  your focus list right away, with a smooth animation showing where it went. New to-dos are added at
  the bottom of Active, and newly scheduled threads at the bottom of their day, so your ordered list
  stays put.
- When you change the state of the thread you're reading, Plot now opens the next thread below it
  (or the one above if you're working from the bottom of your list), so you can keep working without
  extra clicks. Threads in Done stay open. The Everything view and search results never reshuffle
  when you change a thread's state.
- Threads tied to a connected tool now show a single, clear status. A thread from an app that tracks
  status (like a Linear issue or a calendar event) shows one status icon — in the thread header and
  on the row in your list — and tapping it lets you change the status right from Plot. The old stack
  of per-link rows at the top of a thread is gone; a meeting thread still shows its **Join** button
  in the header, and the thread menu now has an **Open in [app]** action to jump to the original
  item. Resting states that aren't worth the clutter (like a plain "Confirmed" event) stay quiet in
  your list but still show in the header.
- Slack custom emoji (like :party_parrot:) now work both ways. Reactions added in Slack show up in
  Plot as their real images, the reaction picker offers your workspace's custom emoji on Slack
  threads, and reacting with one in Plot posts it back to Slack.
- Slack reactions now sync both ways for the full standard emoji set, including skin tones.
- Slack and Gmail threads no longer show status labels (Inbox/Later/Sent, Starred/Archived).
  Starring a message still adds it to your to-do, and removing the star still clears it.
- The sharing count on a thread now counts only the _other_ people on it, not you, and counts the
  actual people in a shared group rather than the group as one. A thread that's just yours no longer
  looks "shared"; one you've shared with a single person shows a **1** instead of a 2; and a thread
  shared with a 7-person group shows **7**. Someone who's both named directly and in a shared group
  is only counted once. The sharing list no longer lists you among the recipients either — and to
  step away from a thread, there's now a **Leave thread** action in the thread's menu.
- Onboarding and Plot Updates messages now clearly show they come from **Plot Team**, and replies to
  them reach the Plot team. The blank gap that sometimes appeared above these threads is gone.
- Replying to an email thread is clearer. Instead of a cluster of faces, the reply bar now shows a
  labelled **Reply all** with a count of who's on the reply and a pencil to edit the recipients,
  alongside a plain **Reply** to write back to just the person who started it. Plot's own threads
  and assistant chats are simpler too — a single **Reply** that goes to everyone on the thread, plus
  your **Private note**. Editing recipients now prompts you to "Select recipients".
- Threads in your list now lead with the person who started them. When someone emails you or kicks
  off a conversation, their name shows first among the participants, so you can tell at a glance who
  reached out. Threads you started keep their usual order.
- Every thread in your list now shows when it was last active — a relative time like "5 minutes ago"
  at the right edge of each row, matching the latest note — so you can scan how fresh each
  conversation is. On narrow screens the "ago" is dropped to save space.
- Activity emails now only notify you about new notes written in Plot — items synced from your
  connected apps (like calendar events and emails) no longer trigger digest emails.
- You can now assign any thread to someone — yourself or a teammate — from the thread header or a
  row's hover actions, and filter your list by assignee. For threads tied to a connected tool that
  tracks an assignee (like a Linear issue), changing the assignee in Plot updates it there too, and
  assignee changes made in the tool flow back into Plot.
- Clearer names for the thread actions: "Add to Active" is now **To do**, "Move to Done" is now
  simply **Done**, and "Schedule" (along with "Reschedule" and "Reschedule all") is now **Do later**
  — with an alarm-clock icon — since it's really about picking the day you'll act on a thread next.
  Nothing about how they work has changed.
- Email threads now show the people on them. The faces of everyone who's been on the conversation
  appear in your thread list and at the top of the thread — even when some messages went to only a
  few of them. When you reply, Plot starts with the people on the latest message (so a reply that
  had narrowed to a couple of folks stays that way), and the recipient picker has an "In this
  thread" section to re-add anyone else with one tap. And where the recipients changed mid-thread,
  Plot now marks it inline — like "Added Jamie" or "Dropped everyone except Paul".
- Replying to an onboarding message — like the "Welcome to Plot!" thread — now goes privately to the
  Plot team (and to you), not to everyone who received the welcome. Tap the recipients on the note
  bar if you want to narrow who on the team sees your reply.
- Threads from a connected channel now show where they came from right in the list — like "Acme Co ›
  #general" for a Slack channel or "Acme Co › Project X" for a Linear project — so you can tell at a
  glance which workspace and channel a thread belongs to. In the Everything view, your focus still
  appears after it (e.g. "Acme Co › #general · Marketing").
- Plain Plot threads now show the Plot logo instead of a generic note icon, so your own threads are
  easy to tell apart from ones that came in from a connected app (which keep their source's logo).
- Opening a thread now starts you at the first unread note — opened up in full so you can read it
  right away — instead of always dropping you at the newest message with older unread notes scrolled
  past. A thread with a single note opens scrolled to the top of that note.
- The Everything view now lists threads by recency, newest activity first — the same order as the
  Done section everywhere else. Before, every unread or important thread floated to the top, so an
  older unread item could sit above something you'd just worked on; now the most recently active
  thread always leads.
- Messages you send now appear at the top of Done right away. The Done list sorts strictly by
  recency — importance only affects the order of unread items and whether something notifies you,
  never where a finished thread lands. Before, a read thread with low or no importance (like a
  message you'd just sent) got pushed below everything "more important" and never surfaced near the
  top, even though it was the most recent thing you'd done. This works offline too: a thread you
  create or send shows at the top of Done immediately, without waiting for a sync.
- Replies in a connected thread (like a Slack channel or a shared email) now go out to the
  connection automatically — the separate "send to connection" button under the editor is gone. To
  keep a reply inside Plot, mark it private with the private button (now sitting next to the attach
  button), and it stays with just the people you choose instead of going out to the connection.
- Thread headers and notes now reflect how a thread is actually shared. Slack channel and Linear
  project threads show the channel or project name in the header instead of a contact list — the
  channel's membership is the audience, not a per-thread roster. Email threads still show the
  participants you'd expect, but each note now carries a small label above its body when the
  recipients diverge from the thread default: "Private" for a note only you can see, "Just Alice and
  you" when an email reply goes to a subset, or "Plus Bob" when someone outside the usual recipients
  was looped in. Notes that match the thread default stay clean.
- The "Archive threads like this" command is now "Skip active for threads like this". Instead of
  archiving the thread and ones like it, Plot marks them as read and slots them directly into Done
  so they don't push you to act. The broom icon stays visible on muted threads like a tag — click it
  on any muted row to un-mute and let new ones like it surface in Doing again. A "Show muted only"
  filter (in the priority overflow menu) lists everything you've muted so you can find them later.
  Muted threads — and ones that match a thread you muted — now stay quiet: they won't send you push
  notifications or show up in your email digest, even when a new reply arrives.
- Renamed the activity feed headers: "Doing" is now "Active" and "Activity" is now "Done". Same
  behavior — the wording is just clearer about what each section holds.
- Activity section now respects the bumps from reading and finishing threads. Marking a thread done,
  or reading an unread thread that wasn't on your Doing list, lifts it to the top of Activity —
  where it then stays in stable order as newer threads arrive above it. Previously the Activity
  section sorted purely by the original note time, so just-read or just-finished threads stayed
  buried at their old position.
- Plot now sorts every new thread into Respond, Do, Read, Update, or None — Respond, Do, and Read
  are reserved for things that clearly need a reply, an action, or a longer read; Update is the
  default for "good to know"; None covers passive items like receipts and sign-in confirmations and
  lives quietly in All. Threads carry an Urgent flag when something genuinely needs your attention
  before your next response window, and unsolicited or low-relevance items no longer push
  notifications by themselves.
- Tapping a notification that covers multiple threads now lands you on the Catch up tab of the
  priority, which lists every unread thread sorted by urgency, so you go straight to what's new even
  if you were last looking at a different tab on that priority.
- Renamed the activity feed section "Today" to "Doing", and the button that puts a thread there from
  "Do today" to "To do". Same behavior — the wording just better reflects that "Doing" is what
  you're working on right now, not strictly today's schedule.
- Tapping a notification now jumps straight to the thread when there's only one new item, instead of
  dropping you on the priority's activity feed. When several new threads share a notification, Plot
  still opens the priority but scrolls the New section to the top so the unread items are right
  there.
- Dropping a thread on Done in the activity feed always lands at the top now — there's a single drop
  zone above the first done thread (and just under the Done header when the section is empty), so
  the gap stays put as you drag anywhere over Done instead of opening between done threads. Drop a
  thread that's already done to bump it back to the top.
- The Activity tab is now the home for managing threads on a priority. Threads are organized into
  Today (active items), per-day Scheduled sections (Tomorrow, Friday, etc. for things you've
  scheduled ahead), New (unread items waiting for your attention), and Done. Drag a thread between
  sections to move it — drop on Today to work on it now, on a future day to schedule it, on New to
  mark it unread, or on Done to finish.
- Renamed the to-do button: "Add to agenda" is now "Do today" and "Remove from agenda" is now
  "Finish". The keyboard shortcut and behavior are unchanged.
- Merging a calendar event thread into a discussion thread now keeps the event link and its
  scheduling on the merged thread, while bringing the discussion's notes along. Splitting later
  restores the event to its own thread.
- Plot Team is now pre-attached when you start a thread in Using Plot — your feedback and questions
  go straight to the Plot team without needing to add them as a recipient first
- Contact avatars now show in more places — your own photo from your sign-in account, photos from
  connectors that supply them (Linear, GitHub, Jira, Slack), photos pulled in from your Google
  Contacts when you have Gmail or Calendar connected (no separate Google Contacts connector
  required), and a Gravatar fallback for anyone else. Contacts without any photo still show the
  colored initials.
- Share a thread with a whole team or group, not just individuals — groups now appear alongside
  contacts in the thread sharing UI
- "Add to agenda" replaces "Start" throughout the app — clearer wording for putting a thread on your
  agenda

### Notes

- The link button in a note now lets you attach a reference to another Plot thread — including
  notes-only threads — instead of jumping away to it. Search by title to find any thread, pick a
  linked item to reference its thread, or paste a URL as before. The attached reference shows as a
  removable chip on your note.
- Flagging a note as a To do is now a single toggle in the note bar — the circle-plus button at the
  left, in both new threads and replies. The separate "Note" and "Task" tabs are gone; a plain Plot
  note no longer shows a tab bar at all, and you can mark anything To do without changing who it's
  shared with.
- Notes now speak the same To do / Done language as threads. The note action once labeled "Make a
  task" is now **To do**, and "Mark done" is simply **Done**. Flagging a note To do still adds its
  thread to your To do list, and finishing a thread now marks the notes you'd flagged on it as done
  no matter how you finish it — the Done button, ⌘D, or a swipe. To un-check a done note, just tap
  its check.
- Pressing Enter inside a quote now continues the quote on a new line, just like lists do — press
  Enter on an empty quote line to step back out.
- The "Add link" and "Attach file" buttons in the note bar now appear only when the thread's source
  can actually accept them — for example, Gmail shows "Attach file" but not "Add link", and Google
  Tasks shows neither. Your own private Plot notes still support both.
- Pick recipients per message: tap the avatars in the new note bar to choose who sees a reply (now
  including any groups on the thread), or use the Private note button to keep it to yourself. The
  new bar also shows what mode you're in — Note, Task, Chat, Reply, or Comment — and the Send button
  label follows.
- Note tasks are simpler: you make a note your own task, and that's it — there's no more assigning a
  task to someone else. Anyone on a shared note can still mark it as their own task and everyone
  sees who's on it, just like an emoji reaction. Tap the circle to make it yours (and again to check
  it off); when teammates have it too, you'll see their assignment and can tap to join or step back
  out.
- Download the original file from the image viewer — click an image attachment to open it full-size,
  then tap the download button next to the close icon. On Mac, Windows, and Linux the file lands
  directly in your Downloads folder; on iOS and Android Plot opens the system save sheet so you can
  pick a location.
- Create Google Tasks from Plot — pick "Create new Task" when adding a link to a thread, choose a
  Google Tasks list, and Plot creates the task in Google Tasks and links it back automatically
- React to notes with a quick tap — pick from Thinking, Remember, Agreed, Relieved, Send, Noted,
  Laugh, Surprised, Confused, or Dismayed to acknowledge a note without writing a reply
- Create new items in connected tools right from Plot — when adding a link to a thread, pick "Create
  new Linear issue" (and similar for other connectors) and Plot creates the item in the external
  tool and links it back automatically
- Code blocks in notes are now selectable — drag to copy just part of a snippet instead of having to
  copy the whole block
- Cleaner Done button on notes — a single Done button toggles your own status instead of three
  different states crowding the note
- Improved Add link modal — when the search field is empty, you'll see your recent links and "Create
  new" options for your connected tools instead of an empty results message

### Agenda

- The agenda now stays out of your way until it's useful. If you haven't connected a calendar, it's
  hidden from the sidebar and the bottom navigation — and it appears automatically the moment you
  connect one.
- Renamed "Start timer" to "Start focus" — your focus block now lives on your agenda, not just in a
  corner pill. Starting a focus drops a 30-minute block onto the agenda at the current time (or
  shorter if a scheduled item is coming up sooner), and the agenda block lengthens or shrinks as you
  adjust the timer. Pausing leaves a sliding "remaining" block that follows the current time forward
  until you resume or stop it; stopping clears it from the agenda. Selecting a focus that already
  has a scheduled block covering now starts the timer for you automatically — and so does the start
  of a scheduled block while you're on that focus. Dragging an active block to a future time stops
  the timer; dropping a future block onto now starts it.
- You can now schedule a focus block straight from a free slot in the agenda. Every gap between
  events shows a +, and tapping anywhere on the gap row sets aside time — pre-filled to start when
  the gap starts and sized to fit the opening (the usual 30 minutes, or the whole gap if it's
  shorter). The day headers work the same way for adding a block to that day. On desktop the + stays
  tucked away until you hover the row.
- The agenda keeps today focused on right now. Events, focus blocks, and free-time gaps that have
  already passed drop off, so the top of today is always what's happening now or coming up next.
  Whatever is in progress shows "Now" in place of its start time with a live countdown of the time
  left, and when you're between things you'll see a "Now" gap counting down to your next event.
- The agenda now highlights a block only when it's actually relevant. A block at the current time
  lights up when you're viewing its priority, and tapping any block in the agenda highlights exactly
  that one — even a later one. Switching priorities another way (the tree, a header, opening a
  thread) no longer tints an unrelated block just because that priority has something scheduled
  elsewhere on the agenda; if nothing's happening for it right now, nothing is highlighted.
- The agenda now shows only what's actually on your schedule: calendar events and the focus blocks
  you explicitly add, each at its real time, with read-only markers for the free space between them.
  Scheduling a task for a day no longer drops a timeless, empty block onto the agenda — tasks live
  in their priority's list, and a slot only appears on the agenda when you deliberately put one
  there.
- Video meeting links in the agenda are now a single tap-to-join chip. When a calendar event keeps
  its Zoom, Meet, Teams, or Webex link in the location field, the agenda used to show the raw URL as
  unclickable text that looked like a physical address. Now Plot recognizes the link and shows just
  "Zoom" (or the right provider), clickable to join — and still shows the room or address alongside
  it when there's a real location too.
- Scheduling a focus block is now fully keyboard-friendly. Tab moves between the priority, date,
  time, and duration fields, and the left/right arrow keys adjust the focused field — Shift+arrow
  for bigger jumps (a week on the date, an hour on the time and duration). You can still type a time
  or date and use the on-screen chevrons exactly as before.
- Event RSVPs now show as a single colour-coded chip — your response sets its colour, and you can
  change it or see who's coming right from the chip.
- Tapping a priority or event in the agenda now opens its activity feed rolled up with everything
  from its sub-priorities, the same as opening that priority anywhere else. Agenda taps used to land
  on a direct-only feed that hid sub-priority threads, which felt inconsistent with the rest of the
  app.
- The old per-priority "Notifications" panel is now "Response times", split into two
  clearly-labelled settings: "Schedule time to respond" (when to set aside time, with a master
  toggle, active hours, and a response SLA) and "Early notifications" (when to allow interruptions
  before that scheduled block, with its own toggle, allowed hours, and see-within deadline). Each
  setting inherits from its parent priority by default and reverts to inheritance when you set it
  back to the parent's value. Your agenda now places respond blocks inside your active hours and
  around your existing calendar — if there's no room before the deadline, the block shows up
  overflowed (in red) so you notice rather than silently slipping.
- The timer pill now appears automatically when a scheduled event for the priority is in progress —
  no need to press Start. The countdown shows the time remaining in the event, and pressing pause
  (or stop) ends the event timer for you, marking the rest of the event as time you opted out of.
  After that, pressing Start fires up a fresh pomodoro defaulted to the time still left in the
  event. The `+` and `−` buttons on an event-driven timer extend or shorten the event itself in
  15-minute steps.
- The Start timer button now picks a sensible starting time every time. If you've paused a timer for
  the priority, pressing Start picks it back up where you left off. If not, Plot uses whatever
  duration you've set on that priority's block (capped to the time before the next event so the
  timer can't overrun), and falls back to 15 minutes when there's nothing else to go on. Switching
  priorities mid-timer still opens a quick 5-minute reminder on the new priority, but those
  auto-starts no longer get revived later — only timers you explicitly started or extended do.
  Pressing `+` on an auto-started 5-minute timer promotes it to a real session, so the next time you
  come back to that priority it picks up where you left off.
- The timer pill now pauses cleanly — tap a running timer to pause and the time remaining is
  preserved, so the next Start picks up exactly where you left off. The `+` button snaps the
  remaining time up to the next 15-minute mark (so 7 minutes left becomes 15, and 15 becomes 30),
  and `−` shaves off 5 minutes (or whatever's available above the 5-minute floor).
- Drag a priority block into a gap and Plot fits it in cleanly — if you've set a duration, it uses
  yours; otherwise it picks a default (30 minutes, or whatever's left in the gap if that's shorter).
  If your blocks don't fill the gap, the leftover time shows as a smaller gap right below them so
  you can see at a glance how much room is left and drop another block into it. Blocks that don't
  fit a gap spill into the next one (and the next, until the day's events run out), so combined
  durations longer than the gap split across periods on the fly without rewriting anything.
- Time spent on calendar events now counts toward each priority's totals automatically — for any
  event you accepted, or did not decline. Overlapping active sessions take precedence, and
  overlapping events only count once each, so totals match wall-clock time. When you first turn this
  on, Plot fills in the past 90 days from your connected calendars.
- Drag a thread to the end of a block on a different day or in a different gap to move just that
  thread without changing its priority — Plot creates a new block under the destination, or merges
  into an existing block of the same priority if one is already there. Dropping a thread inside a
  block (or at the end of a block in the same period) still adopts the destination's priority as
  before.
- Drag a thread onto an event to add it to that event — the thread now nests under the event header
  and disappears from anywhere else in the agenda. Hover an event-attached thread to reveal a new
  "Remove from event" button at the trailing end. The leading icon stays the same as a regular
  thread, so you can still mark it done or schedule it without first detaching it from the event.
- Threads in your agenda are now grouped under shared headers by priority, event, or schedule gap.
  Each block's header carries the priority's accent color so you can scan a day at a glance, and
  event headers now show the time, RSVPs, and elapsed/remaining inline instead of repeating that
  information on every event row.
- Drag a priority's header to rearrange your day — reorder priorities within the current slot, or
  drop the whole block into a different gap or day to move all of its threads at once.
- Long priority blocks stay scannable — the first two threads show in full and the rest collapse
  behind a small chevron-down row. Click the chevron to expand the block; expanding another
  collapses the previous one. Events with several attached threads now collapse the same way: the
  event row plus one attached thread show, and the rest hide behind the chevron until you expand.

### Search

- Search now matches the calm look of starting a thread: instead of a boxed input, it's a clean,
  underlined prompt that fades in when you open it. On phones it runs edge to edge across the top
  with no wasted padding.
- Search is now truly global: you get the same results no matter which focus you started from, with
  "Everything" selected at the top of the sidebar. Tap a focus in the list to narrow your results to
  just that focus without leaving the search — or tap "Everything" to see them all again. Results
  pulled from the server now blend right into the same list instead of sitting under a separate
  "From the server" heading. Tag and type filters work exactly the same way.
- Search filters now match search itself. Because search looks across all your focuses, the filter
  chips it offers — tags, reactions, and types — are now drawn from every focus too, so you can
  narrow a search by a tag or type even when it isn't used in the focus you happen to be on. Before,
  the chips only reflected the current focus, so those filters were missing the moment you searched
  beyond it.
- Filters now work everywhere, just like search. The filter chips — tags, reactions, and types — are
  drawn from every focus, and selecting one searches across all of them and switches to the
  Everything view, then drops you back where you were when you clear it. Before, both the available
  chips and their results were limited to the focus you happened to be on, so filtering couldn't
  reach anything outside it.
- On phones, tapping Search now jumps straight to the Everything view so you're searching across all
  your threads from the first keystroke, instead of staying scoped to whatever priority you were on.
- Search now also returns matches from the server, not just what's already on your device — and
  shows a hint when there are matching archived items you might want to include
- Filter the search bar by thread type — pick any type represented in the current priority,
  including connector link types like Linear issues or Attio deals, each with its own logo

### Plot AI

- Plot AI is now a full assistant. Mention @Plot (or start a "Plot AI chat") and ask it anything —
  it answers general questions, writes and summarizes, searches the web for current information, and
  digs through your own Plot workspace (your notes, threads, and projects) to answer questions about
  your stuff. You can also ask it to organize, and it'll propose a plan to move, archive, or rename
  threads and priorities for your approval. It no longer dead-ends with "I didn't recognize what
  you're asking for" — just talk to it like you would ChatGPT or Claude.
- Plot AI is now a connection. On the new-thread page, tap the connection field above the editor and
  pick "Plot AI chat" to start a chat with the Plot twist. The duplicate twist button under the
  editor is gone — the connection field is the single place to choose where your thread goes. You
  can also still @-mention Plot in the body to switch the connection.

### Connections & onboarding

- Connectors that need Plot Pro now wear a small **Pro** label while you're connecting your tools.
  Tapping one when you're not on Pro opens the upgrade options instead of the setup screen, so it's
  clear up front which connections your plan includes — and once you're on Pro, they connect as
  usual.
- The "Connect your tools" onboarding step now groups your connectors into **Messaging**,
  **Calendars**, and **Apps**, so it's easy to find what you want to connect. It also shows your
  plan's connection limits — two connections free, up to five on Plot Core (free for 30 days) — with
  a quick **Upgrade to Plot Pro** option for unlimited connections.
- Connected apps now sync quietly in the background. The "Twisting" badge that used to appear on
  threads while a connection (like Slack) was catching up is gone — connector sync happens
  transparently. The badge still shows for Plot's own assistants and twists when they're working on
  a thread.
- Adding a connection is clearer: each one now describes what you can actually do with it — like
  "See your schedule, respond to invites, and add notes and to-dos to events" for Google Calendar —
  instead of a bland list of data types. The same descriptions now appear on the Connections page of
  our website, where the "vote for what's next" button also got a cleaner look with a proper count.
- When connecting Google Calendar, you can now see a short summary of what Plot accesses, and choose
  whether to share contacts (to add names to events) and list all your calendars. Skipping the
  optional permissions no longer blocks the connection — Plot just syncs your primary calendar.
- The connect screen now explains, in plain language, exactly what access each connection grants —
  before you authorize it.
- Adding a connection now starts with smarter defaults: Plot turns on the channels you'd actually
  want and leaves the noise off. Your own Google and Outlook calendars are selected (holiday
  calendars and ones shared with you by other people are left off so they don't crowd your view),
  Gmail starts with your inbox and sent mail, and Google Drive includes your files plus shared ones.
  Big containers that would pull in everything at once — like a whole GitHub org or a Microsoft
  Teams team — wait for you to pick what you want. You can still toggle anything on or off.
- Each connection now speaks your service's language when picking what to sync. Instead of a generic
  "Sync new channels" toggle, you'll see "Sync new folders" for Google Drive, "Sync new projects"
  for Linear and Todoist, "Sync new calendars" for your calendars, and so on. And for connections
  where Plot already syncs everything by default (like Linear, Asana, or Slack), that toggle now
  starts **on**, so newly created projects or channels show up automatically — while connections
  that sync only a few things by default (like Gmail or your calendars) leave it off so nothing
  unexpected sneaks in.
- When a connected account (like a calendar) is missing a permission Plot needs, we'll now prompt
  you to reconnect it instead of silently failing to sync.
- Connect WhatsApp and Instagram (pro): see and reply to your DMs and group chats right in Plot, and
  start new conversations.
- Your onboarding threads — including the "Welcome to Plot!" message — now arrive in your Inbox, and
  the fixed "Using Plot" and "Twist Development" focuses are gone, so you can organize everything
  however you like. The onboarding threads stay put in your Inbox even as you add focuses; move one
  into a focus and the rest follow. "Help and feedback" still works the same way — it opens a new
  thread in your Inbox that's shared with the Plot team.
- New positioning across the marketing site: Plot now leads with collaboration — every conversation
  in its place, the best of the day stays yours.
- Outlook and Apple calendars now stay in sync as reliably as Google Calendar. Outlook RSVPs
  (Accept/Decline/Tentative) actually go back to Outlook now instead of silently failing, Outlook
  webhooks no longer die after three days, and big initial syncs surface upcoming meetings within
  seconds instead of after the whole 2-year backfill finishes. Apple Calendar no longer wipes the
  entire calendar when a single event is deleted, and recurring-event cancellations from iCloud stop
  occasionally getting dropped. Both calendars now have a "Syncing…" indicator that actually clears
  when the initial sync is done.
- New Granola integration. AI meeting notes from Granola now attach onto your existing calendar
  event thread automatically — Google Calendar, Outlook, and Apple Calendar are all supported,
  including recurring meetings where every occurrence shares one thread. If a Granola note doesn't
  match a calendar event yet (e.g. an ad-hoc meeting), it gets its own thread instead of being
  skipped. Each note is added as a single markdown summary, with a link back to the Granola web
  page.
- Calmer first-time sign-in. The loading screen no longer says "Syncing your data" when there isn't
  any data yet — new accounts see a brief "Welcome to Plot" and "Setting things up…" instead. The
  onboarding screen also fades in gently after sign-in rather than appearing all at once.
- Onboarding threads now describe the new Activity workflow — Today, Scheduled, New, Done sections
  with drag-between-sections — and use **Do today** / **Finish** throughout instead of the old "Add
  to agenda" / "Remove from agenda" wording. The "Getting Around" gestures list adds a bullet for
  dragging threads between Activity sections, and the agenda concept is reintroduced as the
  universal day view across every priority (the Agenda tile on the priorities list / bottom nav).
- New onboarding flow walks first-time users through the basics in seven steps — welcome, connecting
  calendars (with inline "Continue with Google" / "Continue with Microsoft" buttons), connecting
  other tools (a responsive grid of every available connector that opens each one's standard setup
  modal), then a tour of priorities, the agenda, the activity feed (Plot switches the panel tabs as
  it goes), and finally a peek at the "Everything in its place" thread to introduce notes and
  sharing. Steps include a back chevron to revisit a previous step, an X close to dismiss anytime,
  and EditSource modals opened from onboarding now show "Upgrade to add more connections" instead of
  "Add connection" when you're at your plan limit.
- Onboarding threads now cover the new agenda and thread gestures — long-press the add/remove button
  at the start of a thread to schedule it to a date and time, tap a thread's icon to edit its
  title/icon/priority (or long-press to jump to moving it), and drag a thread under an event to set
  an event agenda that's shared with other invitees using Plot and carried forward across recurring
  meetings.
- Pick exactly which Airtable tables and views you want to sync — bases now expand into their tables
  and each table's views, so you can sync just one filtered view (like "My open deals" or "Active
  cases") instead of every record in the whole base
- Clearer guidance in the onboarding "Clean up" thread — archive is for mistakes (threads) and
  inactive areas (priorities), not for marking work done. To finish a thread, "Remove from agenda" —
  it stays in Activity for everyone and your tasks plus linked items in connected apps complete. The
  thread also points to the new home for "Show archived" / "Hide archived" in the priority's More
  commands menu.
- Smarter onboarding — after your first connections sync, Plot suggests starter priorities based on
  what's coming in from your calendar, mailbox, and chats, so you don't have to design your priority
  tree from scratch
- Auto-sync new channels — turn on "Sync new channels" in a connection to have Plot automatically
  enable newly added Slack channels, Airtable bases, Linear projects, etc. as they appear
- Most twists are now single-instance by default — you install them once per workspace or team
  instead of needing a separate copy per priority
- Connection names are now set automatically as "Connector (account)" — no more blank or stale
  labels, and the field is no longer editable since it's derived from the connected account
- Google connection consent now shows only the new scopes you're granting — Plot uses incremental
  authorization so you don't have to re-approve scopes you've already granted
- Improved Slack admin handoff — if your Slack workspace requires admin approval, members now see a
  clear error with a "Copy message for admin" button, and admins can install via plot.day/slack
- Added a "Help and feedback" command to the Settings menu — opens a new thread in Using Plot so you
  can send feedback to the Plot team in one step
- When your Core trial ends (or you downgrade to Free), Plot now cleans up any connections and
  twists over your new plan's limits the same way removing them from the app would — including
  archiving the threads from each trimmed connection, so nothing stale is left on your agenda
- New sign-ups now see their 30-day Core trial right on the Welcome to Plot! thread, with a reminder
  before it ends — add a payment method anytime during the trial to keep Core access, or let it end
  and switch to free
- Airtable now syncs every task-like record from your bases, not only records assigned to you —
  records with an assignee still come in pre-assigned
- Slack now connects as you — no workspace bot to install or invite into channels. Replies you send
  from Plot post as you, and Plot only sees channels you're already a member of. You'll need to
  reconnect Slack once.
- Slack: save a message for Later and it becomes a to-do in Plot. Toggle the to-do in Plot and the
  message saves/unsaves in Slack.
- Notification emails now include an unsubscribe link — choose to get them at most once per day,
  once per week, or never, without needing to sign in

### Keyboard shortcuts

- Cmd+Shift+X now toggles a note as your own to-do (moved from Cmd+Shift+T, which conflicted with
  the agenda/activity tab toggle)
- More keyboard shortcuts: Cmd+J switches focuses (Cmd+Option+J on web), and on the new thread page
  you can now change the focus with Cmd+Shift+P (Cmd+Option+Shift+P on web), edit the title with
  Cmd+Shift+H, and change the thread type with Cmd+Shift+I
- Keyboard shortcut updates: Cmd+Shift+A focuses the current list and switches between agenda and
  activity on a second press, Cmd+T makes the focused note a task, Cmd+Shift+T assigns it, and new
  thread on web is now Cmd+Option+N (so browsers stop stealing Cmd+Shift+N)

### Performance

- Unread threads open with their messages already there. Plot now keeps the messages for your unread
  and active threads ready on every device, so opening one from Updates — or tapping a notification
  — shows the conversation right away instead of fetching it on the spot. Older threads you haven't
  opened still load their messages on demand, now showing a brief spinner only when they aren't
  already on hand (and never a flash when they are). A fresh device also no longer downloads your
  entire message history up front — it pulls older conversations as you open them — so signing in on
  a new device is quicker and lighter.
- Switching between focuses is now much faster. Even in large workspaces with thousands of threads,
  a focus's feed appears in a fraction of a second instead of taking several seconds.
- Filtering when you start a thread is now instant. Typing a person's name or an email in the first
  step of the new-thread picker updates the list as fast as you type, instead of lagging a beat or
  two behind on accounts with lots of contacts and connections.
- Faster startup sync (often by a few seconds). The push phase was redundantly re-pushing every
  parent entity inside the dependency walk of every child level — three times for priorities, twice
  each for threads, links, schedules, and friends — so a quiet sync that should have been a series
  of cheap "nothing pending" checks turned into ten-plus of them. The orchestrator now remembers
  what it already pushed inside a single sync, and small partial indices on the pending column make
  each of those checks effectively instant instead of a full table scan.
- Faster priority switches while the app is catching up after startup. Plot's per-entity sync was
  doing a write to its bookkeeping table for every entity on every cycle even when the server
  returned nothing, which serialised against the activity feed's read queries. With ~16 entities on
  a quiet startup that added up to a noticeable stall. The bookkeeping writes (and an empty-batch
  transaction that came with them) are now skipped when nothing actually changed, so switching
  priorities stays snappy through the sync window too.
- Activity feed feels snappier, especially during sync. Scrolling through a long feed now loads in
  steady-time pages instead of getting progressively heavier, and opening a thread while the app is
  syncing in the background lands faster.
- Switching priorities is much snappier — the loading spinner now appears the moment you click
  instead of after a beat where the previous priority's threads stayed on screen, and the new
  threads land sooner because the agenda's database query no longer waits in line behind redundant
  lookups for draft state. A new index on the priorities table also speeds up the sidebar load and
  other places that look up priorities by path.
- Faster agenda — opening a priority's agenda now renders significantly more quickly by skipping
  redundant rebuilds and trimming empty-day headers
- Faster Add connection — channel setup now happens in batches in the background instead of blocking
  the save

### Fixes

- On phones, pop-up sheets now stretch across the full width of the screen with their content
  centered, instead of sitting in a narrow strip off to one side. The close (X) always rides in the
  top-right corner of the sheet, and a thin line along the top sets the sheet apart from what's
  behind it.
- Dragging a thread to reorder it now reliably keeps it where you dropped it. Threads that had never
  been individually ordered (most synced messages, and some starter threads) shared the same
  internal position value, so dropping a thread between two of them silently sent it to the bottom
  of that group instead. Plot now spots the tied values on drop and spaces them out so the dragged
  thread lands — and stays — exactly where you put it.
- The people count on a thread now includes everyone in a group it's shared with. A thread shared
  with a group (like your team) plus another person used to under-count — showing only the
  directly-named people and treating the whole group as no one — so it could read "1" when two
  others could actually see it. It now counts the group's members too.
- Keyboard shortcuts work again in the web app on a Mac. The shortcut to start a new thread (and to
  switch focuses or change a thread's focus) did nothing in Safari and Firefox and triggered the
  wrong thing in Chrome, because the old key combination clashed with how macOS and browsers handle
  the Option key. They now use a combination that works in every browser.
- Replying to an email or message in its original app no longer pings you about your own reply. When
  you answer a Gmail thread (or similar) directly in that app, Plot used to sync the reply back,
  mark the thread unread for you, and notify you about a message you just wrote. Plot now recognizes
  those replies as yours and leaves the thread read.
- After you upgrade, the connection screen updates itself. If you were on the "Set up" screen for a
  connection and tapped "Upgrade to add more connections," that screen now turns the upgrade button
  back into the normal connect button the moment your new plan takes effect — even when you finished
  the upgrade in your browser — so you can add the connection right away without closing and
  reopening it. The same applies to adding a twist.
- The icons at the right end of a thread row now hold their place when you hover. The always-present
  ones — like a muted thread's mute icon, a status icon, an RSVP, or an assignee's avatar — stay
  put, and the extra actions that appear on hover slide in to their left instead of nudging them
  around. The status icon also now matches the size and look of the other icons beside it.
- On iPad, the circle button beside each thread now sits perfectly level with the thread's title,
  instead of drooping below it. The icons at the right end of a row (status, RSVP, and the actions
  that appear when hovering with a trackpad pointer) line up the same way.
- The two side-by-side panel headers now line up exactly. On iPad and on the web, the bar above an
  open thread could sit a touch taller than the list header beside it, leaving a small step where
  the panels meet; both now share the same height on every platform. On iPad, the rounded corners on
  the thread panel's right side also showed a dark sliver — they render clean now.
- Opening a thread no longer moves it. Just reading a completed thread used to bump it to the top of
  Done, and in Everything (and search) — where read and unread threads sit together — both reading
  and completing a thread could yank it to the top. Now opening a thread leaves it in place, and the
  Everything and search lists stay in a steady, recency-based order.
- On a phone, the agenda no longer looks washed out. Event titles now show in their focus's full
  color, and the day and summary text read at a normal contrast level, so the agenda is easy to scan
  at a glance. On wider windows, where the agenda sits beside your threads as secondary content, it
  stays softly muted as before.
- New replies on a thread you'd already opened now show up as unread again, and notify you. A reply
  could land silently — no unread mark, no push or email — on any thread you'd previously read; new
  messages now resurface the thread and reach you as expected.
- A focus you'd paused no longer shows up twice in the agenda. When a focus was scheduled for right
  now and also had a paused timer, the agenda could list the same block twice in a row; it now shows
  the live scheduled block just once.
- Replies you write on an email thread now actually send. A recent change could leave a reply
  sitting in Plot without going out over email — the connector couldn't tell who the recipients were
  and quietly skipped the send. Your replies now reach everyone on the thread again.
- Archiving a note no longer re-sends it. Removing a note you'd written could cause it to be emailed
  out, so a note you archived and rewrote could go out twice; archiving a note now never triggers a
  send.
- The onboarding tour is easier to read in light mode. The tinted steps that show your app
  underneath were washing out against the light background, making the white text hard to read; they
  now carry enough contrast to read clearly.
- Upgrading your plan now takes effect immediately when you return to the app — no more being asked
  to subscribe again right after you've paid. You'll also see a quick confirmation when your new
  plan is active.
- Switching between a focus and an agenda event in another focus no longer flickers. The Event
  Agenda section used to flash in over the previous focus's threads (and on the way out, vanish a
  moment before the threads changed); now the event and the thread list always change together in a
  single step.
- Read status now syncs reliably across your devices. Reading a thread on one device now clears the
  unread dot everywhere — previously some threads (often the welcome and Plot Team messages) could
  stay marked unread no matter how many times you opened them, and searching could even make a
  thread you'd read pop back to unread. Threads that were stuck this way are cleared automatically.
- When you search for a group to start a thread, it now shows the right number of people in it
  instead of sometimes showing zero.
- Fixed sync stalling for very large workspaces. Right after connecting tools with a big history
  (tens of thousands of threads), syncing could time out and stop bringing in updates entirely;
  thread sync is now fast no matter how much is coming in.
- Changing a focus's color now updates everywhere at once. Previously the current event in your
  agenda could keep showing the focus's old color.
- Connecting a second account no longer shortens a contact's name. If one app knows someone as "Beth
  Round" and another only as "Beth", Plot now keeps the fuller name instead of overwriting it with
  the shorter one — and fills in a name when it was missing. New connections can only add detail,
  never take it away.
- Replies you add to a thread you started in a connected channel (like a Slack channel) now post
  back to that service, just like the first message did. Previously only the opening message went
  out and follow-up replies stayed in Plot.
- A connection that gets stuck on "Syncing…" now recovers on its own. If a sync is interrupted
  partway — say a server restarts mid-sync — Plot notices the stall and quietly picks it back up,
  instead of leaving the connection spinning forever.
- Connecting an account no longer leaves a stuck connection if you close setup partway. A connection
  only counts once you've signed in and chosen what to sync — so if you back out before finishing,
  nothing lingers behind, and you can always start over with the same account.
- Contact names you see are now based on your own connected accounts, so someone else's data can
  never change how a contact's name appears to you. This fixes cases where a shared contact (like a
  team address) would get renamed to something wrong — for example a group address picking up the
  name of whoever last emailed it.
- Switching between focuses — and moving between a focus and the Everything view — is now seamless.
  The thread list updates in place instead of blinking to an empty panel for a moment, and you'll no
  longer catch a brief flash of two stacked headers while the new view loads.
- Email previews in your thread list no longer show a stretch of blank space. Some newsletters hide
  invisible spacer characters in their preview text to control how it looks in other inboxes; Plot
  now strips those out, so a thread shows its actual opening line instead of a few words trailed by
  emptiness and an ellipsis.
- Connect a new app and it shows up right away. When you add a connection, its options now appear in
  the new-thread picker immediately, instead of only after you restart Plot.
- Forwarded emails now show their content. When a message is forwarded into a connected inbox (like
  Gmail), Plot reads the forwarded message instead of leaving the thread blank.
- People in connected email and chat threads no longer show up as "Unknown." If you'd earlier
  cleared someone from your contacts and they later turn up on a new thread you can see, Plot
  recognizes them again and shows their name and photo instead of a blank "?".
- When you're writing a new thread, clicking the empty space around the input no longer drops you
  out of it — your place is kept until you move to another field.
- Removing a connection or turning off a synced channel now cleanly clears its items from all your
  devices, and re-adding it brings them back without leaving stale duplicates behind.
- Hover tooltips in the open thread — the names and emails behind an avatar, who reacted, and the
  toolbar buttons — now show in full instead of being cut off at the panel's edge.
- Imported emails and newsletters now read cleanly — links and bold text no longer run into the
  words next to them, so everything stays properly spaced and formatted.
- Fixed focus blocks not showing up when scheduled on a top-level priority. A focus block added to
  the priority at the top of your list (or any priority that doesn't have its own threads on the
  agenda) would save but never appear — now every focus block shows at its scheduled time regardless
  of which priority it's on.
- Fixed new items piling into the wrong priority. Plot could funnel almost everything from your
  email and other connected accounts into a single sub-priority — whichever one you'd most recently
  filed a few similar items into — even when the items had nothing to do with it (a couple of
  cycling emails could pull your whole inbox into "Cycling"). Plot now sorts each item by the
  specific source it came from and what it's about, and only auto-files into a priority when the
  past examples there clearly agree. Items already mis-sorted this way re-sort themselves.
- Opening Plot now takes you to the right place. If an event or focus block is happening right now,
  it opens to that priority; otherwise, if you have a timer running, it opens to the priority you're
  tracking; and when nothing is scheduled or running it starts at the top of your priorities.
  Before, it would sometimes open into a specific sub-priority for no clear reason.
- Fixed Google connections (Gmail, Calendar, Drive) repeatedly asking you to reconnect. Reconnecting
  an account would get you a session that quietly expired about an hour later and prompted you to
  reconnect again, in a loop. Reconnecting now restores a lasting connection that stays signed in.
- Your active threads always show at the top of a rolled-up priority now. At a high-level priority
  like "Everything" with thousands of threads, the Active and Scheduled sections could come up empty
  even when you had active threads in sub-priorities — the feed was loading one recent page that
  filled up with finished items and pushed your active threads out of view. The feed now loads each
  section (Updates, Active & Scheduled, Done) separately, so what you're working on is always there
  regardless of how much history sits below it. Active threads also sync to a fresh device reliably
  instead of only the most recently touched ones.
- Gmail sending and syncing are more dependable. Sending an email or a reply no longer risks a
  duplicate copy going out if Plot retries the send behind the scenes, and incoming mail that
  briefly failed to download during a sync is now retried instead of being skipped, so messages stop
  going missing.
- Dragging a thread in the activity feed now lands it exactly where you released it. Drops at the
  edge of a sort group used to bounce back, jump to the top of the list, or silently flip a read
  thread to unread (and vice versa): the order field was being computed across sort groups that
  don't share an order space, and a thread dropped at the unread/read boundary always inherited the
  prev neighbour's group. The drop now picks the destination group from where you actually released
  — staying read at the top of reads, unread at the bottom of unreads, or in the same importance
  bucket within unreads — and computes the order from only the same-group neighbour, so the row
  lands in the slot under your cursor instead of somewhere else.
- Fixed the desktop window restoring to the wrong height when you'd last used Plot on an external
  monitor taller than your laptop screen. Each restart was trimming the window down to the laptop
  screen's height instead of the external monitor's, leaving a strip of empty space below the window
  every time.
- Marking a task done on a note no longer flickers. Clicking the circle on a task assigned to you
  now switches straight to the checkmark and stays there, instead of briefly showing nothing (or
  popping back to the circle) while sync caught up with the server.
- Fixed switching to a second priority, re-tapping the priority you were just on, or tapping a
  scheduled event in the agenda for the priority you're already viewing — all three used to show a
  permanent spinner where the activity feed (or the event's thread) should be. The destination now
  reliably swaps in instead of stranding you on a loading screen.
- Dragging a thread to Doing now updates every open agenda instantly and reliably. Two issues were
  causing trouble: occasionally the new block would never appear at all (a stale snapshot was
  masking the update until the next app restart), and even when it did appear, the side-panel agenda
  could lag several seconds behind the drop while a background sync was holding the database. The
  agenda now picks up the change in the same frame you drop the thread, whether you're looking at
  the activity feed, the side-panel agenda, or the agenda page.
- Switching priorities no longer flashes the previous priority's threads under the new headers
  before refreshing — the activity feed now waits until both its data sources are ready and swaps
  everything in one frame, so you go straight from spinner to the new content.
- Switching priorities no longer flashes. Picking a different priority now updates in place — the
  new-thread editor stays mounted so anything you'd started typing carries over to the right
  priority's draft, the side panel widths you'd set stay put, and the brief blank moment between the
  old and new priority is gone. If you were reading a thread, the right panel cleanly moves to the
  new priority's new-thread page instead of showing the old thread under the new feed.
- Cleaner email threads — emails brought into Plot no longer carry the columns of broken decoration
  images that newsletters wrap their header logos, footer social icons, poster thumbnails and
  avatars in. The tall empty rectangles those used to leave between paragraphs (and the long stretch
  of nothing after an email's "sent by …" line) are gone, so the note is just the text and the links
  that matter.
- Fixed rapid Add/Remove time presses on the timer pill silently dropping changes — pressing `+` or
  `−` several times in quick succession now lands every press, instead of one of them appearing to
  take effect and then snapping back.
- Time you add to a block in the agenda now applies only to that block instead of every day.
- Fixed a loading spinner that could spin forever at the bottom of the activity feed after signing
  in for the first time. It now disappears as soon as the feed has finished pulling everything from
  the server.
- Fixed Finish not moving a thread to the top of Done. Finishing a thread you'd already read at some
  point left it sitting at its old position in Done because the bump timestamp was being dropped
  both locally (the optimistic update kept the old position) and on the server (the read-state
  upsert silently skipped the bump when the thread was already marked read). Finishing now reliably
  lands the thread at the top of Done.
- Fixed calendar events and priority blocks going missing from the agenda. Scheduled events at their
  actual times and priority blocks for outstanding todos (today, tomorrow, or any future day with a
  scheduled item) both stay visible regardless of how many other todos you've accumulated. Past
  events from earlier in the day also no longer linger once they've ended, and adding or finishing a
  todo for a new day adds or removes that day in the agenda right away.
- Fixed new calendar events and other items from connected apps not showing up on your desktop until
  you reloaded — they now sync in real time even while Plot is sitting in the background, and
  bringing the app to the foreground always pulls in anything that might have slipped through.
- Archiving a thread from the activity feed's more-commands menu (or right-click, or the unified
  header menu) now removes it from the list immediately instead of waiting for the next sync
  round-trip. Previously the archive still saved, but the list didn't update until you switched
  priorities or refreshed.
- Fixed "Remove from agenda" sometimes putting the thread back on the agenda a moment later —
  clicking the to-do button to finish a thread now sticks even when other sync activity (a
  teammate's update, an incoming reply, etc.) lands at the same time. Previously a concurrent
  background sync could overwrite your archive with the pre-click state, so the thread reappeared on
  its own. Same protection now covers links and event nestings too.
- Fixed agenda block drag-and-drop instability — dragging a priority block into an empty gap between
  events no longer flickers as the layout shifts under you, and the drop zone now sticks at the last
  valid position when you cross over an event row or scroll past the agenda's edges instead of
  vanishing. The drop zone follows your pointer's intent rather than bouncing around as neighbouring
  blocks expand and collapse.
- Fixed two search annoyances — moving the cursor inside the search box no longer wipes results and
  re-runs the query, and searching for terms that contain a dot (like "cal.com") now returns the
  matches you'd expect instead of behaving as if the dot and everything after it weren't there.
- Fixed dragging a priority block onto another time slot in the same day — dropping the block
  "above" another time slot now moves it into that slot's period instead of the previous one, so
  merging blocks together by drag works regardless of which half of the destination you aim at.
  Reordering blocks within a single time slot also now respects period boundaries (so the reorder
  doesn't bracket against an unrelated block from a different time slot above), and the new ordering
  attaches to the slot itself (not "from now forward") — so it sticks for past dates, future dates,
  and time-traveled sessions, and re-reordering the same slot replaces its previous ordering instead
  of accumulating duplicates.
- Tightened a privacy gap where members of broadcast groups (like "Everyone") could end up exposed
  to each other's contact details through threads sent to those groups. Affected contacts have been
  removed from your contact list automatically, and the in-app cache now scrubs name and email when
  a contact is unshared.
- Fixed the desktop and mobile apps quietly stalling after your sign-in expired — if your session
  was ended on the server (signed out from another device, revoked, or just timed out), the app
  would keep running with a dead session and your new notes would silently stop syncing. Plot now
  reliably signs you out in that case so you can sign back in, while still riding out flaky-network
  blips without bouncing you to the sign-in screen.
- Fixed a sync edge case where a temporary server hiccup right as you started a new thread could
  leave its first note stranded on your device — the thread would land for the people you shared
  with, but their copy would look empty. Plot now keeps the note queued and retries it on the next
  sync instead of giving up, so the note shows up for everyone once the hiccup clears.
- Threads created in Using Plot now show up in Using Plot for everyone they're shared with — the
  thread routes to each recipient's Using Plot priority instead of landing in their root, even when
  no specific topic was set. The same rule applies to any priority that's the same across users
  (like Twist Development).
- Fixed a tiny vertical bounce in the agenda when starting to drag a priority block — the rest of
  your day now stays put instead of jumping up a pixel or two and drifting back as the source
  collapses.
- Fixed agenda block drag thresholds drifting after the first drag — picking up a priority block and
  dropping it back where it started no longer makes you drag farther on the next attempt before
  neighbors shift out of the way.
- Fixed drag-to-reorder snapping back inside collapsed priority blocks — todos that span different
  scheduled dates (overdue, today, undated) now stay where you drop them instead of jumping back to
  the top of the block. Drops also respect priority block boundaries so an unrelated neighbor in a
  different block can no longer derail the new position.
- Team members now get unlimited AI titles and summaries — previously the monthly free-tier cap
  could still apply to people on a team plan if their personal plan was free, so new threads
  sometimes ended up titled with the first line of the note instead of an AI-generated summary
- Fixed Gmail replies sometimes not showing up in Plot — incoming replies on existing email threads
  now sync reliably even when the new reply isn't itself starred or marked Important. The connector
  now watches your whole mailbox for changes and routes each thread to the right channel based on
  its labels.
- Fixed contacts with multiple linked email addresses appearing twice — the same person now shows up
  once everywhere (assignees, share, mentions, avatars), and assigning or completing a to-do for
  them stays a single entry even if Plot saw their other email later
- Fixed "Show archived" turning itself off when you cleared the search bar — archived visibility is
  now fully independent from search and filters
- Fixed silent sign-outs — when your session expires, you now see a banner on the sign-in page (and
  a one-off notification on mobile) instead of just stopping receiving updates
- Fixed bidirectional Gmail star ↔ Plot to-do sync — starring a message in Gmail now reliably
  creates a to-do in Plot, and toggling the to-do in Plot stars/unstars in Gmail
- Fixed contact names showing a trailing " via Plot" or similar from Google Groups and other mailing
  lists — sender names in lists and mentions are now shown cleanly
- Fixed adding a new connection showing the auth button without its spinner after authorizing — the
  button could be accidentally re-tapped mid-setup, which could disrupt the flow. The spinner now
  stays on through the entire setup.
- Fixed onboarding threads (Welcome, Priorities, Connections, etc.) not appearing for new sign-ups
  whose email had been shared on a thread before they joined — every new user now gets the full set
  of onboarding threads on their agenda
- Calendar event notes synced from Outlook and Teams look cleaner — "Manage Booking" and "Join"
  style links now appear as real clickable links instead of raw URLs, and long meeting URLs are
  shown as the site name instead of filling the screen
- Fixed missing notifications and unread indicators for threads shared to a team — feedback and
  other team-wide threads now correctly trigger push and email notifications, and show the unread
  dot on the priority they land in
- Archiving a thread from the activity feed now feels instant — the thread disappears immediately
  instead of after a noticeable delay
- Priorities with nothing on the agenda now open straight to the activity feed — and opening a
  thread that isn't on the agenda also switches to the feed, so you always land on a list that has
  your thread in it
- On an email thread with several people, you can now choose **Reply to [sender]** to write back to
  just the original sender. Tapping that tab used to jump the selection straight back to **Reply
  all**, so there was no way to keep it — the tab now stays selected like it should.
