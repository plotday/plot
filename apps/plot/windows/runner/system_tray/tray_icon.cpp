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

// Reads HKCU\...\Personalize\SystemUsesLightTheme. Defaults to dark
// (the Windows 10/11 default) when the key is missing so the text icon
// stays legible on the dark default taskbar.
bool IsLightTaskbarTheme() {
  DWORD value = 0;
  DWORD size = sizeof(value);
  HKEY key = nullptr;
  LONG status = RegOpenKeyExW(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      0, KEY_READ, &key);
  if (status != ERROR_SUCCESS) return false;
  DWORD type = 0;
  status = RegQueryValueExW(key, L"SystemUsesLightTheme", nullptr, &type,
                            reinterpret_cast<LPBYTE>(&value), &size);
  RegCloseKey(key);
  if (status != ERROR_SUCCESS || type != REG_DWORD) return false;
  return value != 0;
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
  UpdateTrayIcon();
  if (NeedsTicking()) {
    StartTickTimer();
  } else {
    StopTickTimer();
  }
}

void TrayIcon::Refresh() {
  UpdateTooltip();
  UpdateTrayIcon();
  if (NeedsTicking()) {
    StartTickTimer();
  } else {
    StopTickTimer();
  }
}

bool TrayIcon::NeedsTicking() const {
  if (current_state_.timer_state == L"running") return true;
  if (current_state_.next_event_start_unix_ms <= 0) return false;
  long long secs_until =
      (current_state_.next_event_start_unix_ms - UnixNowMs()) / 1000;
  // 10-minute banner window + 1-minute pad so the tick starts just
  // before the banner is supposed to appear, without waiting for the
  // next `ApplyState` push.
  return secs_until > 0 && secs_until <= 11 * 60;
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
  UpdateTrayIcon();
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
  logo_icon_ = static_cast<HICON>(LoadImageW(
      instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, cx, cy,
      LR_DEFAULTCOLOR));
  if (!logo_icon_) {
    logo_icon_ = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
  }
  if (!logo_icon_) {
    logo_icon_ = LoadIconW(nullptr, IDI_APPLICATION);
  }
  data_.hIcon = logo_icon_;
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
  data_.hIcon = nullptr;
  if (countdown_icon_) {
    DestroyIcon(countdown_icon_);
    countdown_icon_ = nullptr;
  }
  if (logo_icon_) {
    DestroyIcon(logo_icon_);
    logo_icon_ = nullptr;
  }
  displayed_text_.clear();
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

void TrayIcon::UpdateTrayIcon() {
  if (!icon_added_) return;

  std::wstring desired_text;
  if (current_state_.is_signed_in) {
    // Approaching-event banner wins over the running-timer countdown:
    // a scheduled event ≤ 10 minutes away is the more time-sensitive
    // thing for the user to notice, so the tray icon shows its
    // countdown.
    if (current_state_.next_event_start_unix_ms > 0 &&
        !current_state_.next_event_title.empty()) {
      long long secs_until =
          (current_state_.next_event_start_unix_ms - UnixNowMs()) / 1000;
      if (secs_until > 0 && secs_until <= 10 * 60) {
        desired_text = FormatRemaining(secs_until);
      }
    }
    if (desired_text.empty() &&
        current_state_.timer_state == L"running" &&
        current_state_.timer_ends_at_unix_ms > 0) {
      long long remaining_ms =
          current_state_.timer_ends_at_unix_ms - UnixNowMs();
      desired_text = FormatRemaining(remaining_ms / 1000);
    }
  }

  if (desired_text == displayed_text_ && data_.hIcon) {
    // Ceil-to-minutes means the tick at 1Hz is a no-op most seconds —
    // we only re-render when the visible label actually changes.
    return;
  }

  HICON next_icon = nullptr;
  if (desired_text.empty()) {
    next_icon = logo_icon_;
  } else {
    HICON fresh = CreateCountdownIcon(desired_text);
    if (!fresh) {
      // Rendering failed; fall back to the logo so the tray still has
      // something visible.
      next_icon = logo_icon_;
      desired_text.clear();
    } else {
      if (countdown_icon_) DestroyIcon(countdown_icon_);
      countdown_icon_ = fresh;
      next_icon = countdown_icon_;
    }
  }

  if (!next_icon) return;
  data_.hIcon = next_icon;
  data_.uFlags |= NIF_ICON;
  Shell_NotifyIconW(NIM_MODIFY, &data_);
  displayed_text_ = desired_text;
}

HICON TrayIcon::CreateCountdownIcon(const std::wstring& text) {
  int size = GetSystemMetrics(SM_CXSMICON);
  if (size <= 0) size = 16;

  HDC screen_dc = GetDC(nullptr);
  if (!screen_dc) return nullptr;
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  if (!mem_dc) {
    ReleaseDC(nullptr, screen_dc);
    return nullptr;
  }

  // 32bpp top-down DIB so we can pull the bits back out, post-process
  // the GDI render (which doesn't set alpha) and feed
  // CreateIconIndirect a properly premultiplied bitmap.
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = size;
  bi.bmiHeader.biHeight = -size;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP color_bmp = CreateDIBSection(mem_dc, &bi, DIB_RGB_COLORS, &bits,
                                       nullptr, 0);
  if (!color_bmp || !bits) {
    if (color_bmp) DeleteObject(color_bmp);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    return nullptr;
  }
  std::memset(bits, 0, static_cast<size_t>(size) * size * 4);

  HGDIOBJ old_bmp = SelectObject(mem_dc, color_bmp);
  SetBkMode(mem_dc, TRANSPARENT);
  // Render the glyphs in pure white. Coverage is recovered from the
  // pixel value below and re-tinted to the theme-appropriate colour.
  SetTextColor(mem_dc, RGB(255, 255, 255));

  // Start near the icon height and shrink if the text overflows. The
  // common labels ("5m", "59m", "1h") fit at ~75% of the icon height;
  // the worst case ("1h59m") needs to shrink further.
  auto make_font = [](int height) -> HFONT {
    return CreateFontW(height, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
                       DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                       CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                       DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
  };
  int font_height = -static_cast<int>(size * 0.75);
  HFONT font = make_font(font_height);
  if (!font) font = static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
  HGDIOBJ old_font = SelectObject(mem_dc, font);

  auto measure_width = [&]() {
    RECT r = {0, 0, size, size};
    DrawTextW(mem_dc, text.c_str(), -1, &r,
              DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
    return r.right - r.left;
  };
  int text_w = measure_width();
  int attempts = 0;
  while (text_w > size && attempts < 5) {
    SelectObject(mem_dc, old_font);
    if (font && font != GetStockObject(DEFAULT_GUI_FONT)) DeleteObject(font);
    font_height = static_cast<int>(font_height * 0.82);
    if (font_height > -5) font_height = -5;
    font = make_font(font_height);
    if (!font) font = static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
    old_font = SelectObject(mem_dc, font);
    text_w = measure_width();
    ++attempts;
  }

  RECT rect = {0, 0, size, size};
  DrawTextW(mem_dc, text.c_str(), -1, &rect,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_NOCLIP);
  GdiFlush();

  COLORREF text_color = IsLightTaskbarTheme() ? RGB(0, 0, 0)
                                              : RGB(255, 255, 255);
  int target_r = GetRValue(text_color);
  int target_g = GetGValue(text_color);
  int target_b = GetBValue(text_color);

  std::uint32_t* pixels = static_cast<std::uint32_t*>(bits);
  for (int i = 0; i < size * size; ++i) {
    std::uint32_t px = pixels[i];
    // DIB layout is 0xAARRGGBB in memory little-endian; alpha is the
    // top byte. GDI left it at 0 — recover coverage from the max of the
    // RGB channels (ANTIALIASED_QUALITY emits grayscale, so R==G==B).
    int b = px & 0xFF;
    int g = (px >> 8) & 0xFF;
    int r = (px >> 16) & 0xFF;
    int coverage = std::max(r, std::max(g, b));
    if (coverage == 0) {
      pixels[i] = 0;
      continue;
    }
    int pr = (target_r * coverage) / 255;
    int pg = (target_g * coverage) / 255;
    int pb = (target_b * coverage) / 255;
    pixels[i] = (static_cast<std::uint32_t>(coverage) << 24) |
                (static_cast<std::uint32_t>(pr) << 16) |
                (static_cast<std::uint32_t>(pg) << 8) |
                static_cast<std::uint32_t>(pb);
  }

  SelectObject(mem_dc, old_font);
  if (font && font != GetStockObject(DEFAULT_GUI_FONT)) DeleteObject(font);
  SelectObject(mem_dc, old_bmp);

  // CreateIconIndirect requires a mask bitmap even when the colour
  // bitmap has a real alpha channel; a 1bpp all-zero mask makes Windows
  // honour the alpha in hbmColor.
  HBITMAP mask_bmp = CreateBitmap(size, size, 1, 1, nullptr);
  if (!mask_bmp) {
    DeleteObject(color_bmp);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    return nullptr;
  }

  ICONINFO ii = {};
  ii.fIcon = TRUE;
  ii.hbmColor = color_bmp;
  ii.hbmMask = mask_bmp;
  HICON icon = CreateIconIndirect(&ii);

  DeleteObject(color_bmp);
  DeleteObject(mask_bmp);
  DeleteDC(mem_dc);
  ReleaseDC(nullptr, screen_dc);
  return icon;
}

void TrayIcon::UpdateTooltip() {
  if (!icon_added_) return;
  std::wstring tip;
  if (!current_state_.is_signed_in) {
    tip = L"Plot";
  } else if (current_state_.next_event_start_unix_ms > 0 &&
             !current_state_.next_event_title.empty()) {
    long long secs_until =
        (current_state_.next_event_start_unix_ms - UnixNowMs()) / 1000;
    if (secs_until > 0 && secs_until <= 10 * 60) {
      tip = FormatRemaining(secs_until) + L" → " +
            current_state_.next_event_title;
    }
  }
  if (tip.empty()) {
    if (current_state_.timer_state == L"running" &&
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
  s.next_event_title = Utf8ToWide(ExtractString(json, "nextEventTitle"));
  s.next_event_start_unix_ms =
      ParseIsoToUnixMs(ExtractString(json, "nextEventStartIso"));
  s.can_start = ExtractBool(json, "canStart");
  s.can_pause = ExtractBool(json, "canPause");
  s.can_stop = ExtractBool(json, "canStop");
  s.can_add_time = ExtractBool(json, "canAddTime");
  s.can_remove_time = ExtractBool(json, "canRemoveTime");
  return s;
}

}  // namespace plot::system_tray
