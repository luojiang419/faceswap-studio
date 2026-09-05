# FaceFusion 核心升级 3.9.0

状态：已完成
当前阶段：5/5
最后更新：2026-09-05 10:00

## 当前状态

已将仓库核心升级到官方 `3.9.0`，完整迁移 `alphaface_256` 换脸模型、`hrffa` 人脸关键点模型及 `JOBS_PATH` 默认值修正。8 个核心文件已与官方标签逐项核对，除 `types.py` 文件末尾空行外内容一致。

本地 `facefusion/` 与官方 `3.8.3` 的有效源码一致，仅额外保留一个未被引用的历史文件 `facefusion/uis/components/common_options.py`；大量文件哈希差异来自 CRLF/LF，不属于功能定制。工作区存在用户尚未提交的 Flutter、构建脚本和历史测试修改，本任务不回退、不覆盖这些改动。

核心自动升级已增加安全解压、完整性/版本/API 兼容预检、替换后独立进程复检和失败自动回滚。上次故障涉及的 Bridge `get_output_file_extension` shim、worker `face_creator` API 与预览函数签名均已纳入强制预检和回归测试。仓库和 `D:\Program Files\FaceSwap Studio` 均完成真实启动验证，安装版正式 launcher、Flutter、Bridge 和 FaceFusion 联合运行稳定。

## 下一步

下一步首先执行：

1. [已完成] 仓库 Bridge、FaceFusion 和 WebUI 真实启动验证。
2. [已完成] 创建 `backup/v001` 并同步安装目录必要文件。
3. [已完成] 安装版正式 launcher、Flutter、Bridge、FaceFusion 联合稳定性验证。
4. [已完成] 提交本轮文件并推送远程。

## 当前 TODO

- [x] 确认上游最新正式版本与发布说明
- [x] 建立本地 3.8.3 定制差异清单
- [x] 审查并迁移 3.9.0 核心差异
- [x] 补充核心升级兼容性保护与回归测试
- [x] 完成仓库级静态检查和相关测试
- [x] 完成 Bridge/FaceFusion 实际启动验证
- [x] 检查安装目录同步策略并按验证结果部署
- [x] 更新文档、提交并推送

## 最近验证状态

- 静态检查：核心与 Bridge `compileall` 通过；目标文件 `git diff --check` 无错误，仅有既有 LF/CRLF 提示
- 单元测试：核心版本/新模型、Bridge/worker/launcher、Job 管理相关合并回归 `71 passed, 1 warning`
- 编译：本轮未修改 Flutter；Python 模块编译通过
- 运行测试：仓库与安装目录 Bridge `/health` 200、核心 `3.9.0`、FaceFusion `ready`、WebUI 200；安装版 Flutter/launcher 稳定观察通过且无新增 Windows 崩溃事件
- 最近功能 Git commit：`e0c8def feat: upgrade FaceFusion core to 3.9.0`
- push：已推送 `origin/feat/facefusion-core-3.9.0`

---

## 任务目标

将 FaceSwap Studio 内置 FaceFusion 核心从 `3.8.3` 升级到官方最新正式版 `3.9.0`，保留现有 Studio 定制与用户未提交改动，并防止再次发生核心升级后 Bridge 或 FaceFusion 无法启动的问题。

## 当前项目现状

- 仓库：`G:\\app\\facefusion\\faceswap-studio`
- 分支：`feat/facefusion-core-3.9.0`
- 上游：`https://github.com/facefusion/facefusion.git`
- 当前核心：`3.8.3`
- 目标核心：`3.9.0`
- 官方变更文件：`face_landmarker.py`、`jobs/job_manager.py`、`metadata.py`、`background_remover/core.py`、`face_swapper/choices.py`、`face_swapper/core.py`、`face_swapper/types.py`、`types.py`
- 关键适配层：`faceswap studio/bridge/app_server.py`、两个 Bridge worker、`launch_faceswap_studio.py`
- 已知脏工作区：Flutter 前端、构建脚本、配置、历史测试等用户改动，必须保留。

## 技术方案

以官方标签 `3.8.3` 为基线核对本地定制，再应用官方 `3.8.3..3.9.0` 的最小文件级变更。升级自动应用链路增加候选核心静态兼容预检，并在替换后执行可回滚的导入冒烟；失败时恢复备份，避免把不可启动版本留在安装目录。Bridge 自有兼容逻辑不放入上游核心目录，以降低后续升级冲突。

## 文件 / 模块清单

预计修改：

