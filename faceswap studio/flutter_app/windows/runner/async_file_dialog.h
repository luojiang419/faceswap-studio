#ifndef RUNNER_ASYNC_FILE_DIALOG_H_
#define RUNNER_ASYNC_FILE_DIALOG_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Shell/COM 初始化和模态循环不得占用 Flutter 的窗口线程。
class AsyncFileDialog {
 public:
  AsyncFileDialog(flutter::BinaryMessenger* messenger, HWND owner);
  ~AsyncFileDialog();
  bool HandleMessage(UINT message);

 private:
  struct State;
  std::shared_ptr<State> state_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> pending_;
};

#endif
