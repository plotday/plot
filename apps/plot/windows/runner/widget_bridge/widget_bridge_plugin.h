#ifndef RUNNER_WIDGET_BRIDGE_WIDGET_BRIDGE_PLUGIN_H_
#define RUNNER_WIDGET_BRIDGE_WIDGET_BRIDGE_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace flutter {
class FlutterEngine;
}

namespace plot::system_tray {
class TrayIcon;
}

namespace plot::widget_bridge {

// Windows side of the `day.plot/widgets` MethodChannel.
//
// Persists state to %APPDATA%\Plot\widget-state.json and triggers a
// repaint of the (optional) system tray. No widget UI exists yet —
// this is plumbing only.
class WidgetBridgePlugin {
 public:
  WidgetBridgePlugin(flutter::FlutterEngine* engine,
                     plot::system_tray::TrayIcon* tray_icon);

  // Send an action back to Flutter — reserved for future tray
  // click handlers.
  void SendAction(const std::string& name);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  plot::system_tray::TrayIcon* tray_icon_;  // not owned
};

}  // namespace plot::widget_bridge

#endif  // RUNNER_WIDGET_BRIDGE_WIDGET_BRIDGE_PLUGIN_H_
