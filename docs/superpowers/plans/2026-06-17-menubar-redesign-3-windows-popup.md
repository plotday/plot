# Menu-bar redesign — Plan 3: Windows tray popup shell

> **STATUS (2026-06-17): DEFERRED — not started.** Flutter cannot cross-compile
> Windows from macOS, so this C++ can't be built/verified without a Windows
> host/CI. The legacy Windows system-tray widget is currently **hidden** behind
> the `PLOT_ENABLE_WINDOWS_TRAY` compile guard in
> `apps/plot/windows/runner/flutter_window.cpp` (the tray icon is simply not
> created). To implement this plan: get Windows access, remove that guard (or
> define the macro), re-add Task 1's structured-`state` channel payload (it was
> reverted from the macOS-only branch since nothing consumed it — see
> `widget_bridge_channel.dart writeState`), then execute Tasks 1–6 below.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Windows tray right-click `HMENU` with a borderless popup
window that renders the redesigned surface from Plan 1's `WidgetState` (NOW/NEXT
events with Join, current focus + switcher, top-5 to-dos, quick capture, compact
timer, footer), at parity with the macOS popover (Plan 2). Keep the dynamic
tray-icon countdown, now driven by the computed title; show the full title in
the tooltip.

**Architecture:** A new `TrayPopup` owns a `WS_POPUP` layered, tool-window
(no taskbar button) anchored near the notification area. Left-click on the tray
icon shows it; it dismisses on deactivate. Its own `WndProc` lays out native
child controls (static labels, an edit box for capture, buttons) and maps their
`WM_COMMAND` ids to Plan 1 action names, looking up per-row arg payloads
(thread/focus ids) from a side table. Right-click keeps a minimal `HMENU` with
Quit as a fallback. The tray icon shows the countdown glyph when a timer runs
(else the logo), and the tooltip shows the full computed title.
**Depends on Plan 1** (contract + handlers) and **Plan 2 Task 1** (the channel
sends the structured `state` map). The dev environment here is macOS; the
Windows build/verification steps require a Windows host or CI runner.

**Tech Stack:** C++17, Win32 (`CreateWindowEx`, `WS_POPUP`, layered windows,
`EDIT`/`BUTTON`/`STATIC` controls, GDI), Flutter Windows embedding
(`flutter::EncodableValue` codec), `Shell_NotifyIcon`.

## Global Constraints

- UI text sentence case (first word + proper nouns only).
- Keep the tray in-process; state is pushed in-process (no shared-file parsing
  required for the live surface — read the `EncodableMap` directly).
- `TrayIcon`/`TrayPopup` stay free of Flutter headers; the **plugin** converts
  `EncodableMap` → a plain `WidgetState` struct (new `tray_state.h`).
- Action names + arg keys match Plan 1 exactly (`navigateThread`/`navigateFocus`/
  `setCurrentFocus`/`joinCall`/`capture`/`openApp` + timer actions; arg keys
  `threadId`, `priorityId`, `focusId`, `text`, `target`).
- Build check (Windows host/CI): `cd apps/plot && flutter build windows --debug`
  must succeed. Native UI verified manually on a Windows build.
- Preserve the existing GDI countdown-icon rendering (`CreateCountdownIcon`) and
  theme-aware text colour.

## File structure

- **Create** `apps/plot/windows/runner/system_tray/tray_state.h` — plain
  `WidgetState`/`Focus`/`Event`/`Todo` structs (no Flutter deps).
- **Modify** `apps/plot/windows/runner/widget_bridge/widget_bridge_plugin.{h,cpp}`
  — convert the structured `EncodableMap` into `tray_state::WidgetState`; widen
  `SendAction` + the dispatcher to carry an args map.
- **Modify** `apps/plot/windows/runner/system_tray/tray_icon.{h,cpp}` — hold the
  new state struct; drive icon/tooltip from the computed title; show the popup on
  left-click; keep a minimal right-click Quit menu; forward args on actions.
