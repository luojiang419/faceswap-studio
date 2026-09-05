# FaceFusion 核心升级兼容与回滚

## 问题表现

应用 FaceFusion 新核心后，Bridge 可能在导入阶段退出，launcher 报告 `Bridge failed to start`。即使文件覆盖本身成功，也可能因上游 API 删除、函数签名变化或依赖缺失导致 FaceFusion/worker 无法运行。

## 触发条件

- 直接用上游源码包覆盖本地 `facefusion/`。
- Bridge 或 worker 仍导入上游已删除/重命名的 API。
- 更新包版本与声明版本不一致，或缺少入口和依赖文件。
- 覆盖完成后未在独立进程中重新导入新核心。

## 根本原因

核心源码更新与 Studio 适配层存在运行时契约。仅校验压缩包包含 `facefusion/` 目录，无法证明 Bridge 所需模块、`face_creator` API、预览函数签名和当前 Python 依赖仍兼容。旧升级器在覆盖后直接标记成功，失败时也没有自动恢复原核心。

## 无效尝试

- 只修改 `facefusion.metadata` 的版本号。
- 只运行 `compileall`；它无法发现导入符号和依赖错误。
- 覆盖后依赖当前 Bridge 进程内已缓存的旧模块判断成功。
- 失败时只保留备份路径，但不主动恢复。

## 正确解决方案

1. 以当前官方标签为基线，分别核对本地定制差异与上游版本差异。
2. 解压前校验 Zip 成员路径，拒绝路径穿越；解压后检查唯一源码根目录和完整 payload。
3. 替换前在独立 Python 进程中导入 Bridge/worker 所需模块，并校验核心版本、`face_creator.get_many_faces` 和 `process_preview_frame` 签名。
4. 预检通过后创建时间戳备份，再替换核心。
5. 替换后使用新的独立 Python 进程复检实际安装目录；失败立即从备份自动回滚。
6. 最后执行 Bridge `/health`、FaceFusion `ready`、WebUI HTTP 200 和正式 launcher/Flutter 稳定性验证。

Bridge 自有兼容逻辑应放在 `faceswap studio/bridge/`，避免写回上游核心文件，从而降低下次升级的冲突面。

## 验证方法

- `python facefusion.py --version`
- Bridge 模块独立导入
- `GET /health` 返回 HTTP 200
- `POST /facefusion/start` 后状态进入 `ready`
- `http://127.0.0.1:7860` 返回 HTTP 200
- 自动升级测试覆盖：预检拒绝、恶意路径拒绝、替换后失败回滚、成功应用保留备份

## 如何避免

- 不直接整目录盲目覆盖后立即宣告成功。
- 不把本地兼容函数长期放在上游核心目录。
- 上游发布新版本时先查看变更文件和依赖差异。
- 真实启动验证前确认旧进程与端口已清理，避免把进程复用/清理时序误判为新版故障。

## 影响模块

- `facefusion/`
- `faceswap studio/bridge/app_server.py`
- `faceswap studio/bridge/services/`
- `launch_faceswap_studio.py`
- 安装目录核心更新流程
