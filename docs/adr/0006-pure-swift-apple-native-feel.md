# 0006 — 纯 Swift 与苹果第一方观感（原生红线）

本 ADR 把 ADR-0001 的"纯 Swift macOS 原生应用"从叙事升级为**可验收的工程约束**：实现语言只有 Swift，UI 只用 Apple 系统框架，观感目标是让用户分不出它与苹果第一方工具（Finder、系统设置、Xcode Organizer）的差别。

## 约束（红线）

- **语言与框架**：实现语言只用 Swift；UI 只用 SwiftUI + AppKit + Apple 系统框架。禁止 webview / Electron / Tauri / React Native / Flutter 外壳，禁止非 Apple 渲染栈（GPUI 等），禁止 Mac Catalyst 移植。
- **UI 层零第三方依赖**：不引入第三方组件库、图标包、字体包、动画库。非 UI 层依赖仍受 AGENTS.md 的"每个依赖自证维护与体积成本"约束（当前只有 Yams，读侧 YAML 刚需）。
- **只用系统素材**：语义颜色（`Color.primary`、`.secondary`、`.accentColor`…）、SF Symbols、系统字体。不硬编码颜色、圆角、阴影值来模仿系统外观。
- **不自绘 chrome**：不自定义标题栏、侧边栏、滚动条、开关、进度条；窗口结构用 `NavigationSplitView`、设置用 `Settings` 场景、全局动作用 window toolbar、模态用系统 sheet / alert / `confirmationDialog`、预览走 Quick Look。
- **新能力靠继承，不靠模仿**：系统新观感（macOS 26 的 Liquid Glass 等）必须由标准控件自动获得；需要新 API 时用 `#available` 门控做渐进增强，旧系统退回标准表现。任何"自己画一层玻璃"的实现视为违反红线。
- **跟随系统偏好**：深浅色、强调色、Increase Contrast、Reduce Transparency、Reduce Motion、辅助功能字号、VoiceOver 标签一律跟随系统。不提供 app 内主题切换或 app 内语言切换；本地化（`en` + `zh-Hans`）由系统语言驱动。
- **键盘与菜单**：主菜单栏承载全部命令并标注快捷键，`⌘,` 打开标准设置窗口；没有只能靠鼠标完成的操作。
- **应用图标**：Icon Composer（`.icon`）单一来源，必须带底板 `fill` 与图层阴影，保证浅色与深色背景下都可见（此前一次回归把 `fill` 去掉、阴影归零，图标在浅色 Dock 上等于隐形）。

## Consequences

- 想要"特别"的视觉时，改设计去贴合系统控件，而不是自绘控件去贴合设计稿。视觉差异化不是本产品的竞争位置（裁判身份才是）。
- 审查清单（PR 级）：UI 层无第三方依赖、无硬编码颜色/材质、无自绘 chrome、新系统 API 均有 `#available` 门控、新增字符串进双语 catalog、新增控件带辅助功能标识与 `.help` 说明。
- 门禁沿用现有工具链：`swift-format` + `swiftlint --strict` + `swift test`；图标可见性用构建产物图标的平均亮度做量化检查，别再靠肉眼。
- 只做 macOS（沿用 ADR-0001）。不为跨平台复用而降低原生度，iOS / iPadOS 版本不在路线内。
- 新系统的适配工作因此收敛为"抬高 SDK、跑一遍门禁、`#available` 门控点检"，而不是一轮 UI 重绘。