- **Create** `apps/plot/windows/runner/system_tray/tray_popup.{h,cpp}` — the
  borderless popup window + child-control layout + command routing.
- **Modify** `apps/plot/windows/runner/flutter_window.cpp` — no new routing
  needed (the popup has its own `WndProc`); confirm the tray-message route still
  reaches `HandleTrayMessage`.

---

### Task 1: Plain state structs (`tray_state.h`)

**Files:**
- Create: `apps/plot/windows/runner/system_tray/tray_state.h`

**Interfaces:**
- Produces (namespace `plot::system_tray`):
  - `struct TsFocus { std::wstring focus_id, focus_name; std::wstring role_name; bool has_role_name; std::wstring color_hex; bool has_color; };`
  - `struct TsEvent { std::wstring thread_id, title, start_iso; std::wstring end_iso; bool has_end; bool has_call; bool present = false; };`
  - `struct TsTodo { std::wstring thread_id, title; };`
  - `struct WidgetState { bool is_signed_in=false; std::wstring title; bool title_is_timer=false; std::wstring timer_title_prefix; long long timer_ends_at_unix_ms=0; TsFocus current_focus; bool has_current_focus=false; TsEvent current_event; TsEvent next_event; std::vector<TsTodo> todos; std::vector<TsFocus> focuses; };`
- Consumed by: Tasks 2–4.

- [ ] **Step 1: Create the header** with the structs above (include `<string>`,
  `<vector>`). Pure data; no methods.

- [ ] **Step 2: Commit**

```bash
git add apps/plot/windows/runner/system_tray/tray_state.h
git commit -m "feat(windows): plain tray WidgetState structs (no flutter deps)"
```

---

### Task 2: Plugin converts the structured map + widened action args

**Files:**
- Modify: `apps/plot/windows/runner/widget_bridge/widget_bridge_plugin.h`
- Modify: `apps/plot/windows/runner/widget_bridge/widget_bridge_plugin.cpp:27-59`
- Modify: `apps/plot/windows/runner/system_tray/tray_icon.h:32,42,50`
- Modify: `apps/plot/windows/runner/system_tray/tray_icon.cpp` (`ApplyState`,
  `SetActionDispatcher`, dispatcher type)

**Interfaces:**
- Produces:
  - `using ActionDispatcher = std::function<void(const std::string& name, const std::map<std::string, std::string>& args)>;` (widened on `TrayIcon`).
  - `void TrayIcon::ApplyState(const WidgetState& state);` (replaces the
    `std::string json` overload).
  - `void WidgetBridgePlugin::SendAction(const std::string& name, const std::map<std::string, std::string>& args);`
- Consumed by: Tasks 3–4.

The codec delivers nested values: `EncodableMap` for objects, `EncodableList`
for arrays, `EncodableValue` holding `std::string`/`bool`/`double`. Conversion
lives in the plugin (it already includes the Flutter codec headers).

- [ ] **Step 1: Widen `SendAction`** in the plugin header + impl:

```cpp
// header
void SendAction(const std::string& name,
                const std::map<std::string, std::string>& args);
// cpp
void WidgetBridgePlugin::SendAction(
    const std::string& name,
    const std::map<std::string, std::string>& args) {
  flutter::EncodableMap arg_map;
  for (const auto& [k, v] : args) {
    arg_map[flutter::EncodableValue(k)] = flutter::EncodableValue(v);
  }
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("name")] = flutter::EncodableValue(name);
  payload[flutter::EncodableValue("args")] = flutter::EncodableValue(arg_map);
  channel_->InvokeMethod(
      "onWidgetAction",
      std::make_unique<flutter::EncodableValue>(payload));
}
```

- [ ] **Step 2: Convert the structured `state` map** in `HandleMethodCall`'s
`writeState` branch. Add helpers (file-local) to read typed fields from an
`EncodableMap`, then build `WidgetState`:

