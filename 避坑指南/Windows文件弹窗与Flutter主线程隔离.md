# Windows 文件弹窗与 Flutter 主线程隔离

## 表现及定位边界

点击上传人脸后，文件选择窗口还未出现，主窗口已经“未响应”。Windows Application 1002 为 Cross-thread，1001 为 AppHangB1；Bridge 仍正常轮询，没有收到人脸提取请求。

原 `file_selector_windows` 在平台线程同步执行 COM 文件窗口初始化和 `IFileDialog::Show()`。Shell 初始化、扩展加载或线程等待会使主窗口受阻。该次 WER 没有线程转储，不能仅凭事件报告断言具体 Shell 扩展是根因；普通原生弹窗回归未稳定复现原始持续挂起。

## 解决方法

- Windows 人脸、视频和人物库选图统一经 `pickStudioFiles()` 调用独立 STA 线程；COM 对象在同一工作线程创建、使用和释放。
- 结果由窗口消息投递回平台线程后回复 MethodChannel；工作线程不能直接访问 messenger。窗口销毁时解除共享状态的 owner 绑定，避免悬空回调。
- 前端与原生均限制同时一个弹窗；取消不修改素材，异常给出提示；页面销毁后丢弃延迟结果。
- 读取 `faceswap studio/runtime/file-dialog.log` 的 begin/created/show/closed/complete 判断停留阶段；`0x800704c7` 是正常取消。

## 已验证

- `flutter test --no-pub`：40 项通过。
- `flutter test -d windows integration_test/file_dialog_windows_test.dart --no-pub`：真实多选、单选、再次多选打开/取消通过，弹窗期间 Dart 心跳继续运行。
- `flutter test -d windows integration_test/close_behavior_windows_test.dart --no-pub`：关闭、取消、托盘恢复通过。
- `flutter analyze --no-pub` 及 Windows Release 构建通过。

测试只操作本测试 PID 的弹窗。旧弹窗可能晚于选择 Future 完成才销毁，监控器需要再次验证 PID 和可见性；跨 isolate 返回的推断 `Map<String, bool>` 不可直接写入 int，应先复制为 `Map<String, Object?>`。
