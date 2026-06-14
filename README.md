# FaceSwap Studio

FaceSwap Studio 是基于 FaceFusion 推理引擎、Flutter 桌面前端和 Python Bridge 适配层构建的一体化桌面换脸工作台。它把原本分散的运行、参数调整、队列执行、作品管理和设置入口收拢到一个 Windows 桌面应用里，尽量降低实际使用门槛。

## 核心特点

- 桌面一体化：使用 Flutter 构建正式桌面壳层，统一承载首页、工作台、作品管理、设置和关于页面。
- 启停可视化：首页集中展示 Bridge 状态、FaceFusion 状态、系统资源和运行日志。
- 原生工作台：支持直接使用 Windows 原生文件选择器准备 `SOURCE` / `TARGET`，减少频繁切浏览器的成本。
- 生成队列：支持把多个任务加入队列，按顺序执行并追踪进度。
- 作品管理：统一浏览输出结果、收藏、删除、下载和预览图片 / 视频。
- 设置持久化：主题和默认输出目录由本地 Bridge 持久化保存。
- 启动链路收敛：仓库内已提供启动器、Bridge、Flutter 应用和部署脚本，便于直接运行或继续开发。

## 安装方式

### 方式一：使用 Windows 安装包

适合最终用户安装成普通桌面软件。

1. 运行 `dist/installer/FaceSwapStudioSetup.exe`。
2. 安装器会优先选择 `D:\Program Files\FaceSwap Studio`。
3. 如果 D 盘空间不足，会自动选择其他可用磁盘下的 `Program Files\FaceSwap Studio`。
4. 安装完成后，桌面会出现 `FaceSwap Studio` 快捷方式。
5. 首次启动时，如果核心模型缺失，软件会弹窗下载核心小包，并显示进度、速度和当前文件。
6. 下载完成后会自动启动 FaceFusion。
7. 启动后会检查公开 GitHub Release 更新；有增量包时会弹窗确认下载和安装。

开发者可以使用下面命令生成安装包：

```powershell
./scripts/build_installer.ps1
```

说明：

- 安装包内置 Python 运行时、项目虚拟环境、Bridge、Flutter 桌面运行包和 FFmpeg。
- 模型不会预置到安装包中，首次运行只下载核心小包，避免安装包体积过大。
- 软件版本以仓库根目录 `VERSION` 为准，安装器和更新 manifest 都会读取它。
- 如果 Windows 弹出 SmartScreen 或未知发布者提示，需要手动选择继续运行。

生成 GitHub Release 更新产物：

```powershell
./scripts/build_update_package.ps1 -FromManifest .\dist\updates\<old-version>\files-<old-version>.json -FromVersion <old-version>
./scripts/publish_release.ps1 -Repository <owner>/<repo>
```

说明：

- `build_update_package.ps1` 会生成 `update-manifest.json`、当前文件 manifest 和文件级 delta zip。
- `publish_release.ps1` 通过 GitHub CLI 上传全量安装器、delta zip、文件 manifest 和更新 manifest。
- 客户端默认读取公开 Release，不内置 GitHub token；delta 不可用时会提示下载全量安装器。

### 方式二：直接运行仓库内桌面启动器

适合只想尽快启动软件的用户。

1. 克隆或下载当前仓库。
2. 进入仓库根目录。
3. 双击运行 `启动FaceSwap Studio.exe`。
4. 启动器会拉起 Flutter 桌面应用和本地 Bridge。
5. 首次运行后，首页可以看到运行状态、工作台和日志。

说明：

- 如果 Windows 弹出 SmartScreen 或未知发布者提示，需要手动选择继续运行。
- 如果模型尚未下载完整，首次执行相关功能时会比后续启动慢。

### 方式三：使用 Windows 原生脚本部署

适合需要自行安装依赖、使用 CUDA 加速或继续维护环境的用户。

在仓库根目录执行：

```powershell
./scripts/install_facefusion.ps1 -Backend cuda
./scripts/prefetch_models.ps1
./scripts/run_facefusion.ps1
```

这套流程会完成：

- 自举项目内 Python
- 创建 `.venv-win`
- 安装 FaceFusion 所需依赖
- 准备项目内 `ffmpeg`
- 预拉取常用模型
- 启动 FaceFusion 图形界面

如果只需要启动桌面工作台：

```powershell
python .\launch_faceswap_studio.py
```

或者直接运行：

```powershell
./启动FaceSwap Studio.exe
```

### 方式四：开发者本地调试

适合需要修改 Flutter、Bridge 或 FaceFusion 代码的开发者。

```powershell
./scripts/install_facefusion.ps1 -Backend cuda
python .\launch_faceswap_studio.py
```

Flutter 应用源码位于：

- `faceswap studio/flutter_app/`

Bridge 服务源码位于：

- `faceswap studio/bridge/`

## 系统要求

推荐环境：

- Windows 10 / Windows 11
- PowerShell 7 或较新的 Windows PowerShell
- NVIDIA 显卡与可用驱动（如果需要 CUDA 推理）
- 足够的磁盘空间用于模型、缓存和输出文件

如果需要 GPU 加速，请确保：

- `nvidia-smi` 可正常执行
- 显卡驱动已正确安装
- CUDA 相关运行时可被当前机器加载

## 常用入口

- `启动FaceSwap Studio.exe`
  适合最终用户，直接启动桌面软件。
- `launch_faceswap_studio.py`
  启动桌面工作台链路。
- `scripts/install_facefusion.ps1`
  初始化 Windows 原生依赖。
- `scripts/prefetch_models.ps1`
  预下载模型。
- `scripts/run_facefusion.ps1`
  启动 FaceFusion 图形界面。
- `scripts/build_installer.ps1`
  构建 Windows 安装器。
- `scripts/build_update_package.ps1`
  构建 Release 更新 manifest 和文件级 delta 包。
- `scripts/publish_release.ps1`
  通过 GitHub CLI 发布或上传 Release 资产。
- `FaceSwapStudioUpdater.exe`
  独立提权更新程序，由 Bridge 在用户确认更新后启动。

## 目录说明

- `facefusion/`
  FaceFusion 核心源码。
- `faceswap studio/bridge/`
  Python Bridge 服务。
- `faceswap studio/flutter_app/`
  Flutter 桌面前端。
- `faceswap studio/runtime/`
  运行期产物与当前部署包。
- `docs/`
  项目文档与安装说明。

## 详细安装文档

更完整的安装、依赖、常见问题和调试方式，请看：

- [详细安装文档](docs/INSTALLATION.md)

## 使用提示

- 如果 `7860` 页面正在运行旧进程，修改 WebUI 顶部结构后需要重启一次 FaceFusion 才会生效。
- 默认输出目录可在“设置”页修改。
- 工作台支持本地文件选择、队列提交和浏览器高级参数联动。

## 免责声明

本项目仅限合法、合规和经授权场景使用。请勿用于侵犯他人肖像权、隐私权、著作权或任何违法用途，相关法律责任由使用者自行承担。