```cpp
// file-local helpers in widget_bridge_plugin.cpp
namespace {
using flutter::EncodableMap;
using flutter::EncodableList;
using flutter::EncodableValue;

const EncodableValue* Find(const EncodableMap& m, const char* key) {
  auto it = m.find(EncodableValue(std::string(key)));
  return it == m.end() ? nullptr : &it->second;
}
std::string Str(const EncodableMap& m, const char* key) {
  const auto* v = Find(m, key);
  if (v) if (const auto* s = std::get_if<std::string>(v)) return *s;
  return {};
}
bool Has(const EncodableMap& m, const char* key) {
  const auto* v = Find(m, key);
  return v && !std::holds_alternative<std::monostate>(*v);
}
bool Bool(const EncodableMap& m, const char* key) {
  const auto* v = Find(m, key);
  if (v) if (const auto* b = std::get_if<bool>(v)) return *b;
  return false;
}
// Utf8->wide via the existing helper in tray_icon (expose it) or MultiByteToWideChar.
}  // namespace
```

Build the struct (use `MultiByteToWideChar` or the existing `Utf8ToWide`):

```cpp
    if (const auto* state_v = Find(*args, "state")) {
      if (const auto* sm = std::get_if<EncodableMap>(state_v)) {
        plot::system_tray::WidgetState st;
        st.is_signed_in = Bool(*sm, "isSignedIn");
        st.title = Utf8ToWide(Str(*sm, "title"));
        st.title_is_timer = Bool(*sm, "titleIsTimer");
        st.timer_title_prefix = Utf8ToWide(Str(*sm, "timerTitlePrefix"));
        st.timer_ends_at_unix_ms = ParseIsoToUnixMs(Str(*sm, "timerEndsAtIso"));
        // currentFocus
        if (const auto* fv = Find(*sm, "currentFocus")) {
          if (const auto* fm = std::get_if<EncodableMap>(fv)) {
            st.has_current_focus = true;
            st.current_focus = ToFocus(*fm);   // small local builder
          }
        }
        st.current_event = ToEvent(Find(*sm, "currentEvent2"));
        st.next_event = ToEvent(Find(*sm, "nextEvent2"));
        if (const auto* tv = Find(*sm, "todos")) {
          if (const auto* tl = std::get_if<EncodableList>(tv)) {
            for (const auto& e : *tl) {
              if (const auto* em = std::get_if<EncodableMap>(&e)) {
                st.todos.push_back({Utf8ToWide(Str(*em, "threadId")),
                                    Utf8ToWide(Str(*em, "title"))});
              }
            }
          }
        }
        // focuses: same shape as currentFocus
        if (const auto* fv = Find(*sm, "focuses")) {
          if (const auto* fl = std::get_if<EncodableList>(fv)) {
            for (const auto& e : *fl) {
              if (const auto* fm = std::get_if<EncodableMap>(&e)) {
                st.focuses.push_back(ToFocus(*fm));
              }
            }
          }
        }
        if (tray_icon_) tray_icon_->ApplyState(st);
      }
    }
    result(nullptr);
```

Implement `ToFocus(const EncodableMap&)` and `ToEvent(const EncodableValue*)`
file-local builders. `ParseIsoToUnixMs` and `Utf8ToWide` already exist in
`tray_icon.cpp` — promote their declarations to a shared spot
(`tray_state.h` or a small `tray_util.h`) so the plugin can call them.

- [ ] **Step 3: Replace `TrayIcon::ApplyState(json)`** with
`ApplyState(const WidgetState&)`: store into a `WidgetState current_state_;`
member (replacing the old `Snapshot current_state_`), then
`UpdateTrayIcon(); UpdateTooltip(); /* Start/StopTickTimer */`. Delete
`ParseSnapshot` and the old `Snapshot` struct (moved to `tray_state.h`).
Widen `action_dispatcher_` + `SetActionDispatcher` to the new signature; in
`FlutterWindow::OnCreate` update the lambda wiring to forward args:

