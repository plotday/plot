#include "system_tray/tray_icon.h"

#include <shellapi.h>
#include <strsafe.h>

#include "resource.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <string>

namespace plot::system_tray {

namespace {

constexpr UINT kCallbackId = 0xA011;

// Menu command IDs. Must not collide with any other WM_COMMAND
// identifiers the runner emits. The 0x71xx range is reserved here.
constexpr WORD IDM_TRAY_START = 0x7101;
constexpr WORD IDM_TRAY_PAUSE = 0x7102;
constexpr WORD IDM_TRAY_STOP = 0x7103;
constexpr WORD IDM_TRAY_ADD = 0x7104;
constexpr WORD IDM_TRAY_REMOVE = 0x7105;
constexpr WORD IDM_TRAY_QUIT = 0x71FF;

// Ceil-to-minutes, formatted as `Nm` / `Hh` / `Hh Mm`. Mirrors
// `_PillLabel._formatMinutes` in `lib/widget/unified_header.dart` so
// the tray tooltip reads identically to the in-app pill.
std::wstring FormatRemaining(long long seconds_remaining) {
  if (seconds_remaining <= 0) return L"0m";
  long long total_minutes = (seconds_remaining + 59) / 60;
  long long h = total_minutes / 60;
  long long m = total_minutes % 60;
  wchar_t buf[32];
  if (h == 0) {
    StringCchPrintfW(buf, 32, L"%lldm", m);
  } else if (m == 0) {
    StringCchPrintfW(buf, 32, L"%lldh", h);
  } else {
    StringCchPrintfW(buf, 32, L"%lldh %lldm", h, m);
  }
  return std::wstring(buf);
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return {};
  int len = MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                 static_cast<int>(s.size()), nullptr, 0);
  if (len <= 0) return {};
  std::wstring out(static_cast<size_t>(len), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                      out.data(), len);
  return out;
}

// Returns the value of "key" as a UTF-8 string. Looks for `"key": "..."`
// honouring backslash-escaped quotes. Returns empty when missing or
// when the value is `null`.
std::string ExtractString(const std::string& json, const std::string& key) {
  std::string needle = "\"" + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos) return {};
  pos = json.find(':', pos);
  if (pos == std::string::npos) return {};
  ++pos;
  while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) ++pos;
  if (pos >= json.size()) return {};
  if (json.compare(pos, 4, "null") == 0) return {};
  if (json[pos] != '"') return {};
  ++pos;
  std::string out;
  while (pos < json.size() && json[pos] != '"') {
    if (json[pos] == '\\' && pos + 1 < json.size()) {
      char c = json[pos + 1];
      switch (c) {
        case 'n': out.push_back('\n'); break;
        case 't': out.push_back('\t'); break;
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case '/': out.push_back('/'); break;
        default: out.push_back(c); break;
      }
      pos += 2;
    } else {
      out.push_back(json[pos]);
      ++pos;
    }
  }
  return out;
}

bool ExtractBool(const std::string& json, const std::string& key) {
  std::string needle = "\"" + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos) return false;
  pos = json.find(':', pos);
  if (pos == std::string::npos) return false;
  ++pos;
  while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) ++pos;
  return json.compare(pos, 4, "true") == 0;
}

