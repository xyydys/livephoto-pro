# 实况原画 · LivePhoto Pro (v2.0)

把高清视频无损保存为 iOS 系统相册中的 Live Photo（实况照片）。转换器直接将兼容视频（H.264 / HEVC）的压缩样本比特级直通写入配对 MOV，没有重新编码、画质劣化或补帧环节；同时突破了传统 3 秒时长限制，并从 iOS 系统底层强制撤销了实况照片播放时的默认放大效果。

## 核心特性

1. **1:1 强制撤销实况播放默认放大**：
   - 在 iOS 系统底层框架 `PhotosPlayer.framework`（`-[ISLivePhotoPlayer _updateScaleIfNeeded]`）中，当 `playerContent.supportsVitality` 为 `true` 时，系统会在长按播放实况照片时默认施加 `0.3s` 的 `1.075x`（放大 7.5%）镜头推进缩放。
   - 本项目通过向配对 MOV 容器层注入 `mdta/com.apple.quicktime.live-photo.vitality-disabled = 1` 与 `com.apple.quicktime.live-photo.transition-vitality-score.v1 = 0.0` 元数据，使 `PhotosFormats.PFMetadataMovie.hasVitality` 返回 `false`，从而强制 `ISLivePhotoPlayer` 在播放时保持 `scale = 1.0`（1:1 原画比例，零放大），并且以 `AVAssetImageGenerator.ApertureMode.encodedPixels` 采样静态封面，实现与直接播放原视频一致的画面比例。
2. **突破 3 秒时长限制 & 自由区间截取**：
   - 支持将任意完整时长的视频（如 5 秒、10 秒、30 秒或更长）直接转为实况照片，也支持在时间轴工作台上自由截取指定起止区间或快速选择 `3 秒 / 5 秒 / 10 秒 / 完整全长` 预设。
3. **首帧零跳动封面 & 任意自选封面帧**：
   - 默认以片段首帧（`0.0s`）作为静态封面，实现从封面过渡到播放时零跳帧；也支持通过胶片缩略图时间轴自由拾取任意时间戳作为封面帧（Key Photo），并支持 `JPEG (100% 质量)` 与 `HEIC` 两种封面格式。
4. **高帧率满帧播放 & 智能音轨处理**：
   - 自动写入 `com.apple.quicktime.full-frame-rate-playback-intent = 1` 保留 60fps / 120fps 高刷丝滑度；AAC 音轨零重编码直通，PCM 等非 AAC 音轨自动智能转封装为高码率 AAC-LC（亦可一键静音导出）。
5. **原生 Liquid Glass 界面**：
   - iOS 26 使用系统原生液态玻璃（`glassEffect` / `GlassEffectContainer` / `.glassProminent`），iOS 17–18 自动降级为材质玻璃；背景可选「画面氛围」（当前封面帧柔焦铺底）或「纯净深色」。
   - 卡片分层入场、模糊替换过渡、可拖拽胶片截取手柄、带放大镜的封面帧拾取、逐帧微调、顶部轻提示与触感反馈。

## 在 iPhone 上运行

1. 在 Xcode 15 / 16 或更新版本打开 `LivePhotoPreserve.xcodeproj`，选择 `LivePhotoPreserve` scheme。
2. 在目标的 **Signing & Capabilities** 中选择自己的 Team，连接运行 iOS 17 或更新版本的 iPhone，再运行 App。如签名提示标识符冲突，可在 `LivePhotoPreserve.xcconfig` 改成自己的 Bundle Identifier。
3. 从「相册」或「文件」导入高清视频，按需调整时长区间、封面帧与 1:1 防缩放开关，可先点「生成实况并在 App 内预览」长按测试，或直接点「转换并存入系统相册」。

## 验证导出的视频

用「文件」导入一段固定构图、四角有标记的短片。可在「照片」或应用内实况预览中观察从首帧过渡到长按播放时四角是否发生任何缩放位移。要校验转换后的文件是否完好保留了原始压缩视频流，可导出配对 MOV 并运行：

```sh
python3 scripts/verify-video.py source.mp4 exported-paired.mov
```

脚本对比压缩视频包的 SHA-256、相对显示和解码时间、分辨率、方向、有效画幅与色彩参数。退出码 `0` 表示压缩视频样本与几何属性完全一致。