```cpp
// flutter_window.cpp (where SetActionDispatcher is wired)
tray_icon_->SetActionDispatcher(
    [plugin = widget_bridge_plugin_.get()](
        const std::string& name,
        const std::map<std::string, std::string>& args) {
      if (plugin) plugin->SendAction(name, args);
    });
```

- [ ] **Step 4: Build (Windows host/CI)**

Run: `cd apps/plot && flutter build windows --debug`
Expected: compiles (the popup is added in Task 4; for now `HandleTrayMessage`
still shows the old menu — temporarily keep `ShowContextMenu` so this task builds
in isolation).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/windows/runner/widget_bridge/ apps/plot/windows/runner/system_tray/tray_icon.h apps/plot/windows/runner/system_tray/tray_icon.cpp apps/plot/windows/runner/flutter_window.cpp
git commit -m "feat(windows): plugin converts structured state; widened action args"
```

---

### Task 3: Tray icon + tooltip from the computed title

**Files:**
- Modify: `apps/plot/windows/runner/system_tray/tray_icon.cpp`
  (`UpdateTrayIcon`, `UpdateTooltip`, `NeedsTicking`)

**Interfaces:**
- Consumes: `WidgetState` (Task 1), `current_state_` (Task 2).
- Produces: icon shows the countdown glyph when `title_is_timer`, else the logo;
  tooltip shows the full computed `title` (or `"prefix · Nm"` while ticking).

- [ ] **Step 1: Drive the icon from `title_is_timer`.** In `UpdateTrayIcon`,
replace the old `timer_state == "running"` logic:

```cpp
  std::wstring text;
  if (current_state_.title_is_timer && current_state_.timer_ends_at_unix_ms > 0) {
    long long remaining_ms = current_state_.timer_ends_at_unix_ms - UnixNowMs();
    text = FormatRemaining(remaining_ms / 1000);  // e.g. "24m"
  }
  // text empty ⇒ show logo; else render countdown glyph (existing path).
```

- [ ] **Step 2: Tooltip = full title.** In `UpdateTooltip`, set `tip` to the
computed title, composing the ticking case:

```cpp
  std::wstring tip;
  if (!current_state_.is_signed_in) {
    tip = L"Plot";
  } else if (current_state_.title_is_timer &&
             current_state_.timer_ends_at_unix_ms > 0) {
    long long rem = current_state_.timer_ends_at_unix_ms - UnixNowMs();
    std::wstring r = FormatRemaining(rem / 1000);
    tip = current_state_.timer_title_prefix.empty()
              ? r
              : current_state_.timer_title_prefix + L" · " + r;
  } else {
    tip = current_state_.title.empty() ? L"Plot" : current_state_.title;
  }
  StringCchCopyW(data_.szTip, ARRAYSIZE(data_.szTip), tip.c_str());
  Shell_NotifyIconW(NIM_MODIFY, &data_);
