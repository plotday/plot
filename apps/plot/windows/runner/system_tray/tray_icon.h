#ifndef RUNNER_SYSTEM_TRAY_TRAY_ICON_H_
#define RUNNER_SYSTEM_TRAY_TRAY_ICON_H_

#include <windows.h>

namespace plot::system_tray {

// RAII wrapper around the Windows Shell_NotifyIconW API.
//
// The icon is only added to the tray when the
// `WidgetSharedStorage::TrayEnabled()` flag is true at construction
// time — default is false, so today this is a no-op for end users.
//
// Today the icon has no menu, no tooltip text beyond "Plot", and no
// click handlers. Drop UI in once tray designs land.
class TrayIcon {
 public:
  explicit TrayIcon(HWND host_window);
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // Re-evaluate the enable flag and add/remove the icon to match.
  // Called at startup and whenever Flutter triggers `reloadAll`.
  void Refresh();

 private:
  void EnsureIcon();
  void TearDownIcon();

  HWND host_window_;
  bool icon_added_ = false;
  NOTIFYICONDATAW data_ = {};
};

}  // namespace plot::system_tray

#endif  // RUNNER_SYSTEM_TRAY_TRAY_ICON_H_