// Parses an ISO-8601 timestamp (with optional fractional seconds and a
// trailing `Z` or `+00:00`-style offset) into a Unix epoch in
// milliseconds. Returns 0 on parse failure.
long long ParseIsoToUnixMs(const std::string& iso) {
  if (iso.empty()) return 0;
  int year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0;
  int frac = 0;
  int frac_digits = 0;
  size_t i = 0;
  auto read_int = [&](int& out, int width) {
    int v = 0;
    int n = 0;
    while (i < iso.size() && n < width && std::isdigit(static_cast<unsigned char>(iso[i]))) {
      v = v * 10 + (iso[i] - '0');
      ++i; ++n;
    }
    out = v;
    return n;
  };
  if (read_int(year, 4) != 4) return 0;
  if (i >= iso.size() || iso[i] != '-') return 0; ++i;
  if (read_int(month, 2) != 2) return 0;
  if (i >= iso.size() || iso[i] != '-') return 0; ++i;
  if (read_int(day, 2) != 2) return 0;
  if (i >= iso.size() || (iso[i] != 'T' && iso[i] != ' ')) return 0; ++i;
  if (read_int(hour, 2) != 2) return 0;
  if (i >= iso.size() || iso[i] != ':') return 0; ++i;
  if (read_int(minute, 2) != 2) return 0;
  if (i >= iso.size() || iso[i] != ':') return 0; ++i;
  if (read_int(second, 2) != 2) return 0;
  if (i < iso.size() && iso[i] == '.') {
    ++i;
    while (i < iso.size() && std::isdigit(static_cast<unsigned char>(iso[i])) && frac_digits < 3) {
      frac = frac * 10 + (iso[i] - '0');
      ++i;
      ++frac_digits;
    }
    while (i < iso.size() && std::isdigit(static_cast<unsigned char>(iso[i]))) ++i;
    while (frac_digits < 3) { frac *= 10; ++frac_digits; }
  }
  int tz_minutes = 0;
  if (i < iso.size()) {
    if (iso[i] == 'Z') {
      // UTC, nothing to do.
    } else if (iso[i] == '+' || iso[i] == '-') {
      int sign = (iso[i] == '+') ? 1 : -1;
      ++i;
      int oh = 0, om = 0;
      if (read_int(oh, 2) != 2) return 0;
      if (i < iso.size() && iso[i] == ':') ++i;
      if (read_int(om, 2) != 2) return 0;
      tz_minutes = sign * (oh * 60 + om);
    }
  }

  std::tm tm{};
  tm.tm_year = year - 1900;
  tm.tm_mon = month - 1;
  tm.tm_mday = day;
  tm.tm_hour = hour;
  tm.tm_min = minute;
  tm.tm_sec = second;
  tm.tm_isdst = 0;
#if defined(_WIN32)
  long long secs = static_cast<long long>(_mkgmtime(&tm));
#else
  long long secs = static_cast<long long>(timegm(&tm));
#endif
  if (secs < 0) return 0;
  secs -= tz_minutes * 60;
  return secs * 1000LL + frac;
}

long long UnixNowMs() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(
             system_clock::now().time_since_epoch())
      .count();
}

}  // namespace

TrayIcon::TrayIcon(HWND host_window) : host_window_(host_window) {
  data_.cbSize = sizeof(NOTIFYICONDATAW);
  data_.hWnd = host_window_;
  data_.uID = kCallbackId;
  data_.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
  data_.uCallbackMessage = kTrayCallbackMessage;
  StringCchCopyW(data_.szTip, ARRAYSIZE(data_.szTip), L"Plot");
  EnsureIcon();
}

TrayIcon::~TrayIcon() {
  StopTickTimer();
  TearDownIcon();
}

void TrayIcon::ApplyState(const std::string& json) {
  current_state_ = ParseSnapshot(json);
  UpdateTooltip();
  if (current_state_.timer_state == L"running") {
    StartTickTimer();
  } else {
    StopTickTimer();
  }
}

void TrayIcon::Refresh() {
  UpdateTooltip();
  if (current_state_.timer_state == L"running") {
    StartTickTimer();
  } else {
    StopTickTimer();
  }
}

void TrayIcon::SetActionDispatcher(ActionDispatcher dispatcher) {
  action_dispatcher_ = std::move(dispatcher);
}

void TrayIcon::HandleTrayMessage(WPARAM /*wparam*/, LPARAM lparam) {
  UINT event = LOWORD(lparam);
  if (event == WM_LBUTTONUP || event == WM_RBUTTONUP) {
    ShowContextMenu();
  }
}

void TrayIcon::HandleCommand(WORD command_id) {
  std::string action;
  switch (command_id) {
    case IDM_TRAY_START:  action = "startTimer"; break;
    case IDM_TRAY_PAUSE:  action = "pauseTimer"; break;
    case IDM_TRAY_STOP:   action = "stopTimer"; break;
    case IDM_TRAY_ADD:    action = "addTime"; break;
    case IDM_TRAY_REMOVE: action = "removeTime"; break;
    case IDM_TRAY_QUIT:
      PostMessageW(host_window_, WM_CLOSE, 0, 0);
      return;
    default:
      return;
  }
  if (action_dispatcher_) action_dispatcher_(action);
}

void TrayIcon::HandleTimer(UINT_PTR timer_id) {
  if (timer_id != kTrayTickTimerId) return;
  UpdateTooltip();
}

