#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {
constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\FaceSwapStudio.SingleInstance";

std::filesystem::path ResolveSettingsPath() {
  wchar_t executable_path[MAX_PATH];
  if (::GetModuleFileName(nullptr, executable_path, MAX_PATH) == 0) {
    return std::filesystem::path();
  }

  auto current = std::filesystem::path(executable_path).parent_path();
  for (int depth = 0; depth < 8 && !current.empty(); ++depth) {
    const auto studio_root = current / "faceswap studio";
    const auto runtime_candidate = studio_root / "runtime" / "settings.json";
    if (std::filesystem::exists(runtime_candidate)) {
      return runtime_candidate;
    }

    const auto template_candidate = studio_root / "config" / "settings.json";
    if (std::filesystem::exists(template_candidate)) {
      return template_candidate;
    }
    current = current.parent_path();
  }
  return std::filesystem::path();
}

bool ShouldCloseToTray() {
  const auto settings_path = ResolveSettingsPath();
  if (settings_path.empty()) {
    return true;
  }

  std::ifstream settings_file(settings_path, std::ios::binary);
  if (!settings_file.is_open()) {
    return true;
  }

  const std::string content(
      (std::istreambuf_iterator<char>(settings_file)),
      std::istreambuf_iterator<char>());
  if (content.find("\"close_behavior\"") == std::string::npos) {
    return true;
  }
  if (content.find("\"close_behavior\": \"exit\"") != std::string::npos ||
      content.find("\"close_behavior\":\"exit\"") != std::string::npos) {
    return false;
  }
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  HANDLE single_instance_mutex =
      CreateMutexW(nullptr, TRUE, kSingleInstanceMutexName);
  if (single_instance_mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
    Win32Window::NotifyRunningInstance();
    CloseHandle(single_instance_mutex);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1400, 700);
  window.SetMinSize(Win32Window::Size(1400, 700));
  if (!window.Create(L"faceswap_studio", origin, size)) {
    if (single_instance_mutex) {
      CloseHandle(single_instance_mutex);
    }
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  window.SetCloseToTray(ShouldCloseToTray());

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (single_instance_mutex) {
    CloseHandle(single_instance_mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