```

- [ ] **Step 3: `NeedsTicking`** returns `current_state_.title_is_timer`
(the imminent-event label is now precomputed in `title` and pushed on change).

- [ ] **Step 4: Build (Windows host/CI)** + commit

```bash
cd apps/plot && flutter build windows --debug
git add apps/plot/windows/runner/system_tray/tray_icon.cpp
git commit -m "feat(windows): tray icon + tooltip driven by computed title"
```

---

### Task 4: `TrayPopup` — borderless popup window

**Files:**
- Create: `apps/plot/windows/runner/system_tray/tray_popup.h`
- Create: `apps/plot/windows/runner/system_tray/tray_popup.cpp`
- Modify: `apps/plot/windows/runner/system_tray/tray_icon.cpp`
  (`HandleTrayMessage`: left-click → popup, right-click → minimal Quit menu)

**Interfaces:**
- Consumes: `WidgetState` (Task 1), the widened `ActionDispatcher` (Task 2).
- Produces:
  - `class TrayPopup` with:
    - `explicit TrayPopup(HINSTANCE, ActionDispatcher);`
    - `void Show(const WidgetState& state, POINT anchor);`
    - `void Hide();`
  - Emits action names + arg maps via the dispatcher.

The window: `CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, ...,
WS_POPUP, ...)`, no taskbar button, ~320 px wide, height computed from content.
Dismiss on `WM_ACTIVATE`→`WA_INACTIVE` (or `WM_KILLFOCUS`). Child controls are
created per `Show()` (cleared and rebuilt each time so the content matches the
current state). Each interactive control gets a command id; a
`std::map<int, std::pair<std::string,std::map<std::string,std::string>>>`
maps command id → (action, args). The capture `EDIT` submits on Enter (subclass
or handle `WM_COMMAND`/`EN_*` + a Send button).

- [ ] **Step 1: Window class + lifecycle skeleton**

```cpp
// tray_popup.cpp (essentials)
namespace plot::system_tray {

static const wchar_t* kPopupClass = L"PlotTrayPopup";

TrayPopup::TrayPopup(HINSTANCE inst, ActionDispatcher dispatcher)
    : instance_(inst), dispatcher_(std::move(dispatcher)) {
  WNDCLASSW wc = {};
  wc.lpfnWndProc = &TrayPopup::WndProc;
  wc.hInstance = inst;
  wc.lpszClassName = kPopupClass;
  wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClassW(&wc);
}

void TrayPopup::Show(const WidgetState& state, POINT anchor) {
  if (!hwnd_) {
    hwnd_ = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kPopupClass, L"", WS_POPUP,
        0, 0, kWidth, 10, nullptr, nullptr, instance_, this);
  }
  BuildContent(state);                 // clears + recreates child controls
  int height = LayoutControls();       // returns total content height
  // Anchor above-left of the cursor/tray (bottom-right of screen).
  SetWindowPos(hwnd_, HWND_TOPMOST,
               anchor.x - kWidth, anchor.y - height,
               kWidth, height, SWP_SHOWWINDOW);
  SetForegroundWindow(hwnd_);
}

void TrayPopup::Hide() { if (hwnd_) ShowWindow(hwnd_, SW_HIDE); }

