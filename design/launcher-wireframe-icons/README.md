# 启动器动画风格双面具图标

采用用户最后确认的方向：启动器右上角人脸融合动画的线框样式，包含人脸轮廓、三角网格、特征点与流动粒子。两张人脸按卡牌方式前后错位，鼠尾草绿在后、暖铜色在前，整体扁平化、透明背景。

图形直接复用 `installer/bootstrap/Program.cs` 中 `FaceFusionArtwork` 的五段贝塞尔轮廓、20 个特征点、30 条网格边与眉眼鼻口路径，用代码输出。最终版未采用先前 imagegen 的实体面具草稿。

## 文件

- `icon-master.png`：1024 × 1024 RGBA 透明主图。
- `icon.svg`：可编辑矢量图，透明底，保持主图的轮廓、配色和布局，粒子为固定静态位置。
- `png/`：16、20、24、32、40、48、64、96、128、192、256、512、1024 像素透明 PNG。16 至 48 像素自动简化网格并加粗轮廓。
- `faceswap-studio.ico`：Windows 图标，包含 16、20、24、32、40、48、64、96、128、256 像素共 10 帧，各尺寸独立渲染。
- `icon-animated.webp`：384 × 384，40 帧，约 3.32 秒循环，透明背景，包含粒子流动与前脸扫描线。Windows ICO 本身是静态格式，动效文件用于界面或预览。
- `preview-light-dark.png`：浅深背景与小尺寸预览，此文件本身有背景。
- `validation.json`：PNG 透明通道、ICO 实际帧、WebP 帧数及透明度验证记录。
- `faceswap-studio-icons.zip`：完整交付包。

重新导出（需 Pillow）：

```powershell
python design/launcher-wireframe-icons/export_icons.py
```

用户已确认并授权全面应用：`scripts/sync_brand_icons.py` 将本目录资源同步到软件、启动器、安装器与 Web；桌面侧栏及 Web 页头使用统一品牌组件。原生 ICO 保持静态，应用界面支持透明 WebP 动画并遵循系统减少动画偏好。正式版本不变。
