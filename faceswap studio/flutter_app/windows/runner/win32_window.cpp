#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <shellapi.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";
constexpr UINT kTrayIconMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayMenuShowWindow = 1001;
constexpr UINT kTrayMenuExitApplication = 1002;
constexpr wchar_t kTrayIconTooltip[] = L"\u6613\u5BB9 Studio";
constexpr wchar_t kWindowTitle[] = L"\u6613\u5BB9 Studio";
constexpr wchar_t kActivateWindowMessageName[] =
    L"FaceSwapStudio.ActivateWindow";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

UINT GetActivateWindowMessage() {
  static const UINT message = RegisterWindowMessage(kActivateWindowMessageName);
  return message;
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

void Win32Window::SetMinSize(const Size& size) {
  minimum_size_ = size;
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    default:
      if (message == GetActivateWindowMessage()) {
        RestoreFromTray();
        return 0;
      }
      break;
    case WM_CLOSE:
      if (!force_quit_ && OnCloseRequested()) {
        return 0;
      }
      if (close_to_tray_ && !force_quit_) {
        if (HideToTray()) {
          return 0;
        }
      }
      break;
    case WM_GETMINMAXINFO: {
      if (minimum_size_) {
        auto minmax_info = reinterpret_cast<MINMAXINFO*>(lparam);
        HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
        double scale_factor = dpi / 96.0;
        minmax_info->ptMinTrackSize.x =
            Scale(minimum_size_->width, scale_factor);
        minmax_info->ptMinTrackSize.y =
            Scale(minimum_size_->height, scale_factor);
        return 0;
      }
      break;
    }
    case WM_DESTROY:
      DestroyTrayIcon();
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;
    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case kTrayMenuShowWindow:
          RestoreFromTray();
          return 0;
        case kTrayMenuExitApplication:
          ExitFromTray();
          return 0;
      }
      break;
    case kTrayIconMessage:
      return HandleTrayMessage(wparam, lparam);

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

bool Win32Window::OnCloseRequested() {
  return false;
}

bool Win32Window::HideToTray() {
  if (!window_handle_) {
    return false;
  }
  if (!tray_icon_visible_) {
    NOTIFYICONDATA notify_icon_data{};
    notify_icon_data.cbSize = sizeof(NOTIFYICONDATA);
    notify_icon_data.hWnd = window_handle_;
    notify_icon_data.uID = kTrayIconId;
    notify_icon_data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    notify_icon_data.uCallbackMessage = kTrayIconMessage;
    notify_icon_data.hIcon =
        LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
    wcscpy_s(notify_icon_data.szTip, kTrayIconTooltip);
    if (!Shell_NotifyIcon(NIM_ADD, &notify_icon_data)) {
      return false;
    }
    tray_icon_visible_ = true;
  }
  ShowWindow(window_handle_, SW_HIDE);
  return true;
}

bool Win32Window::RestoreFromTray() {
  if (!window_handle_) {
    return false;
  }
  DestroyTrayIcon();
  ShowWindow(window_handle_, SW_RESTORE);
  ShowWindow(window_handle_, SW_SHOW);
  BringWindowToTop(window_handle_);
  SetForegroundWindow(window_handle_);
  return true;
}

void Win32Window::ExitFromTray() {
  force_quit_ = true;
  close_to_tray_ = false;
  DestroyTrayIcon();
  if (window_handle_) {
    PostMessage(window_handle_, WM_CLOSE, 0, 0);
  }
}

void Win32Window::DestroyTrayIcon() {
  if (!tray_icon_visible_ || !window_handle_) {
    tray_icon_visible_ = false;
    return;
  }
  NOTIFYICONDATA notify_icon_data{};
  notify_icon_data.cbSize = sizeof(NOTIFYICONDATA);
  notify_icon_data.hWnd = window_handle_;
  notify_icon_data.uID = kTrayIconId;
  Shell_NotifyIcon(NIM_DELETE, &notify_icon_data);
  tray_icon_visible_ = false;
}

void Win32Window::ShowTrayMenu() {
  if (!window_handle_) {
    return;
  }
  HMENU menu = CreatePopupMenu();
  if (!menu) {
    return;
  }
  AppendMenu(menu, MF_STRING, kTrayMenuShowWindow, L"\u663E\u793A\u4E3B\u7A97\u53E3");
  AppendMenu(menu, MF_STRING, kTrayMenuExitApplication, L"\u9000\u51FA\u7A0B\u5E8F");
  POINT cursor_point{};
  GetCursorPos(&cursor_point);
  SetForegroundWindow(window_handle_);
  TrackPopupMenu(
      menu,
      TPM_BOTTOMALIGN | TPM_LEFTALIGN | TPM_RIGHTBUTTON,
      cursor_point.x,
      cursor_point.y,
      0,
      window_handle_,
      nullptr);
  DestroyMenu(menu);
}

LRESULT Win32Window::HandleTrayMessage(WPARAM wparam,
                                       LPARAM lparam) noexcept {
  if (wparam != kTrayIconId) {
    return 0;
  }
  switch (lparam) {
    case WM_LBUTTONUP:
      RestoreFromTray();
      return 0;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      ShowTrayMenu();
      return 0;
  }
  return 0;
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

void Win32Window::SetCloseToTray(bool close_to_tray) {
  close_to_tray_ = close_to_tray;
}

void Win32Window::SetForceQuit(bool force_quit) {
  force_quit_ = force_quit;
}

bool Win32Window::NotifyRunningInstance() {
  const UINT activate_window_message = GetActivateWindowMessage();
  const ULONGLONG deadline = GetTickCount64() + 5000;

  while (GetTickCount64() < deadline) {
    HWND existing_window = FindWindow(kWindowClassName, kWindowTitle);
    if (existing_window) {
      DWORD_PTR result = 0;
      return SendMessageTimeout(existing_window, activate_window_message, 0, 0,
                                SMTO_ABORTIFHUNG, 1000, &result) != 0;
    }
    Sleep(100);
  }
  return false;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