LRESULT CALLBACK TrayPopup::WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
  auto* self = reinterpret_cast<TrayPopup*>(GetWindowLongPtrW(h, GWLP_USERDATA));
  if (m == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(l);
    SetWindowLongPtrW(h, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return DefWindowProcW(h, m, w, l);
  }
  switch (m) {
    case WM_ACTIVATE:
      if (LOWORD(w) == WA_INACTIVE && self) self->Hide();
      return 0;
    case WM_COMMAND:
      if (self) self->OnCommand(LOWORD(w), HIWORD(w));
      return 0;
  }
  return DefWindowProcW(h, m, w, l);
}

}  // namespace plot::system_tray
```

- [ ] **Step 2: `BuildContent` / `LayoutControls`** — create child controls top
to bottom and record their command ids + payloads. Sections (skip empties):

  - **Events** (only if `state.current_event.present || state.next_event.present`):
    for each present event, a `STATIC` "Now"/"Next" + title (clickable: a
    transparent `BUTTON` over the row mapped to `navigateThread` with
    `{threadId, priorityId=currentFocus.focus_id}`); if `has_call`, a "Join"
    `BUTTON` mapped to `joinCall {threadId}`.
  - **Focus header**: `STATIC` with `role › focus` (role only if `has_role_name`),
    in the focus colour (owner-draw or `SetTextColor` via `WM_CTLCOLORSTATIC`);
    a "▾" `BUTTON` mapped to a focus-switch sub-menu (a real `HMENU` popup listing
    `state.focuses`, each item → `setCurrentFocus {focusId}`); clicking the
    header label maps to `navigateFocus {priorityId=focus_id}`.
  - **To-dos**: up to 5 `BUTTON`s (flat) each mapped to `navigateThread
    {threadId, priorityId=currentFocus.focus_id}`.
  - **Capture**: an `EDIT` (cue banner via `EM_SETCUEBANNER` = the
    "Add note in …" placeholder) + a Send `BUTTON` mapped to `capture`
    (args built at submit time from the edit text + target:
    `currentEventThread` if `current_event.present` else
    `newThreadInCurrentFocus`).
  - **Timer**: `STATIC` "Focus timer" + a Start (or Pause/Stop when
    `title_is_timer`) `BUTTON` → `startTimer`/`pauseTimer`/`stopTimer`.
  - **Footer**: "Open Plot" `BUTTON` → `openApp`; "Quit" `BUTTON` → posts
    `WM_CLOSE` to the host window (mirror `IDM_TRAY_QUIT`).

`LayoutControls` positions each control with a running `y` cursor and returns the
total height. Use a fixed `kWidth = 320` and standard control heights.

- [ ] **Step 3: `OnCommand`** — look up the command id in the payload table; if
found, `dispatcher_(action, args)` and `Hide()`. The capture Send builds its
args from the live `EDIT` text:

```cpp
void TrayPopup::OnCommand(WORD id, WORD code) {
  if (id == kCaptureSendId) {
    wchar_t buf[1024];
    GetWindowTextW(capture_edit_, buf, ARRAYSIZE(buf));
    std::string text = WideToUtf8(buf);
    if (!text.empty()) {
      dispatcher_("capture",
                  {{"text", text}, {"target", capture_target_}});
    }
    Hide();
    return;
  }
  auto it = commands_.find(id);
  if (it != commands_.end()) {
    dispatcher_(it->second.first, it->second.second);
    Hide();
  }
}
```

- [ ] **Step 4: Wire the tray click** in `tray_icon.cpp` `HandleTrayMessage`:

```cpp
void TrayIcon::HandleTrayMessage(WPARAM, LPARAM lparam) {
  UINT event = LOWORD(lparam);
  if (event == WM_LBUTTONUP) {
    POINT pt; GetCursorPos(&pt);
    EnsurePopup();                 // lazily create TrayPopup with dispatcher
    popup_->Show(current_state_, pt);
  } else if (event == WM_RBUTTONUP) {
    ShowQuitMenu();                // minimal HMENU: just "Quit Plot"
  }
}
```

`EnsurePopup()` constructs `TrayPopup` with the host instance and a dispatcher
lambda that forwards to `action_dispatcher_`. `ShowQuitMenu()` is the old
`ShowContextMenu` trimmed to the signed-out/Quit path. `TrayIcon` gains a
`std::unique_ptr<TrayPopup> popup_;` member and includes `tray_popup.h`.

- [ ] **Step 5: Build (Windows host/CI)**

Run: `cd apps/plot && flutter build windows --debug`
Expected: compiles; left-click shows the popup, right-click shows Quit.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/windows/runner/system_tray/tray_popup.h apps/plot/windows/runner/system_tray/tray_popup.cpp apps/plot/windows/runner/system_tray/tray_icon.h apps/plot/windows/runner/system_tray/tray_icon.cpp
git commit -m "feat(windows): borderless tray popup window replacing the context menu"
```

Add the new sources to `apps/plot/windows/runner/CMakeLists.txt` if it lists
sources explicitly (check before building — the runner CMake may glob).

---

### Task 5: End-to-end verification on a Windows build

**Files:** none (verification + polish).

- [ ] **Step 1:** On a Windows host/VM, build and run against a seeded account
  (margot seed: 3 roles + events). `flutter run -d windows` or the packaged
  build.
