# FaceSwap Studio 详细安装文档

本文档面向希望在当前仓库基础上完成安装、部署、调试和二次开发的用户。

## 1. 仓库内容概览

当前仓库已经不只是原始 FaceFusion 源码，还包括完整的桌面工作台链路：

- `facefusion/`
  FaceFusion 核心代码
- `faceswap studio/bridge/`
  本地 Python Bridge
- `faceswap studio/flutter_app/`
  Flutter 桌面前端
- `launch_faceswap_studio.py`
  桌面工作台启动入口
- `启动FaceSwap Studio.exe`
  适合最终用户的桌面启动器

## 2. 推荐安装方式

### 2.1 最快方式：直接运行启动器

适合大多数 Windows 用户。

步骤：

1. 下载或克隆仓库到本地。
2. 进入仓库根目录。
3. 双击 `启动FaceSwap Studio.exe`。
4. 等待桌面界面出现。

你会得到：

- Flutter 桌面壳层
- 首页状态面板
- 工作台
- 作品管理
- 设置

适用场景：

- 想直接使用软件
- 不想手动敲安装命令
- 已具备可用运行环境

### 2.2 标准方式：使用 Windows 原生脚本安装

适合要重新部署环境、补依赖、启用 CUDA 或保证环境可复现的用户。

在仓库根目录执行：

```powershell
./scripts/install_facefusion.ps1 -Backend cuda
./scripts/prefetch_models.ps1
./scripts/run_facefusion.ps1
```

说明：

- `install_facefusion.ps1`
  会安装项目所需 Python 环境和关键依赖。
- `prefetch_models.ps1`
  会预先下载常用模型，减少首次使用等待时间。
- `run_facefusion.ps1`
  会启动 FaceFusion 图形界面。

如果你只想启动桌面工作台：

```powershell
python .\launch_faceswap_studio.py
```

## 3. 环境要求

建议配置：

- Windows 10 / 11
- 可联网环境
- 至少一个可写数据盘用于模型和输出文件
- NVIDIA GPU（如果需要 CUDA 推理）

如果要使用 GPU，请确认：

- `nvidia-smi` 正常可用
- 驱动已经安装
- 系统允许加载相关 CUDA 运行时

## 4. Windows 原生脚本做了什么

当前仓库里的 Windows 脚本会尽量把依赖收敛到项目目录中，避免污染系统环境。

关键点：

- 基础 Python 会安装到项目目录下的自举位置
- 虚拟环境使用 `.venv-win/`
- `ffmpeg` 运行文件放在项目内
- 启动脚本会尽量自动补全缺失依赖
- 如果缺少关键 Python 包、虚拟环境或 `ffmpeg`，入口脚本会尝试自动修复

## 5. 常用命令

### 安装依赖

```powershell
./scripts/install_facefusion.ps1 -Backend cuda
```

### 预下载模型

```powershell
./scripts/prefetch_models.ps1
```

### 启动 FaceFusion

```powershell
./scripts/run_facefusion.ps1
```

### 启动桌面工作台

```powershell
python .\launch_faceswap_studio.py
```

### 直接启动桌面应用

```powershell
./启动FaceSwap Studio.exe
```

## 6. 首次启动建议顺序

推荐按下面顺序验证：

1. 安装依赖
2. 预下载模型
3. 启动 FaceFusion
4. 启动 FaceSwap Studio
5. 打开首页检查 Bridge 与 FaceFusion 状态
6. 进入工作台选择源文件和目标文件

## 7. 软件特点说明

### 首页

- 展示 Bridge 状态
- 展示 FaceFusion 状态
- 提供启动 / 停止 / 浏览器打开
- 展示运行日志和系统资源

### 工作台

- 操作台支持原生文件选择
- 生成队列支持顺序执行任务
- 可联动浏览器中的高级参数

### 作品管理

- 浏览生成结果
- 收藏常用作品
- 下载、删除、预览图片与视频

### 设置

- 切换主题
- 配置默认输出目录

### 关于

- 展示当前架构说明
- 给出合规使用提醒

## 8. 常见问题

### 8.1 启动器打不开

排查顺序：

1. 检查是否被 Windows 安全策略拦截
2. 检查仓库目录是否完整
3. 检查是否缺少运行时依赖

### 8.2 GPU 没生效

检查：

- `nvidia-smi` 是否可用
- 驱动是否安装正确
- 当前机器是否具备 CUDA 推理条件

### 8.3 7860 页面还是旧内容

如果你刚改过 WebUI 页面结构：

1. 停止当前 FaceFusion 进程
2. 重新启动 FaceFusion
3. 刷新浏览器

### 8.4 工作台页面显示异常

如果是近期更新后出现的界面问题，优先重新启动桌面应用。如果问题仍然存在，再检查：

- 当前部署包是否已经更新
- 是否误用了旧运行包
- 浏览器和桌面壳层是否混用了不同版本的 Bridge

## 9. 开发者说明

如果你要继续开发：

- Flutter 前端位于 `faceswap studio/flutter_app/`
- Bridge 位于 `faceswap studio/bridge/`
- FaceFusion 引擎位于 `facefusion/`

推荐在每次较大修改后同步做三件事：

1. 更新 README 或文档
2. 重新构建桌面运行包
3. 在确认界面稳定后再补充截图资源
