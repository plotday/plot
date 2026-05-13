#ifndef RUNNER_SYSTEM_TRAY_TRAY_ICON_H_
#define RUNNER_SYSTEM_TRAY_TRAY_ICON_H_

#include <windows.h>

#include <functional>
#include <string>

namespace plot::system_tray {

// Win32 message ID emitted by Shell_NotifyIcon on tray interactions.
// Exposed so `FlutterWindow::MessageHandler` can route to
// `TrayIcon::HandleTrayMessage` without re-declaring the constant.
constexpr UINT kTrayCallbackMessage = WM_APP + 1;

// Timer ID used to refresh the tooltip every second while a timer is
// running. Routed through `FlutterWindow::MessageHandler` (which
// dispatches `WM_TIMER` to `TrayIcon::HandleTimer`).
constexpr UINT_PTR kTrayTickTimerId = 1001;

// Owns the Windows system-tray surface.
//
// State is pushed in-process from `WidgetBridgePlugin::ApplyState` —
// the menu mirrors the unified-header tracking control (priority,
// event, timer, Start / Pause / Stop / Add 15m / Remove 15m). The
// tooltip on the icon ticks each second with a ceil-to-minutes
// countdown so the visible state stays current between Flutter state
// writes. The icon is always created on startup; there's no permission
// to worry about on Windows.
class TrayIcon {
 public:
  using ActionDispatcher = std::function<void(const std::string&)>;

  explicit TrayIcon(HWND host_window);
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // Replace the in-memory state snapshot the menu reads from and
  // re-render anything that depends on it.
  void ApplyState(const std::string& json);

  // Re-render the surface without changing the state snapshot.
  void Refresh();

  // Set the callback invoked when the user picks a menu item. Called
  // by `FlutterWindow::OnCreate` after both the tray icon and widget
  // bridge plugin exist.
  void SetActionDispatcher(ActionDispatcher dispatcher);

  // Win32 message routing (called from FlutterWindow::MessageHandler).
  void HandleTrayMessage(WPARAM wparam, LPARAM lparam);
  void HandleCommand(WORD command_id);
  void HandleTimer(UINT_PTR timer_id);

 private:
  struct Snapshot {
    bool is_signed_in = false;
    std::wstring priority_title;
    std::wstring event_title;
    std::wstring timer_state = L"inactive";
    std::wstring timer_source;
    long long timer_ends_at_unix_ms = 0;  // 0 when no timer
    bool can_start = false;
    bool can_pause = false;
    bool can_stop = false;
    bool can_add_time = false;
    bool can_remove_time = false;
  };

  void EnsureIcon();
  void TearDownIcon();
  void ShowContextMenu();
  void UpdateTooltip();
  // Swap between the Plot logo icon and a dynamically-rendered "time
  // remaining" icon. Windows tray icons can't show text beside them
  // (Explorer forces a single 16×16-ish glyph), so when a timer is
  // running the countdown is drawn into the icon itself.
  void UpdateTrayIcon();
  // Render `text` (e.g. "5m", "1h", "1h5m") into a fresh HICON sized to
  // SM_CXSMICON. Caller owns the returned HICON and must DestroyIcon it.
  HICON CreateCountdownIcon(const std::wstring& text);
  void StartTickTimer();
  void StopTickTimer();
  Snapshot ParseSnapshot(const std::string& json);

  HWND host_window_;
  bool icon_added_ = false;
  bool tick_active_ = false;
  NOTIFYICONDATAW data_ = {};
  Snapshot current_state_;
  ActionDispatcher action_dispatcher_;

  // Owned icons: `logo_icon_` is loaded once from the runner resources,
  // `countdown_icon_` is regenerated each time `displayed_text_` changes.
  // `displayed_text_` empty ⇒ the logo is currently shown.
  HICON logo_icon_ = nullptr;
  HICON countdown_icon_ = nullptr;
  std::wstring displayed_text_;
};

}  // namespace plot::system_tray

#endif  // RUNNER_SYSTEM_TRAY_TRAY_ICON_H_
