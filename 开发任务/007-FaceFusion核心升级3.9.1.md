# FaceFusion 核心升级 3.9.1

[CODEX_LONG_TASK_CONTINUE_V3]

状态：全部完成，实现、运行验证和交付文档已完成。
下一步：使用仓库启动器运行新版核心；本轮不发布安装器或外部更新，不覆盖用户安装目录。
TODO：无功能遗留；本地提交交付，今日不再自动推送。
最近验证：87 项定向 pytest 全部通过；compileall、diff --check、pip check 通过；CLI 3.9.1、完整性校验、Bridge 健康检查和 WebUI HTTP 200 / ready 均通过。
Branch：feat/facefusion-core-3.9.1；起点 08f9f8e。
GitHub：当日同步标记为 2026-10-19，按规则本次仅本地提交，不自动再次推送。
阻塞：无。

## 范围与验收

- 官方最新稳定版为 3.9.1（2026-09-30，7247081）；v4-beta 为预发布测试版，本次不迁移破坏性测试版架构。
- 完整接入内容分析 CoreML 性能修复、CUDA arena 内存规避版本边界、运行时版本读取、各处理器音频依赖和依赖版本更新。
- 通过三方合并保留魔搭下载、完整模型清单、系统代理与 Studio 适配。
- 核对工作台模型 schema、参数规范化和 worker 的 AlphaFace / HRFFA 接入。
- 核心版本、受影响行为和 Bridge/worker 定向测试通过；CLI、Bridge 和 WebUI 实际启动检查通过。
- 不覆盖初始已有修改：安装/打包脚本、安装文档、用户设置、Flutter metadata、launcher C#、四个旧核心测试及缓存占位删除。
- 本任务文件单独提交；应用 VERSION 不因核心调试而递增。不自动发布外部更新或改动用户安装目录。

## 官方证据

- https://github.com/facefusion/facefusion/releases/tag/3.9.1
- https://github.com/facefusion/facefusion/compare/3.9.0...3.9.1
- compare 原始响应保存在 build/core-3.9.1/compare.json（不提交）。
- 官方变更包含 16 个核心文件、requirements.txt 和上游推理测试；本地旧推理测试与上游已存在差异，已单独补充行为回归。

## 已完成及实际验证

- 三方合并全部 16 个核心文件和 requirements.txt。15 个核心文件及依赖列表与官方 3.9.1 标签内容一致；deep_swapper 仅保留原有魔搭通用 URL 解析定制，差异已逐项核对。
- 3.9.1 没有新增模型资产；247 个模型选项及 508 项资产仍复用已发布固定清单。完整清单匹配、下载续传、代理和 SHA 校验回归通过。
- 本机实际安装 onnx 1.23.1、scipy 1.18.1、tqdm 4.70.1；CUDA 12 继续使用官方规定的 onnxruntime-gpu 1.24.4。CPU/CUDA 13 的安装定义更新至 1.30.0，QNN 至 2.6.0；未声称在本机实测这些其他后端。
- 新增推理池版本边界、CoreML 分支、运行时版本 API、10 个处理器音频依赖和官方完整性校验测试。
- 工作台 schema、模型参数规范化、CLI 转换及核心 argparse 实测接受 AlphaFace 256、1024x1024 和 HRFFA；现有 worker API 回归通过。
- 真实运行发现旧 Bridge 只设置 FACEFUSION_UI_HOST/PORT，Gradio 不读取这些变量。7860 已被其他应用占用，核心自动使用 7861，Bridge 误判始终 starting。修正为同时传递 GRADIO_SERVER_NAME/PORT，并设置 GRADIO_NUM_PORTS=1，避免静默跳端口；新增针对继承环境覆盖的回归。
- 最终独立 Bridge 52749 / WebUI 17861 真实启动：health=ok、核心 ready、首页 HTTP 200、/config 包含 alphaface_256 和 hrffa，观察 5 秒保持 ready；验证结束仅停止本次测试进程，原有 7860 应用未动。
- 首轮运行超时已定位并修复，最终证据见 build/core-3.9.1/runtime-result.json；官方源码比对见 source-audit.json。
- 执行命令：`.venv-win/Scripts/python.exe -m pytest tests/test_facefusion_core_version.py tests/test_facefusion_391_compatibility.py tests/test_app_server_workspace_options.py tests/test_workspace_workers.py tests/test_app_server_updates.py tests/test_launcher_updates.py tests/test_app_server_queue_tasks.py tests/test_modelscope_assets.py tests/test_modelscope_client.py tests/test_inference_manager.py tests/test_execution.py -q`，结果 `87 passed in 25.38s`。
- 本轮未修改 Flutter 界面或构建新安装器，未发布魔搭更新，未实测全部模型推理或真实素材生成。