- 官方变更涉及的 8 个 `facefusion/` 核心文件
- `faceswap studio/bridge/app_server.py`
- 核心升级与 Bridge 兼容相关测试
- 本任务文档

明确不主动修改：

- 用户当前未提交的 Flutter 页面与构建脚本
- `facefusion.ini` 中 Studio 的 CUDA、线程数和下载源默认值
- 安装目录运行数据、模型、输出和用户设置

## 开发阶段

- [x] 阶段 1：现状与上游差异分析
- [x] 阶段 2：核心 3.9.0 迁移
- [x] 阶段 3：升级保护与兼容测试
- [x] 阶段 4：集成和真实启动验证
- [x] 阶段 5：部署、提交与推送

## 验收标准

- [ ] `facefusion.metadata` 返回 `3.9.0`。
- [ ] 官方 3.9.0 的 `alphaface_256` 与 `hrffa` 能力完整迁移。
- [ ] Bridge 模块可在仓库虚拟环境正常导入。
- [ ] 两个 worker 继续使用 `face_creator` 当前 API。
- [ ] 核心升级流程能拒绝明显不兼容包，并在替换后验证失败时自动回滚。
- [ ] 相关 pytest、compileall 和核心 CLI/Bridge 启动冒烟通过。
- [ ] 用户原有未提交改动保持不丢失，提交中不混入无关修改。
- [ ] 已配置的 `origin` 完成正常 push。

## 已完成内容

- 查询官方标签与 Release，确认 `3.9.0` 为最新正式版。
- 克隆隔离上游仓库并建立 `3.8.3`/`3.9.0` 对照工作树。
- 确认核心有效源码与官方 `3.8.3` 一致，上游升级范围为 8 个核心文件。
- 阅读上次 `3.8.3` 升级故障任务文档和相关历史快照。
- 完成官方 3.9.0 核心迁移和新模型清单验证。
- 为核心自动升级增加候选预检、Zip 路径保护、替换后复检和自动回滚。
- 新增核心升级事务测试并完成 Bridge/worker/launcher、Job 管理回归。
- 创建 `backup/v001`，保存安装版 3.8.3 核心与 Bridge 关键文件。
- 将 8 个官方核心文件与 Bridge 升级保护同步到安装目录，逐文件哈希一致。
- 仓库和安装目录均完成真实 Bridge/FaceFusion 启动；正式安装版前端联合运行未出现崩溃。

## 当前关键修改

- 修改官方涉及的 8 个核心文件，版本更新为 `3.9.0`。
- 修改 `faceswap studio/bridge/app_server.py`，将核心替换改为可预检、可回滚流程。
- 修改 `tests/test_app_server_updates.py`，覆盖安全解压、预检、回滚与成功应用。
- 新增 `tests/test_facefusion_core_version.py`，固定校验 3.9.0 版本与两个新模型能力。

## 已知问题

- `pytest tests` 仍在收集阶段遇到 6 个历史旧 API 测试错误：`curl_builder.resolve_proxy_commands`、`face_analyser`、`resolve_temp_frame_paths`、`filesystem.get_output_file_extension`、`memory`、`get_temp_frames_pattern`。其中部分测试存在本任务开始前的用户未提交修改；本轮相关回归和真实运行均已通过，未改写这些历史用例。
- 直接执行 `pytest -q` 会继续递归收集 `backup/` 中的旧测试副本并产生同名模块污染；应使用 `pytest tests` 或后续单独增加 pytest 收集配置。
- 正式 launcher 首轮观察期间收到一条来自测试清理时序交叉的 `/facefusion/stop`；日志确认是正常请求退出而非崩溃。重新启动后稳定观察 30 秒保持 `ready`，无后续停止或异常日志。

## 开发日志

- 2026-09-05：启动任务，完成上游版本、历史故障和本地定制差异调查。
- 2026-09-05：完成核心迁移、升级事务保护、自动回滚测试和仓库启动验证。
- 2026-09-05：完成安装目录备份、同步与正式 launcher 联合稳定性验证。
- 2026-09-05：功能提交 `e0c8def` 已推送到 `origin/feat/facefusion-core-3.9.0`，任务完成。

## 接力信息

[CODEX_LONG_TASK_CONTINUE_V3]

新会话启动：

1. 阅读项目规则和本任务文档。
2. 检查 Git branch 与 `git status`。
3. 以源代码和 Git 状态修正文档偏差。
4. 从“下一步”直接继续，不重复已完成阶段。