void TrayIcon::EnsureIcon() {
  if (icon_added_) return;
  HINSTANCE instance = GetModuleHandleW(nullptr);
  // Use LoadImage to pick the small (16x16) frame from the multi-size
  // .ico — LoadIcon always returns the system metric size (typically
  // 32x32) which Shell_NotifyIcon then has to downscale, producing a
  // blurry tray icon.
  int cx = GetSystemMetrics(SM_CXSMICON);
  int cy = GetSystemMetrics(SM_CYSMICON);
  data_.hIcon = static_cast<HICON>(LoadImageW(
      instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, cx, cy,
      LR_DEFAULTCOLOR));
  if (!data_.hIcon) {
    data_.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
  }
  if (!data_.hIcon) {
    data_.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
  }
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

void TrayIcon::StartTickTimer() {
  if (tick_active_) return;
  SetTimer(host_window_, kTrayTickTimerId, 1000, nullptr);
  tick_active_ = true;
}

void TrayIcon::StopTickTimer() {
  if (!tick_active_) return;
  KillTimer(host_window_, kTrayTickTimerId);
  tick_active_ = false;
}

void TrayIcon::UpdateTooltip() {
  if (!icon_added_) return;
  std::wstring tip;
  if (!current_state_.is_signed_in) {
    tip = L"Plot";
  } else if (current_state_.timer_state == L"running" &&
             current_state_.timer_ends_at_unix_ms > 0) {
    long long remaining_ms =
        current_state_.timer_ends_at_unix_ms - UnixNowMs();
    std::wstring remaining = FormatRemaining(remaining_ms / 1000);
    if (!current_state_.priority_title.empty()) {
      tip = current_state_.priority_title + L" · " + remaining;
    } else {
      tip = L"Plot · " + remaining;
    }
  } else {
    tip = current_state_.priority_title.empty()
              ? L"Plot"
              : current_state_.priority_title;
  }
  // szTip is 128 wchar_t — truncate gracefully.
  StringCchCopyW(data_.szTip, ARRAYSIZE(data_.szTip), tip.c_str());
  Shell_NotifyIconW(NIM_MODIFY, &data_);
}

void TrayIcon::ShowContextMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;

  if (!current_state_.is_signed_in) {
    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, L"Plot");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, IDM_TRAY_QUIT, L"Quit Plot");
  } else {
    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0,
                current_state_.priority_title.empty()
                    ? L"Plot"
                    : current_state_.priority_title.c_str());
    if (!current_state_.event_title.empty()) {
      AppendMenuW(menu, MF_STRING | MF_GRAYED, 0,
                  current_state_.event_title.c_str());
    }
    std::wstring timer_label;
    if (current_state_.timer_state == L"running" &&
        current_state_.timer_ends_at_unix_ms > 0) {
      long long remaining_ms =
          current_state_.timer_ends_at_unix_ms - UnixNowMs();
      std::wstring prefix =
          current_state_.timer_source == L"event" ? L"Event" : L"Running";
      timer_label = prefix + L" · " + FormatRemaining(remaining_ms / 1000);
    } else {
      timer_label = L"No timer";
    }
    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, timer_label.c_str());
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);

    AppendMenuW(menu, MF_STRING | (current_state_.can_start ? 0 : MF_GRAYED),
                IDM_TRAY_START, L"Start");
    AppendMenuW(menu, MF_STRING | (current_state_.can_pause ? 0 : MF_GRAYED),
                IDM_TRAY_PAUSE, L"Pause");
    AppendMenuW(menu, MF_STRING | (current_state_.can_stop ? 0 : MF_GRAYED),
                IDM_TRAY_STOP, L"Stop");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING | (current_state_.can_add_time ? 0 : MF_GRAYED),
                IDM_TRAY_ADD, L"Add 15 minutes");
    AppendMenuW(menu,
                MF_STRING | (current_state_.can_remove_time ? 0 : MF_GRAYED),
                IDM_TRAY_REMOVE, L"Remove 15 minutes");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, IDM_TRAY_QUIT, L"Quit Plot");
  }

  POINT cursor;
  GetCursorPos(&cursor);
  // Required so the popup is dismissed if the user clicks elsewhere
  // (Microsoft KB Q135788).
  SetForegroundWindow(host_window_);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
                 cursor.x, cursor.y, 0, host_window_, nullptr);
  PostMessageW(host_window_, WM_NULL, 0, 0);
  DestroyMenu(menu);
}

TrayIcon::Snapshot TrayIcon::ParseSnapshot(const std::string& json) {
  Snapshot s;
  if (json.empty()) return s;
  s.is_signed_in = ExtractBool(json, "isSignedIn");
  s.priority_title = Utf8ToWide(ExtractString(json, "currentPriorityTitle"));
  s.event_title = Utf8ToWide(ExtractString(json, "currentEventTitle"));
  std::string ts = ExtractString(json, "timerState");
  if (!ts.empty()) s.timer_state = Utf8ToWide(ts);
  s.timer_source = Utf8ToWide(ExtractString(json, "timerSource"));
  s.timer_ends_at_unix_ms =
      ParseIsoToUnixMs(ExtractString(json, "timerEndsAtIso"));
  s.can_start = ExtractBool(json, "canStart");
  s.can_pause = ExtractBool(json, "canPause");
  s.can_stop = ExtractBool(json, "canStop");
  s.can_add_time = ExtractBool(json, "canAddTime");
  s.can_remove_time = ExtractBool(json, "canRemoveTime");
  return s;
}

}  // namespace plot::system_tray
