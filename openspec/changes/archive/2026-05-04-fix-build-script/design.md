## Context

当前 `build.sh` 生产的 app bundle 存在三个缺失组件，导致启动失败：

1. **Info.plist 未正确复制** — 脚本中有 `cp Info.plist` 但实际构建产物中缺失
2. **Sparkle.framework 未嵌入** — 自动更新框架未复制到 `Contents/Frameworks/`
3. **rpath 未配置** — 主 binary 缺少 `@executable_path/../Frameworks`，无法加载嵌入的 framework

手动修复后应用可正常启动，但每次构建都需要重复手动操作。脚本结构也缺乏清晰的阶段划分，难以定位问题。

## Goals / Non-Goals

**Goals:**
- 修复缺失组件，使 `./build.sh` 产出完整可用的 app bundle
- 重组脚本结构，添加清晰的阶段标记
- 保持现有功能：universal binary、签名自动检测、notarization + DMG（可选）

**Non-Goals:**
- 不添加开发模式（--dev 快速构建）
- 不拆分为多文件
- 不替换为 Makefile
- 不改变 notarization 或 DMG 流程

## Decisions

### 1. 脚本结构重组：阶段划分

**Decision**: 将脚本划分为 5 个阶段，添加明确的阶段标记注释。

**Rationale**: 当前脚本逻辑连续，难以定位问题。阶段划分后可快速找到对应逻辑位置。

**Phases**:
- Phase 1: Build (universal binary)
- Phase 2: Bundle Assembly (目录结构 + Info.plist + binaries)
- Phase 3: Framework Embedding (Sparkle + rpath)
- Phase 4: Code Signing (bridge → framework → app)
- Phase 5: Optional Notarization + DMG

### 2. Info.plist 复制时机

**Decision**: 在创建目录结构后立即复制 Info.plist，而非在 lipo 之后。

**Rationale**: Info.plist 是纯文本文件，不依赖架构合并。早期复制可确保后续步骤（如 icon 编译）能读取版本信息。

**Implementation**:
```bash
mkdir -p "$APP_BUNDLE/Contents/Frameworks"  # 新增
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"  # 修复点
```

### 3. Sparkle.framework 嵌入

**Decision**: 从 SPM 构建产物复制 Sparkle.framework 到 `Contents/Frameworks/`。

**Rationale**: Sparkle 是 SPM 依赖，构建后已存在于 `.build/*/release/`。直接复制即可，无需额外下载。

**Implementation**:
```bash
SPARKLE_SRC=".build/arm64-apple-macosx/release/Sparkle.framework"
cp -R "$SPARKLE_SRC" "$APP_BUNDLE/Contents/Frameworks/"
```

### 4. rpath 配置

**Decision**: 使用 `install_name_tool -add_rpath` 添加 Frameworks 搜索路径。

**Rationale**: macOS 加载 embedded frameworks 时搜索 `@rpath`。默认 rpath 不包含 `@executable_path/../Frameworks`。

**Implementation**:
```bash
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
```

**Timing**: 必须在签名之前执行，因为修改 binary 会破坏签名。

### 5. 签名顺序调整

**Decision**: 按 nested component → parent component 顺序签名。

**Rationale**: 父签名必须引用子签名的 hash。错误顺序会导致父签名失效。

**Correct order**:
1. bridge (`Contents/Helpers/codeisland-bridge`)
2. Sparkle.framework (`Contents/Frameworks/Sparkle.framework`)
3. app bundle (整体，含 entitlements)

### 6. Bundle 验证步骤

**Decision**: 在脚本末尾添加完整性检查，验证必需文件和 rpath 存在。

**Rationale**: 避免生成不完整 bundle 后才发现问题。早期失败比后续手动排查更高效。

**Checks**:
- Info.plist 存在
- Main binary 存在
- Sparkle.framework 存在
- rpath 已配置

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Sparkle framework 路径因 SPM 版本变化 | 使用 `.build/*/release/Sparkle.framework` glob 模式，并添加存在性检查 |
| install_name_tool 使签名失效 | 确保 rpath 添加在签名之前（Phase 3 vs Phase 4） |
| 签名顺序错误导致 bundle 不可用 | Phase 4 中明确按 bridge → framework → app 顺序 |
| 验证步骤增加构建时间 | 仅检查文件存在性和 rpath，耗时 < 1s |