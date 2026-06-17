#include "flutter_window.h"

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Windows system-tray widget is disabled for now. The menu-bar surface was
  // redesigned (NSPopover on macOS); the matching Windows popup hasn't been
  // built yet (see docs/superpowers/plans/2026-06-17-menubar-redesign-3-windows-popup.md).
  // Rather than ship the legacy pomodoro tray menu alongside the new macOS UI,
  // we don't create the tray icon at all. The Dart widget bridge's channel
  // calls simply no-op on Windows (MissingPluginException is caught), and the
  // WM_COMMAND/WM_TIMER/tray-message routing below is already null-guarded.
  // To restore: define PLOT_ENABLE_WINDOWS_TRAY (and finish the popup plan).
#ifdef PLOT_ENABLE_WINDOWS_TRAY
  tray_icon_ =
      std::make_unique<plot::system_tray::TrayIcon>(GetHandle());
  widget_bridge_ = std::make_unique<plot::widget_bridge::WidgetBridgePlugin>(
      flutter_controller_->engine(), tray_icon_.get());
  // Route menu-item picks back into Flutter via the existing
  // `onWidgetAction` method-channel call.
  tray_icon_->SetActionDispatcher(
      [bridge = widget_bridge_.get()](const std::string& name) {
        bridge->SendAction(name);
      });
#endif

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Drop the bridge before the engine — the channel holds a raw
  // pointer into flutter_controller_'s messenger.
  widget_bridge_.reset();
  tray_icon_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (tray_icon_) {
    if (message == plot::system_tray::kTrayCallbackMessage) {
      tray_icon_->HandleTrayMessage(wparam, lparam);
    } else if (message == WM_COMMAND) {
      tray_icon_->HandleCommand(LOWORD(wparam));
    } else if (message == WM_TIMER) {
      tray_icon_->HandleTimer(static_cast<UINT_PTR>(wparam));
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
