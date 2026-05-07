#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "system_tray/tray_icon.h"
#include "widget_bridge/widget_bridge_plugin.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Optional system-tray surface; constructed but only attaches the
  // icon when the on-disk enable flag is set.
  std::unique_ptr<plot::system_tray::TrayIcon> tray_icon_;

  // MethodChannel bridge for widget state — owns the channel; safe to
  // hold raw pointers to flutter_controller_'s engine for its lifetime
  // because both are torn down in OnDestroy.
  std::unique_ptr<plot::widget_bridge::WidgetBridgePlugin> widget_bridge_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
