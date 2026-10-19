# Windows 中文品牌名与原生构建编码

## 表现与原因

改名为“易容 Studio”时，Windows/Web 与原生安装器均可编译，但原生窗口标题可能变成乱码。当前 MSVC 工程没有统一启用 `/utf-8`，UTF-8 源码中的宽字符串仍可能按系统代码页解释。`Runner.rc` 已有 `#pragma code_page(65001)`，因此资源里的产品名正常，不能用产品信息验证代替真实窗口标题验证。

另一个独立问题是 Windows PowerShell 5.1 默认按系统代码页读取没有 BOM 的脚本：中文输出路径会生成乱码文件名。下载请求头同样不能直接使用中文品牌名，原生 `HttpWebRequest.UserAgent` 会拒绝字符。

## 处理与验证

- C++ 窗口标题、托盘提示和窗口查找常量使用 `L"\u6613\u5BB9 Studio"`，不依赖编译机器代码页；资源文件继续使用原有 UTF-8 code page 声明。
- 含中文路径且可能由 `powershell.exe` 执行的 `.ps1` 使用 UTF-8 BOM；用 Windows PowerShell 5.1 实际编译检查输出文件名。
- HTTP 请求头使用 ASCII `Yirong-Studio`，用户可见名称仍为“易容 Studio”。
- 安装集成验收直接比较新安装桌面进程的真实 `MainWindowTitle`，同时检查快捷方式和系统卸载 `DisplayName`。发行包里的实际应用文件另做逐项 SHA-256 核对。

本次证据位于 `build/yirong-brand/`；首次窗口标题验收准确检出乱码，保留 `codepage-first-install-final.log`。修正后的最终结果位于该次发行目录的 `verification.json`。
