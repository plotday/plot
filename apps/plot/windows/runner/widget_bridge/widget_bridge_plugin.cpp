#include "widget_bridge/widget_bridge_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "system_tray/tray_icon.h"
#include "widget_bridge/widget_shared_storage.h"

namespace plot::widget_bridge {

namespace {
constexpr const char kChannelName[] = "day.plot/widgets";
}  // namespace

WidgetBridgePlugin::WidgetBridgePlugin(flutter::FlutterEngine* engine,
                                       plot::system_tray::TrayIcon* tray_icon)
    : tray_icon_(tray_icon) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

void WidgetBridgePlugin::SendAction(const std::string& name) {
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("name")] = flutter::EncodableValue(name);
  payload[flutter::EncodableValue("args")] =
      flutter::EncodableValue(flutter::EncodableMap{});
  channel_->InvokeMethod("onWidgetAction",
                         std::make_unique<flutter::EncodableValue>(payload));
}

void WidgetBridgePlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& name = call.method_name();
  if (name == "writeState") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) {
      result->Error("bad-args", "writeState requires a map argument");
      return;
    }
    auto it = args->find(flutter::EncodableValue("json"));
    if (it == args->end()) {
      result->Error("bad-args", "writeState requires {json}");
      return;
    }
    const auto* json = std::get_if<std::string>(&it->second);
    if (!json) {
      result->Error("bad-args", "json must be a string");
      return;
    }
    WidgetSharedStorage::WriteState(*json);
    result->Success();
    return;
  }
  if (name == "reloadAll") {
    if (tray_icon_) tray_icon_->Refresh();
    result->Success();
    return;
  }
  result->NotImplemented();
}

}  // namespace plot::widget_bridge
