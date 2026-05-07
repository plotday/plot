#ifndef RUNNER_WIDGET_BRIDGE_WIDGET_SHARED_STORAGE_H_
#define RUNNER_WIDGET_BRIDGE_WIDGET_SHARED_STORAGE_H_

#include <optional>
#include <string>

namespace plot::widget_bridge {

// On-disk paths under %APPDATA%\Plot used to share widget state with
// the (eventual) tray icon and any future external surfaces.
//
// Files are written atomically (temp file + ReplaceFile). Readers
// should tolerate the file being missing or transiently empty.
class WidgetSharedStorage {
 public:
  // Returns the absolute path to the JSON state file, creating
  // parent directories on demand. Returns std::nullopt if %APPDATA%
  // could not be resolved.
  static std::optional<std::wstring> StateFilePath();

  // Returns the absolute path to the tray-enable flag file. Same
  // semantics as StateFilePath.
  static std::optional<std::wstring> EnableFlagFilePath();

  // Persists the given JSON payload. No-op on failure (logs to
  // OutputDebugStringW).
  static void WriteState(const std::string& json);

  // Returns the persisted JSON payload, or an empty string if
  // missing / unreadable.
  static std::string ReadState();

  // True iff the tray-enable flag file exists with a non-empty body
  // that is not "false" / "0".
  static bool TrayEnabled();
};

}  // namespace plot::widget_bridge

#endif  // RUNNER_WIDGET_BRIDGE_WIDGET_SHARED_STORAGE_H_
