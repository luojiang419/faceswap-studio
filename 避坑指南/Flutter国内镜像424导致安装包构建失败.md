# Flutter 国内镜像 424 导致安装包构建失败

## 问题表现

执行 `scripts/build_installer.ps1` 时，Flutter `pub get` 在依赖解析阶段失败：

```text
424 Failed Dependency trying to find package synchronized at https://pub.flutter-io.cn.
flutter pub get failed.
```

## 触发条件

- `scripts/common.ps1` 的 `Use-FlutterMirrors` 无条件设置 `PUB_HOSTED_URL=https://pub.flutter-io.cn`。
- 国内 Pub 镜像临时不可用，但官方 `https://pub.dev` 可访问。
- 即使调用构建脚本前设置官方源，也会被函数覆盖。

## 根本原因

镜像配置没有为调用方显式设置的环境变量保留覆盖入口，网络故障时无法切换到其他可用源。

## 无效尝试

- 原样重复执行构建；镜像仍会返回相同错误。
- 只在父 PowerShell 设置 `PUB_HOSTED_URL`；旧函数会立即覆盖该值。

## 正确解决方案

让 `Use-FlutterMirrors` 仅在 `PUB_HOSTED_URL` 或 `FLUTTER_STORAGE_BASE_URL` 未设置时填充国内默认镜像。镜像故障时，在当前构建进程中显式设置：

```powershell
$env:PUB_HOSTED_URL = "https://pub.dev"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.googleapis.com"
./scripts/build_installer.ps1
```

不需要修改用户级或系统级永久环境变量。

## 验证方法

- 分别探测国内镜像与官方源的 HTTP 响应。
- 使用官方源执行 `flutter pub get`。
- 重新执行完整安装包构建，并确认 Flutter Web/Windows 和 Inno Setup 全部完成。

## 如何避免

- 默认镜像函数必须允许调用方通过已设置环境变量覆盖。
- 网络失败后先诊断具体源，不机械重复完整构建。
- 仅在直连不可用时再使用项目约定代理 `127.0.0.1:7890`。

## 影响模块

- `scripts/common.ps1`
- `scripts/build_flutter_app.ps1`
- `scripts/build_installer.ps1`
