# FaceSwap Studio Bridge

本目录用于承载 Flutter 与 FaceFusion 之间的本地 Python Bridge。

当前阶段已初始化：

- `app_server.py`：最小 FastAPI 服务入口
- `requirements.txt`：Bridge 基础依赖

后续将逐步补齐：

- FaceFusion 启动 / 停止控制
- 资源监控采集
- 日志流
- 队列与作品接口
