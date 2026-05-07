#include "widget_bridge/widget_shared_storage.h"

#include <windows.h>
#include <shlobj.h>

#include <fstream>
#include <sstream>
#include <vector>

namespace plot::widget_bridge {

namespace {

constexpr const wchar_t kAppFolder[] = L"Plot";
constexpr const wchar_t kStateFile[] = L"widget-state.json";
constexpr const wchar_t kEnableFlagFile[] = L"widget-flags.json";

std::optional<std::wstring> AppDataDir() {
  PWSTR raw = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &raw))) {
    return std::nullopt;
  }
  std::wstring base(raw);
  CoTaskMemFree(raw);
  std::wstring dir = base + L"\\" + kAppFolder;
  if (!CreateDirectoryW(dir.c_str(), nullptr)) {
    DWORD err = GetLastError();
    if (err != ERROR_ALREADY_EXISTS) {
      OutputDebugStringW((L"[widget-bridge] CreateDirectory failed: " + dir + L"\n").c_str());
      return std::nullopt;
    }
  }
  return dir;
}

std::string ReadFileUtf8(const std::wstring& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) return {};
  std::ostringstream buf;
  buf << stream.rdbuf();
  return buf.str();
}

void WriteFileAtomicUtf8(const std::wstring& target, const std::string& contents) {
  std::wstring tmp = target + L".tmp";
  {
    std::ofstream stream(tmp, std::ios::binary | std::ios::trunc);
    if (!stream) {
      OutputDebugStringW(L"[widget-bridge] failed to open tmp file for writing\n");
      return;
    }
    stream.write(contents.data(), static_cast<std::streamsize>(contents.size()));
  }
  if (!ReplaceFileW(target.c_str(), tmp.c_str(), nullptr, 0, nullptr, nullptr)) {
    if (!MoveFileExW(tmp.c_str(), target.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
      OutputDebugStringW(L"[widget-bridge] atomic replace failed\n");
    }
  }
}

}  // namespace

std::optional<std::wstring> WidgetSharedStorage::StateFilePath() {
  auto dir = AppDataDir();
  if (!dir) return std::nullopt;
  return *dir + L"\\" + kStateFile;
}

std::optional<std::wstring> WidgetSharedStorage::EnableFlagFilePath() {
  auto dir = AppDataDir();
  if (!dir) return std::nullopt;
  return *dir + L"\\" + kEnableFlagFile;
}

void WidgetSharedStorage::WriteState(const std::string& json) {
  auto path = StateFilePath();
  if (!path) return;
  WriteFileAtomicUtf8(*path, json);
}

std::string WidgetSharedStorage::ReadState() {
  auto path = StateFilePath();
  if (!path) return {};
  return ReadFileUtf8(*path);
}

bool WidgetSharedStorage::TrayEnabled() {
  auto path = EnableFlagFilePath();
  if (!path) return false;
  std::string body = ReadFileUtf8(*path);
  if (body.empty()) return false;
  // Trim whitespace.
  while (!body.empty() && std::isspace(static_cast<unsigned char>(body.back()))) body.pop_back();
  size_t start = 0;
  while (start < body.size() && std::isspace(static_cast<unsigned char>(body[start]))) ++start;
  body.erase(0, start);
  if (body.empty() || body == "false" || body == "0" || body == "{}") return false;
  return true;
}

}  // namespace plot::widget_bridge