- [ ] **Step 2:** Verify parity with the macOS popover:
  - Tray icon: logo at rest; countdown glyph while a timer runs; tooltip shows
    the full computed title (focus / `Role › Focus` / `Nm → Event` / event title
    / `Focus · Nm`).
  - Left-click → popup; right-click → Quit menu.
  - NOW/NEXT events present with seeded events; **section absent** when no events
    today.
  - Join button only when the event has a conferencing link; launches the URL.
  - Focus switch (▾) changes current focus; tooltip + to-dos + capture follow.
  - To-dos: ≤5 active tasks; click opens the thread (window restores).
  - Capture: type + Send creates a note in the current event thread (event in
    progress) or a new thread in the current focus.
  - Timer Start/Pause/Stop drive the in-app pill.
  - Open Plot restores the window; Quit exits.
- [ ] **Step 3:** Polish layout/spacing; re-verify; commit tweaks.

```bash
git add apps/plot/windows/runner/system_tray/
git commit -m "polish(windows): tray popup layout after on-device verification"
```

---

### Task 6: Remove legacy contract fields (cross-platform cleanup)

Run only after **both** Plan 2 and Plan 3 are verified on-device.

**Files:**
- Modify: `apps/plot/lib/widget_bridge/widget_data.dart` (drop
  `currentEventTitle`, `nextEventTitle`, `nextEventStartIso`, and the legacy
  timer-`can*` flags if unused; rename `currentEvent2`/`nextEvent2` →
  `currentEvent`/`nextEvent`).
- Modify: `apps/plot/lib/widget_bridge/widget_bridge.dart` (stop populating the
  dropped fields).
- Modify: `apps/plot/lib/widget_bridge/widget_bridge_channel.dart` (drop the
  legacy `json` payload key once neither shell reads it).
- Modify: macOS `MenuBarModel.swift` + Windows plugin to read the renamed keys.
- Update tests referencing the old fields.

- [ ] **Step 1:** Grep both native trees + Dart for the legacy keys; confirm
  nothing reads them.

Run: `grep -rn "currentEventTitle\|nextEventTitle\|nextEventStartIso\|\"json\"" apps/plot/macos apps/plot/windows apps/plot/lib/widget_bridge`
Expected: only the definitions about to be removed.

- [ ] **Step 2:** Remove the fields/keys, rename `currentEvent2`/`nextEvent2`,
  update `toJson`/`props`, both native readers, and tests.

- [ ] **Step 3:** `cd apps/plot && flutter analyze && flutter test test/widget_bridge/`
  + build both shells. Commit.

```bash
git add apps/plot/lib/widget_bridge apps/plot/macos apps/plot/windows apps/plot/test/widget_bridge
git commit -m "refactor(widget-bridge): drop legacy event/json fields after shell migration"
```

## Self-review

- **Spec coverage:** title→icon/tooltip (Task 3), NOW/NEXT + Join +
  hide-when-empty (Task 4), focus header + switcher (Task 4), to-dos (Task 4),
  capture with target rule (Task 4), compact timer (Task 4), footer (Task 4),
  cross-platform legacy cleanup (Task 6).
- **Placeholder scan:** the popup's `BuildContent`/`LayoutControls` are described
  as concrete control sequences with command-id→action mapping rather than
  pixel-perfect code — appropriate for a Win32 layout that needs on-device
  tuning (Task 5). No vague logic TBDs; the action/arg contract is exact.
- **Type consistency:** struct field names map 1:1 to Plan 1's JSON keys
  (`focusId`/`focusName`/`roleName`/`colorHex`, `threadId`/`title`/`startIso`/
  `endIso`/`hasCall`, `currentEvent2`/`nextEvent2`, `todos`, `focuses`,
  `title`/`titleIsTimer`/`timerTitlePrefix`). Action names + arg keys match
  Plan 1 Task 8 and Plan 2.
- **Dependencies:** Task 2 here depends on Plan 2 Task 1 (structured `state`
  payload). Task 6 depends on both shells shipping. Quit stays native (posts
  `WM_CLOSE`), matching Plan 2's native Quit — no `widgetActionQuit` needed.
- **Build caveat:** the dev environment is macOS; all `flutter build windows`
  steps require a Windows host or CI runner. Flagged in each build step.
