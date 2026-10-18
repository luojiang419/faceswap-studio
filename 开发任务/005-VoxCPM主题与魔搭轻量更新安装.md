# VoxCPM主题与魔搭轻量更新安装

[CODEX_LONG_TASK_CONTINUE_V3]

状态：全部功能、发布与实测完成，正在记录本地Git提交。
下一步：用户运行正式轻量安装器；后续发布使用同一签名密钥和不可变资源路径。
TODO：无功能遗留。
最近验证：76项Python测试、10项原生下载测试、26项原生安装集成测试、2项Flutter渲染测试通过；Flutter分析、Windows/Web构建、PowerShell语法及FaceFusion CLI通过。
Branch：feat/modelscope-theme-installer；起点253bad8；实现提交随本轮交付记录。
GitHub：2026-10-18已检查，本轮只本地commit，不自动push。
阻塞：无。原Windows截图helper超时，改用实际Flutter控件渲染验证，未虚构桌面截图。

## 已交付

- 保留Flutter + Python + FaceFusion，六个现有页面统一为VoxCPM的中性浅色/暖黑深色主题；统一导航、卡片、输入、弹窗、按钮。
- 用户反馈首页按钮丑陋后已改为单行紧凑主按钮+细框次按钮，去掉厚描边和投影；四种主题/启用状态及六页浅深共16张预览已检查。
- 魔搭Ed25519签名更新、逐文件SHA256、断点续接、同版本发布序号升级、独立更新窗口、备份/回滚、掉电恢复与真实桌面/Bridge健康确认。队列运行时禁止安装。
- 原生轻量安装器复用VoxCPM的磁盘卡片、浅深切换、动画开关、暂停续传、快捷方式与卸载；首次准备Python、常用模型及FFmpeg。`.NET4.8`目标和longPathAware修复深层中文路径。
- 仓库：https://modelscope.cn/models/jiangjiang419/facefusion-workbench-updates。原名称触发魔搭命名限制后改为此名称。

## 正式产物

版本0.1.3，发布序号20261018130044，不为调试递增正式版本。

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| FaceSwap安装器.exe | 1481728 | 7530fcb7ba2e7a409602f6b88047c782ba54a932e945b485e380605e2dac6282 |
| FaceSwap-Studio-轻量安装器.zip | 1410776 | 5d92b553c3c460e78e983dd07f3dba767e3672c60db0914fdca531191e34c878 |
| 完整运行包ZIP | 3880259318 | e7c455e734c63f97151c345911594df162fcb2d2524f2c825b356ee294676923 |
| 签名应用更新包ZIP | 44251817 | ef77e29beb847a93304bb9c43595b3b68e700f3c81a06570b1495b2fa3886362 |

本地输出：dist/modelscope/installer-final。EXE约1.41MiB，分发ZIP约1.35MiB；首次联网下载运行包约3.61GiB，29600文件、展开约5.45GiB，至少12GiB可用空间。

- [正式安装器](https://modelscope.cn/api/v1/models/jiangjiang419/facefusion-workbench-updates/repo?Revision=master&FilePath=bootstrap%2F0.1.3%2F20261018130044%2FFaceSwap%E5%AE%89%E8%A3%85%E5%99%A8.exe)
- [正式分发ZIP](https://modelscope.cn/api/v1/models/jiangjiang419/facefusion-workbench-updates/repo?Revision=master&FilePath=bootstrap%2F0.1.3%2F20261018130044%2FFaceSwap-Studio-%E8%BD%BB%E9%87%8F%E5%AE%89%E8%A3%85%E5%99%A8.zip)
- 安装器、运行包及分发ZIP均已匿名完整回读校验，证明：dist/modelscope/installer-final/publication.json。
- 签名更新已发布、匿名回读并激活public/latest.json；证明在对应更新快照的publication.json。
- 私钥仅在被Git忽略的.update-private/signing-key，不进入源码提交或分发包。

## 实测与边界

- installation-result.json：在隔离深层中文目录真实解压，Python/ONNX/14个常用模型自检，真实Flutter首帧与Bridge握手，隔离快捷方式/HKCU登记通过。完整初装复用已校验本地运行包，未伪称原生联网下载了全部3.61GiB。
- online-update-result.json：从20261018124704通过魔搭真实下载升级到20261018130044；独立窗口在工作台/Bridge正常退出后继续完成，重启与健康确认通过，journal complete；400MB换脸模型及个人文件SHA256不变。
- uninstall-result.json：真实卸载保留个人作品与配置，删除应用/依赖/模型及隔离登记；本轮测试进程已清理，52761已关闭。
- build/native-network-validation/result.json：原生下载器真实魔搭HTTPS下载安装器，带已有分片，最终SHA256通过。
- 完整运行包通过匿名流式完整回读；网络提前截断时按实际偏移续接，不能将短流当成完整包。Python/原生截断及分段CDN测试通过。
- 未执行新图片/视频换脸生成，未进行其他GPU实机验证；本轮核心推理代码未变更，CLI与已安装运行环境验证通过。
- 详细日志在build/installation-validation、build/native-tests、build/theme-preview；12页预览检查使用真实控件的离屏渲染，API离线占位态不冒充实际在线截图。

## 源码与恢复

updater/负责客户端和事务，installer/bootstrap/复用原生安装器，scripts/release_modelscope.py与build_lightweight.py负责签名/打包/发布，Flutter主题与更新入口位于flutter_app/lib。

运行包更新保护faceswap studio/data、config、.assets和虚拟环境；允许Bridge内部models代码及Flutter内部data资源。经验记录在避坑指南/魔搭签名更新与长路径安装.md。

原源码备份backup/v002/theme-updater-source.zip。主题交付包含已有六页与媒体/浏览器入口的完整前端及构建依赖，保留原有功能；Bridge同时纳入已验证的模型大小修正。其他配置、FFmpeg测试、旧发布脚本和非本任务文档继续留在工作区。
