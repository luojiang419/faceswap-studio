#include "async_file_dialog.h"

#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <wrl/client.h>

#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "utils.h"

namespace {
constexpr UINT kDialogComplete = WM_APP + 52;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

std::wstring Wide(const std::string& text) {
  const int length = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                       static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      result.data(), length);
  return result;
}

void Log(const char* stage, HRESULT status = S_OK) {
  wchar_t executable[MAX_PATH] = {};
  GetModuleFileNameW(nullptr, executable, MAX_PATH);
  auto parent = std::filesystem::path(executable).parent_path();
  for (int depth = 0; depth < 9 && !parent.empty(); ++depth) {
    const auto runtime = parent / L"faceswap studio" / L"runtime";
    if (std::filesystem::is_directory(runtime)) {
      SYSTEMTIME time;
      GetLocalTime(&time);
      std::ofstream log(runtime / L"file-dialog.log", std::ios::app);
      log << time.wYear << '-' << time.wMonth << '-' << time.wDay << ' '
          << time.wHour << ':' << time.wMinute << ':' << time.wSecond
          << " tid=" << GetCurrentThreadId() << ' ' << stage
          << " HRESULT=0x" << std::hex << static_cast<unsigned long>(status)
          << std::endl;
      return;
    }
    parent = parent.parent_path();
  }
}
}  // namespace

struct AsyncFileDialog::State {
  std::mutex mutex;
  HWND owner = nullptr;
  HRESULT status = S_OK;
  EncodableList paths;
};

AsyncFileDialog::AsyncFileDialog(flutter::BinaryMessenger* messenger, HWND owner)
    : state_(std::make_shared<State>()) {
  state_->owner = owner;
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "faceswap_studio/file_dialog",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() != "openFiles") {
          result->NotImplemented();
          return;
        }
        if (pending_) {
          result->Error("dialog_busy", "A file dialog is already open.");
          return;
        }
        const auto* args = std::get_if<EncodableMap>(call.arguments());
        if (!args) {
          result->Error("bad_args", "Expected file selection options.");
          return;
        }
        const auto multiple = args->find(EncodableValue("multiple"));
        const bool allow_multiple = multiple != args->end() &&
            std::holds_alternative<bool>(multiple->second) &&
            std::get<bool>(multiple->second);
        std::vector<std::wstring> labels, patterns;
        const auto filters = args->find(EncodableValue("filters"));
        if (filters != args->end() &&
            std::holds_alternative<EncodableList>(filters->second)) {
          for (const auto& item : std::get<EncodableList>(filters->second)) {
            const auto* filter = std::get_if<EncodableMap>(&item);
            if (!filter) continue;
            const auto label = filter->find(EncodableValue("label"));
            const auto extensions = filter->find(EncodableValue("extensions"));
            if (label == filter->end() || extensions == filter->end() ||
                !std::holds_alternative<std::string>(label->second) ||
                !std::holds_alternative<EncodableList>(extensions->second)) continue;
            std::wstring pattern;
            for (const auto& extension : std::get<EncodableList>(extensions->second)) {
              if (!std::holds_alternative<std::string>(extension)) continue;
              if (!pattern.empty()) pattern += L";";
              pattern += L"*." + Wide(std::get<std::string>(extension));
            }
            labels.push_back(Wide(std::get<std::string>(label->second)));
            patterns.push_back(pattern.empty() ? L"*.*" : pattern);
          }
        }
        pending_ = std::move(result);
        const auto state = state_;
        std::thread([state, allow_multiple, labels, patterns]() {
          // COM 对象只在此 STA 线程创建、使用和释放，不跨线程传递。
          Log("begin");
          HRESULT status = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED |
                                                      COINIT_DISABLE_OLE1DDE);
          const bool initialized = SUCCEEDED(status);
          EncodableList paths;
          const auto complete = [&]() {
            // Show 已结束、路径已复制，即可解除 Dart 侧的文件窗口占用。
            // Shell 扩展释放和 CoUninitialize 可能很慢，不让它们吞掉下一次选择。
            Log("result-ready", status);
            std::lock_guard<std::mutex> lock(state->mutex);
            state->status = status;
            state->paths = std::move(paths);
            if (state->owner) PostMessageW(state->owner, kDialogComplete, 0, 0);
          };
          if (initialized) {
            ComPtr<IFileOpenDialog> dialog;
            status = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
            Log("created", status);
            if (SUCCEEDED(status)) {
              FILEOPENDIALOGOPTIONS options = 0;
              status = dialog->GetOptions(&options);
              if (SUCCEEDED(status)) status = dialog->SetOptions(options |
                  FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST |
                  FOS_NOCHANGEDIR | (allow_multiple ? FOS_ALLOWMULTISELECT : 0));
              std::vector<COMDLG_FILTERSPEC> filters;
              for (size_t i = 0; i < labels.size(); ++i) {
                filters.push_back({labels[i].c_str(), patterns[i].c_str()});
              }
              if (SUCCEEDED(status) && !filters.empty()) {
                status = dialog->SetFileTypes(static_cast<UINT>(filters.size()), filters.data());
              }
              HWND owner;
              { std::lock_guard<std::mutex> lock(state->mutex); owner = state->owner; }
              if (!owner) status = HRESULT_FROM_WIN32(ERROR_CANCELLED);
              if (SUCCEEDED(status)) {
                Log("show");
                status = dialog->Show(owner);
                Log("closed", status);
              }
              if (SUCCEEDED(status)) {
                ComPtr<IShellItemArray> items;
                status = dialog->GetResults(&items);
                DWORD count = 0;
                if (SUCCEEDED(status)) status = items->GetCount(&count);
                for (DWORD i = 0; SUCCEEDED(status) && i < count; ++i) {
                  ComPtr<IShellItem> item;
                  status = items->GetItemAt(i, &item);
                  PWSTR path = nullptr;
                  if (SUCCEEDED(status)) status = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
                  if (SUCCEEDED(status)) paths.emplace_back(Utf8FromUtf16(path));
                  CoTaskMemFree(path);
                }
              }
            }
            complete();
          } else {
            complete();
          } // 在 CoUninitialize 之前释放所有 COM 对象；不再修改已回传结果。
          if (initialized) CoUninitialize();
          Log("complete", status);
        }).detach();
      });
}

AsyncFileDialog::~AsyncFileDialog() {
  channel_->SetMethodCallHandler(nullptr);
  std::lock_guard<std::mutex> lock(state_->mutex);
  state_->owner = nullptr;
}

bool AsyncFileDialog::HandleMessage(UINT message) {
  if (message != kDialogComplete) return false;
  if (!pending_) return true;
  std::lock_guard<std::mutex> lock(state_->mutex);
  auto result = std::move(pending_);
  if (SUCCEEDED(state_->status) ||
      state_->status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    result->Success(EncodableValue(state_->paths));
  } else {
    result->Error("file_dialog_failed", "Could not open the Windows file dialog.",
                  EncodableValue(static_cast<int32_t>(state_->status)));
  }
  return true;
}
