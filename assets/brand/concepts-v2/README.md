# Flow Quota 图标第二轮提案

2026-11-05。原始三方案比较稿。用户现已选择 C；正式几何已接入 `BrandIdentity.swift`，本目录继续保留原始 A／B／C 提案用于对照。

- A / ribbon：流带。白色与浅蓝色缎带形成 F，蓝色底，推荐方向。
- B / transfer：双向流。两个转弯箭头表示上传／下载，浅瓷白底。
- C / meter：流量刻度。短柱表示用量，分离的圆点表示阈值，深色底。

`comparison.png` 为完整对照页；`A-ribbon.png`、`B-transfer.png`、`C-meter.png` 为 1024 像素应用图标预览，保留透明外边距。各 `*-mark.svg` 为同源矢量标记，`*-menu.png` 为单色标记。对照页同时显示 64／40 像素图标及 18 像素浅／深色菜单栏模拟。248 MB 与时间仅为排版示例，不是实际采样数据。

`ConceptGeometry.swift` 定义几何与配色，`RenderConcepts.swift` 通过 SwiftUI ImageRenderer 本地生成 PNG，并从相同的 Path 导出 SVG。没有外部图片、字体下载、应用服务、网络采集、数据库写入或在线图像生成请求。

在仓库根目录重新生成：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -parse-as-library -swift-version 6 -target arm64-apple-macos14.0 \
  -module-cache-path .artifacts/cache/swift \
  -plugin-path /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins \
  assets/brand/concepts-v2/ConceptGeometry.swift \
  assets/brand/concepts-v2/RenderConcepts.swift \
  -o .artifacts/render-logo-concepts
.artifacts/render-logo-concepts assets/brand/concepts-v2
```

本轮已编译运行并检查完整对照图。选定 C 后已接入正式应用图标、窗口标记与菜单栏；本目录对照图仍是原始提案，安装验证以 `docs/implementation-status.md` 的正式记录为准。
