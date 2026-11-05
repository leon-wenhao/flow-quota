# Flow Quota 标志

设计日期：2026-11-05。用户已选择第二轮 C「流量刻度」。深青色圆角底板搭配薄荷绿刻度：三根圆角柱表示观测用量，右上方分离的圆点表示提醒阈值。图形不依赖文字；菜单栏使用相同轮廓的单色模板。选项 A／B／C 的原始提案保留在 `concepts-v2/`，正式图标与 C 提案逐字节一致。

| 文件 | 用途 |
| --- | --- |
| `FlowQuota.icns` | macOS 应用包图标，包含 16–1024 像素的标准图像表示 |
| `app-icon.png` | 1024×1024 透明画布应用图标，可用于文档或后续平台适配 |
| `logo-preview.png` | 512×512 预览 |
| `logo-mark.svg` | 可编辑矢量标志，适用于深色背景，不包含应用图标底板 |
| `logo-mark.png` | 1024×1024 透明标志 |

## 修改与重新生成

唯一手写几何源在 `macos/Sources/FlowQuotaApp/BrandIdentity.swift`。`FlowQuotaGlyph` 集中定义浅色用量柱与薄荷绿强调部分的几何及配色；`FlowQuotaAppIcon` 定义底板、留白和颜色；窗口标题与导出器使用同一 SwiftUI 组件。修改源文件后执行：

```sh
./scripts/generate-brand-assets.sh
./scripts/build-macos.sh
```

生成器使用本机 Xcode 的 SwiftUI ImageRenderer 从矢量重绘所有尺寸，再由 Apple 官方 iconutil 打包；不需要在线图像服务或第三方依赖。SVG 从同一实际轮廓与渐变配色导出，避免另行维护一套几何。脚本输出中间 iconset／工具到忽略的 `.artifacts/brand-tools/`，最终资源保存在本目录并随项目保存。

菜单栏使用 AppKit `NSImage(size:flipped:drawingHandler:)` 的分辨率无关绘制并设置 `isTemplate = true`，由系统适配菜单栏颜色。它复用同一标志轮廓，不把彩色图标直接缩小；暂停／未知状态沿用状态提示并降低图像亮度。绘制闭包显式 Sendable，只访问值类型几何和当前线程的绘制上下文。

构建脚本将 ICNS 复制到 `Contents/Resources/FlowQuota.icns`，Info.plist 的 `CFBundleIconFile` 指向该文件，再对完整应用包签名。未来修改图标必须重新构建和安装完整应用，避免直接修改已签名包的资源。本轮不改变数据库、阈值、采样或权限配置。
