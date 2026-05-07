#include "system_tray/tray_icon.h"

#include "widget_bridge/widget_shared_storage.h"

#include <shellapi.h>
#include <strsafe.h>

namespace plot::system_tray {

namespace {

constexpr UINT kCallbackId = 0xA011;
constexpr UINT WM_TRAY_CALLBACK = WM_APP + 1;

}  // namespace

TrayIcon::TrayIcon(HWND host_window) : host_window_(host_window) {
  data_.cbSize = sizeof(NOTIFYICONDATAW);
  data_.hWnd = host_window_;
  data_.uID = kCallbackId;
  data_.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
  data_.uCallbackMessage = WM_TRAY_CALLBACK;
  StringCchCopyW(data_.szTip, ARRAYSIZE(data_.szTip), L"Plot");
  Refresh();
}

TrayIcon::~TrayIcon() {
  TearDownIcon();
}

void TrayIcon::Refresh() {
  if (plot::widget_bridge::WidgetSharedStorage::TrayEnabled()) {
    EnsureIcon();
  } else {
    TearDownIcon();
  }
}

void TrayIcon::EnsureIcon() {
  if (icon_added_) return;
  data_.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
  if (!Shell_NotifyIconW(NIM_ADD, &data_)) {
    OutputDebugStringW(L"[tray] Shell_NotifyIcon NIM_ADD failed\n");
    return;
  }
  icon_added_ = true;
}

void TrayIcon::TearDownIcon() {
  if (!icon_added_) return;
  Shell_NotifyIconW(NIM_DELETE, &data_);
  icon_added_ = false;
}

}  // namespace plot::system_tray
