import AVFoundation
import AVKit
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Ambient Background Theme

enum AmbientTheme: String, CaseIterable, Identifiable {
    case adaptive = "随影流光"
    case aurora = "深海极光"
    case solar = "琥珀流金"
    case frost = "冰川琉璃"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .adaptive: return "sparkles.tv"
        case .aurora: return "water.waves"
        case .solar: return "sun.max.fill"
        case .frost: return "snowflake"
        }
    }

    func palette(videoPalette: [RGBAColor]?) -> [RGBAColor] {
        switch self {
        case .adaptive:
            if let videoPalette, videoPalette.count == 4 {
                return videoPalette
            }
            return Self.aurora.palette(videoPalette: nil)
        case .aurora:
            return [
                RGBAColor(r: 0.06, g: 0.36, b: 0.72),
                RGBAColor(r: 0.36, g: 0.14, b: 0.68),
                RGBAColor(r: 0.04, g: 0.58, b: 0.64),
                RGBAColor(r: 0.14, g: 0.10, b: 0.36)
            ]
        case .solar:
            return [
                RGBAColor(r: 0.72, g: 0.28, b: 0.14),
                RGBAColor(r: 0.58, g: 0.12, b: 0.42),
                RGBAColor(r: 0.80, g: 0.48, b: 0.12),
                RGBAColor(r: 0.24, g: 0.08, b: 0.26)
            ]
        case .frost:
            return [
                RGBAColor(r: 0.22, g: 0.46, b: 0.74),
                RGBAColor(r: 0.38, g: 0.36, b: 0.68),
                RGBAColor(r: 0.16, g: 0.58, b: 0.72),
                RGBAColor(r: 0.12, g: 0.20, b: 0.38)
            ]
        }
    }
}

enum DurationPreset: String, CaseIterable, Identifiable {
    case full = "完整全长"
    case threeSeconds = "3 秒"
    case fiveSeconds = "5 秒"
    case tenSeconds = "10 秒"
    case custom = "自由区间"

    var id: String { rawValue }

    var maxSeconds: Double? {
        switch self {
        case .full: return nil
        case .threeSeconds: return 3.0
        case .fiveSeconds: return 5.0
        case .tenSeconds: return 10.0
        case .custom: return nil
        }
    }
}

enum PreviewStageMode: String, CaseIterable, Identifiable {
    case video = "原片画面"
    case livePhoto = "实况预览"

    var id: String { rawValue }
}

// MARK: - Main ContentView

struct ContentView: View {
    @State private var source: ImportedVideo?
    @State private var specification: VideoSpecification?
    @State private var player: AVPlayer?

    // Pickers & sheets
    @State private var showsPhotoPicker = false
    @State private var showsFilePicker = false
    @State private var showsSettingsSheet = false
    @State private var showsAntiZoomPrincipleSheet = false
    @State private var shareItems: [URL] = []
    @State private var showsShareSheet = false

    // Preview & conversion state
    @State private var stageMode: PreviewStageMode = .video
    @State private var generatedFiles: LivePhotoFiles?
    @State private var generatedLivePhoto: PHLivePhoto?
    @State private var livePhotoPlaybackTrigger = 0
    @State private var isWorking = false
    @State private var workingStatus = "正在处理…"
    @State private var feedback: Feedback?

    // User-configurable conversion options
    @AppStorage("LP_disablePlaybackZoom") private var disablePlaybackZoom = true
    @AppStorage("LP_fullFrameRateIntent") private var fullFrameRateIntent = true
    @AppStorage("LP_includeAudio") private var includeAudio = true
    @AppStorage("LP_coverFormat") private var coverFormatRaw = CoverImageFormat.jpeg.rawValue
    @AppStorage("LP_apertureMode") private var apertureModeRaw = CoverApertureMode.encodedPixels.rawValue
    @AppStorage("LP_ambientTheme") private var ambientThemeRaw = AmbientTheme.adaptive.rawValue
    @AppStorage("LP_dynamicBackgroundMotion") private var dynamicBackgroundMotion = true

    // Timeline trimming & cover frame controls
    @State private var durationPreset: DurationPreset = .full
    @State private var trimStartSeconds: Double = 0.0
    @State private var trimEndSeconds: Double = 0.0
    @State private var useCustomCoverTime = false
    @State private var customCoverTimeSeconds: Double = 0.0
    @State private var coverPreviewImage: CGImage?
    @State private var activeAmbientPalette: [RGBAColor]?

    private var coverFormat: CoverImageFormat {
        CoverImageFormat(rawValue: coverFormatRaw) ?? .jpeg
    }

    private var apertureMode: CoverApertureMode {
        CoverApertureMode(rawValue: apertureModeRaw) ?? .encodedPixels
    }

    private var ambientTheme: AmbientTheme {
        AmbientTheme(rawValue: ambientThemeRaw) ?? .adaptive
    }

    private var currentPalette: [RGBAColor] {
        ambientTheme.palette(videoPalette: activeAmbientPalette ?? specification?.ambientPalette)
    }

    private var effectiveTrimRange: ClosedRange<Double>? {
        guard let spec = specification else { return nil }
        let total = max(0.1, spec.durationSeconds)
        switch durationPreset {
        case .full:
            return nil
        case .threeSeconds, .fiveSeconds, .tenSeconds:
            if let limit = durationPreset.maxSeconds, total > limit {
                return 0.0...limit
            }
            return nil
        case .custom:
            let start = max(0.0, min(trimStartSeconds, total - 0.1))
            let end = max(start + 0.1, min(trimEndSeconds, total))
            if start <= 0.02 && end >= total - 0.02 {
                return nil
            }
            return start...end
        }
    }

    private var effectiveOutputDuration: Double {
        guard let spec = specification else { return 0 }
        if let range = effectiveTrimRange {
            return max(0.1, range.upperBound - range.lowerBound)
        }
        return spec.durationSeconds
    }

    private var currentConversionOptions: ConversionOptions {
        let range = effectiveTrimRange
        let clipStart = range?.lowerBound ?? 0.0
        let clipEnd = range?.upperBound ?? (specification?.durationSeconds ?? 0.0)
        let coverTime: Double?
        if useCustomCoverTime {
            coverTime = max(clipStart, min(customCoverTimeSeconds, max(clipStart, clipEnd - 0.02)))
        } else {
            coverTime = nil
        }
        return ConversionOptions(
            disablePlaybackZoom: disablePlaybackZoom,
            fullFrameRatePlaybackIntent: fullFrameRateIntent,
            includeAudio: includeAudio,
            coverFormat: coverFormat,
            apertureMode: apertureMode,
            trimRange: range,
            customCoverTimeSeconds: coverTime
        )
    }

    var body: some View {
        ZStack {
            LiquidAmbientBackgroundView(
                palette: currentPalette,
                isAnimating: dynamicBackgroundMotion,
                isEnergetic: isWorking
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    topHeaderBar

                    heroPreviewStage

                    if let spec = specification {
                        mediaSpecBentoCard(spec)
                        timelineAndCoverStudioCard(spec)
                    }

                    antiZoomAndEngineCard

                    bottomActionDeck
                }
                .frame(maxWidth: 580)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsPhotoPicker) {
            VideoPhotoPicker(
                didStart: {
                    showsPhotoPicker = false
                    feedback = nil
                    workingStatus = "正在从相册载入原视频…"
                    isWorking = true
                },
                didFinish: { result in
                    Task { await finishImport(result) }
                }
            )
        }
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { result in
            Task { @MainActor in
                let url: URL
                do {
                    url = try result.get()
                } catch {
                    await finishImport(.failure(error))
                    return
                }
                feedback = nil
                workingStatus = "正在从文件无损复制原视频…"
                isWorking = true
                let imported = await Task.detached(priority: .userInitiated) {
                    Result { try ImportedVideo.copyCoordinatedFile(at: url) }
                }.value
                await finishImport(imported)
            }
        }
        .sheet(isPresented: $showsSettingsSheet) {
            settingsSheetView
        }
        .sheet(isPresented: $showsAntiZoomPrincipleSheet) {
            antiZoomPrincipleSheetView
        }
        .sheet(isPresented: $showsShareSheet) {
            ActivityShareSheet(activityItems: shareItems)
        }
        .onDisappear {
            player?.pause()
        }
    }

    // MARK: - Top Floating Liquid Glass Header

    private var topHeaderBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.cyan.opacity(0.45), Color.indigo.opacity(0.35)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [.white.opacity(0.65), .white.opacity(0.1)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )

                    Image(systemName: "livephoto")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("实况原画")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("PRO")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .tracking(0.8)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.cyan.opacity(0.85), Color.blue.opacity(0.75)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                            )
                            .foregroundStyle(.white)
                    }

                    Text(disablePlaybackZoom ? "无损直通封装 · 1:1 强制撤销播放缩放" : "无损直通封装 · 原生实况动态缩放")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }

            Spacer()

            Menu {
                Section("流光背景主题") {
                    ForEach(AmbientTheme.allCases) { theme in
                        Button {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                ambientThemeRaw = theme.rawValue
                            }
                        } label: {
                            Label(
                                theme.rawValue,
                                systemImage: ambientTheme == theme ? "checkmark.circle.fill" : theme.icon
                            )
                        }
                    }
                }
                Section("背景动态流转") {
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            dynamicBackgroundMotion.toggle()
                        }
                    } label: {
                        Label(
                            dynamicBackgroundMotion ? "已开启液态流光变换" : "已暂停背景流光",
                            systemImage: dynamicBackgroundMotion ? "pause.circle" : "play.circle"
                        )
                    }
                }
            } label: {
                Image(systemName: ambientTheme.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .modifier(LiquidGlassCircleModifier())
            }
            .accessibilityLabel("切换流光背景主题")

            Button {
                showsSettingsSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .modifier(LiquidGlassCircleModifier())
            }
            .accessibilityLabel("高级封装设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .modifier(LiquidGlassCardModifier(cornerRadius: 24, tintOpacity: 0.10))
    }

    // MARK: - Hero Preview Stage

    private var heroPreviewStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let source, let player {
                // Header inside stage
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.cyan)
                        Text(source.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }

                    Spacer()

                    if generatedLivePhoto != nil {
                        HStack(spacing: 4) {
                            ForEach(PreviewStageMode.allCases) { mode in
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        stageMode = mode
                                        if mode == .livePhoto {
                                            player.pause()
                                        }
                                    }
                                } label: {
                                    Text(mode.rawValue)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule()
                                                .fill(stageMode == mode ? Color.white.opacity(0.24) : Color.clear)
                                        )
                                        .foregroundStyle(stageMode == mode ? .white : .white.opacity(0.65))
                                }
                            }
                        }
                        .padding(3)
                        .background(Capsule().fill(Color.black.opacity(0.32)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8))
                    }

                    Menu {
                        Button {
                            showsPhotoPicker = true
                        } label: {
                            Label("从相册更换视频", systemImage: "photo.on.rectangle.angled")
                        }
                        Button {
                            showsFilePicker = true
                        } label: {
                            Label("从文件导入原片", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("更换")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8))
                        .foregroundStyle(.white)
                    }
                    .disabled(isWorking)
                }

                // Video or Live Photo Stage
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.65))

                    if stageMode == .livePhoto, let livePhoto = generatedLivePhoto {
                        LivePhotoPreviewView(
                            livePhoto: livePhoto,
                            isMuted: !includeAudio,
                            playbackTrigger: livePhotoPlaybackTrigger
                        )
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        VideoPlayer(player: player)
                            .frame(height: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .accessibilityLabel("原视频预览")
                    }

                    // Floating status badges on top of stage
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Image(systemName: "livephoto")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.yellow)
                            Text(stageMode == .livePhoto ? "长按画面测试 1:1 实况播放" : (disablePlaybackZoom ? "1:1 零缩放实况模式" : "标准实况模式"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8))

                        if effectiveOutputDuration > 3.1 {
                            HStack(spacing: 4) {
                                Image(systemName: "infinity")
                                    .font(.system(size: 10, weight: .bold))
                                Text(String(format: "%.1fs 超长实况", effectiveOutputDuration))
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.cyan.opacity(0.45), lineWidth: 0.8))
                        }

                        Spacer()

                        if stageMode == .livePhoto && generatedLivePhoto != nil {
                            Button {
                                livePhotoPlaybackTrigger += 1
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("播放实况")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.cyan.opacity(0.45), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8))
                            }
                        }
                    }
                    .padding(12)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.38), .white.opacity(0.06), .cyan.opacity(0.25)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.1
                        )
                )
            } else {
                emptyHeroImportView
            }
        }
        .padding(16)
        .modifier(LiquidGlassCardModifier(cornerRadius: 28, tintOpacity: 0.12))
    }

    private var emptyHeroImportView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.cyan.opacity(0.35), Color.indigo.opacity(0.15), .clear],
                            center: .center,
                            startRadius: 6,
                            endRadius: 64
                        )
                    )
                    .frame(width: 116, height: 116)

                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [.cyan.opacity(0.8), .white.opacity(0.9), .purple.opacity(0.7), .cyan.opacity(0.8)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 2.2, dash: [5, 5])
                    )
                    .frame(width: 82, height: 82)

                Image(systemName: "livephoto.play")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, .cyan.opacity(0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.top, 8)

            VStack(spacing: 8) {
                Text("高清视频无损直通实况照片")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("直接封装原视频 H.264 / HEVC 压缩样本，不重编码、不降画质。突破 3 秒时长限制，并从系统底层强制撤销实况播放时的默认放大。")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 8)
            }

            // Feature highlight pills
            HStack(spacing: 8) {
                featureBadge(icon: "arrow.up.left.and.arrow.down.right", text: "1:1 零放大播放")
                featureBadge(icon: "infinity", text: "突破 3 秒限制")
                featureBadge(icon: "sparkles", text: "原画比特直通")
            }

            HStack(spacing: 12) {
                Button {
                    showsPhotoPicker = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 16, weight: .semibold))
                        Text("从相册选择视频")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.55), Color.blue.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.65), .white.opacity(0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .foregroundStyle(.white)
                }
                .disabled(isWorking)

                Button {
                    showsFilePicker = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("从文件导入原片")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Color.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.45), .white.opacity(0.10)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .foregroundStyle(.white)
                }
                .disabled(isWorking)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 10)
    }

    private func featureBadge(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.cyan)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
    }

    // MARK: - Media Specification Bento Card

    private func mediaSpecBentoCard(_ spec: VideoSpecification) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("原片编码与画幅诊断", systemImage: "cpu.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(spec.isPassthroughCompatible ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(spec.isPassthroughCompatible ? "支持零重编码直通" : "非标准直通编码")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(spec.isPassthroughCompatible ? Color.green : Color.orange)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.28), in: Capsule())
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                specTile(
                    title: "画幅分辨率",
                    primary: spec.resolutionText,
                    badge: spec.resolutionTier,
                    icon: "viewfinder"
                )
                specTile(
                    title: "视频编码 & 色域",
                    primary: spec.codecName,
                    badge: spec.colorSpaceLabel,
                    icon: spec.isHDR ? "sparkles.tv.fill" : "film"
                )
                specTile(
                    title: "帧率 & 总帧数",
                    primary: spec.frameRateText,
                    badge: "约 \(spec.totalFramesEstimate) 帧",
                    icon: "speedometer"
                )
                specTile(
                    title: "时长 & 码率体积",
                    primary: String(format: "%.2f 秒", spec.durationSeconds),
                    badge: String(format: "%.1f Mbps · %@", spec.estimatedBitrateMbps, spec.fileSizeText),
                    icon: "waveform.path.ecg"
                )
            }
        }
        .padding(16)
        .modifier(LiquidGlassCardModifier(cornerRadius: 24, tintOpacity: 0.09))
    }

    private func specTile(title: String, primary: String, badge: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }

            Text(primary)
                .font(.system(size: 14.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(badge)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
        )
    }

    // MARK: - Timeline Trimming & Cover Frame Studio Card

    private func timelineAndCoverStudioCard(_ spec: VideoSpecification) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("时长截取与封面帧工作台", systemImage: "timeline.selection")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))

                Spacer()

                Text(String(format: "输出时长 %.2fs", effectiveOutputDuration))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.cyan.opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.cyan.opacity(0.38), lineWidth: 0.8))
            }

            // Filmstrip thumbnail bar
            if !spec.thumbnails.isEmpty {
                GeometryReader { geo in
                    let total = max(0.1, spec.durationSeconds)
                    let startRatio = CGFloat((effectiveTrimRange?.lowerBound ?? 0.0) / total)
                    let endRatio = CGFloat((effectiveTrimRange?.upperBound ?? total) / total)
                    let coverSeconds = useCustomCoverTime
                        ? max(effectiveTrimRange?.lowerBound ?? 0, min(customCoverTimeSeconds, effectiveTrimRange?.upperBound ?? total))
                        : (effectiveTrimRange?.lowerBound ?? 0)
                    let coverRatio = CGFloat(coverSeconds / total)

                    ZStack(alignment: .leading) {
                        HStack(spacing: 2) {
                            ForEach(Array(spec.thumbnails.enumerated()), id: \.offset) { _, cgImage in
                                Image(uiImage: UIImage(cgImage: cgImage))
                                    .resizable()
                                    .scaledToFill()
                                    .frame(
                                        width: max(10, (geo.size.width - CGFloat(spec.thumbnails.count - 1) * 2) / CGFloat(spec.thumbnails.count)),
                                        height: 54
                                    )
                                    .clipped()
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        // Dimmed masks outside active trim range
                        if startRatio > 0.005 {
                            Rectangle()
                                .fill(Color.black.opacity(0.62))
                                .frame(width: geo.size.width * startRatio, height: 54)
                        }
                        if endRatio < 0.995 {
                            Rectangle()
                                .fill(Color.black.opacity(0.62))
                                .frame(width: geo.size.width * (1.0 - endRatio), height: 54)
                                .offset(x: geo.size.width * endRatio)
                        }

                        // Active trim window frame
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.cyan, lineWidth: 2)
                            .frame(
                                width: max(16, geo.size.width * (endRatio - startRatio)),
                                height: 54
                            )
                            .offset(x: geo.size.width * startRatio)

                        // Cover frame indicator pin
                        VStack(spacing: 0) {
                            Text("封面")
                                .font(.system(size: 9, weight: .heavy))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.yellow, in: Capsule())
                                .foregroundStyle(.black)
                            Rectangle()
                                .fill(Color.yellow)
                                .frame(width: 2.2, height: 42)
                        }
                        .offset(x: min(max(0, geo.size.width * coverRatio - 14), geo.size.width - 28), y: -4)
                    }
                }
                .frame(height: 56)
            }

            // Duration Preset Chips
            VStack(alignment: .leading, spacing: 8) {
                Text("实况时长模式（已解除 3 秒限制，支持原片任意完整时长）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DurationPreset.allCases) { preset in
                            let isSelected = durationPreset == preset
                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    durationPreset = preset
                                    if preset == .custom && trimEndSeconds <= trimStartSeconds {
                                        trimStartSeconds = 0.0
                                        trimEndSeconds = spec.durationSeconds
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    if preset == .full {
                                        Image(systemName: "infinity")
                                            .font(.system(size: 11, weight: .bold))
                                    }
                                    Text(preset.rawValue)
                                        .font(.system(size: 12.5, weight: .semibold))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.cyan.opacity(0.38) : Color.white.opacity(0.08))
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            isSelected ? Color.cyan.opacity(0.85) : Color.white.opacity(0.16),
                                            lineWidth: 1
                                        )
                                )
                                .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }

            if durationPreset == .custom && spec.durationSeconds > 0.3 {
                VStack(spacing: 10) {
                    HStack {
                        Text(String(format: "起点: %.2fs", trimStartSeconds))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                        Slider(
                            value: Binding(
                                get: { trimStartSeconds },
                                set: { newVal in
                                    trimStartSeconds = min(newVal, max(0, trimEndSeconds - 0.2))
                                    seekPlayer(to: trimStartSeconds)
                                }
                            ),
                            in: 0...max(0.1, spec.durationSeconds - 0.2)
                        )
                        .tint(.cyan)
                    }

                    HStack {
                        Text(String(format: "终点: %.2fs", trimEndSeconds))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                        Slider(
                            value: Binding(
                                get: { trimEndSeconds },
                                set: { newVal in
                                    trimEndSeconds = max(newVal, min(spec.durationSeconds, trimStartSeconds + 0.2))
                                    seekPlayer(to: trimEndSeconds)
                                }
                            ),
                            in: 0.2...max(0.3, spec.durationSeconds)
                        )
                        .tint(.cyan)
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Divider()
                .overlay(Color.white.opacity(0.14))

            // Cover frame selection
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("实况封面帧 (Key Photo)")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(useCustomCoverTime ? String(format: "已指定 %.2fs 处画面作为实况静态封面", customCoverTimeSeconds) : "默认采用片段首帧作为封面，长按播放时零跳帧")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    Spacer()

                    Picker("封面策略", selection: $useCustomCoverTime) {
                        Text("首帧 (零跳帧)").tag(false)
                        Text("自选帧").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                    .onChange(of: useCustomCoverTime) { _, isCustom in
                        if isCustom {
                            let start = effectiveTrimRange?.lowerBound ?? 0.0
                            customCoverTimeSeconds = start
                            Task { await updateCoverFramePreview(at: start) }
                        }
                    }
                }

                if useCustomCoverTime {
                    let minTime = effectiveTrimRange?.lowerBound ?? 0.0
                    let maxTime = max(minTime + 0.05, (effectiveTrimRange?.upperBound ?? spec.durationSeconds) - 0.02)

                    HStack(spacing: 12) {
                        if let coverPreviewImage {
                            Image(uiImage: UIImage(cgImage: coverPreviewImage))
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.yellow.opacity(0.8), lineWidth: 1.2)
                                )
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(String(format: "封面时间戳: %.2f 秒", customCoverTimeSeconds))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.yellow)
                                Spacer()
                                Text("流光背景随帧变色")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.55))
                            }

                            Slider(
                                value: Binding(
                                    get: { min(max(customCoverTimeSeconds, minTime), maxTime) },
                                    set: { newTime in
                                        customCoverTimeSeconds = newTime
                                        seekPlayer(to: newTime)
                                        Task { await updateCoverFramePreview(at: newTime) }
                                    }
                                ),
                                in: minTime...maxTime
                            )
                            .tint(.yellow)
                        }
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(16)
        .modifier(LiquidGlassCardModifier(cornerRadius: 24, tintOpacity: 0.10))
    }

    // MARK: - Anti-Zoom & Core Engine Card

    private var antiZoomAndEngineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("1:1 零缩放与实况引擎调校", systemImage: "wand.and.stars.inverse")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))

                Spacer()

                Button {
                    showsAntiZoomPrincipleSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle.fill")
                        Text("防放大原理")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.cyan.opacity(0.14), in: Capsule())
                }
            }

            // Toggle 1: Force revoke playback zoom
            engineToggleRow(
                icon: "arrow.up.left.and.arrow.down.right.circle.fill",
                iconColor: .cyan,
                title: "强制撤销实况播放默认放大 (1:1 原画比例)",
                subtitle: "写入 QuickTime vitality-disabled 与零过渡分值，阻断 iOS PhotosPlayer 默认的 1.075x 播放缩放动画，与直接播放原视频完全一致。",
                isOn: $disablePlaybackZoom
            )

            Divider()
                .overlay(Color.white.opacity(0.12))

            // Toggle 2: Full frame rate playback intent
            engineToggleRow(
                icon: "gauge.with.dots.needle.67percent",
                iconColor: .green,
                title: "高帧率原速满帧播放 (60fps / 120fps)",
                subtitle: "写入 full-frame-rate-playback-intent 标记，防止系统相册在回放高帧率实况时抽帧降速。",
                isOn: $fullFrameRateIntent
            )

            Divider()
                .overlay(Color.white.opacity(0.12))

            // Toggle 3: Keep original audio
            engineToggleRow(
                icon: includeAudio ? "speaker.wave.3.fill" : "speaker.slash.fill",
                iconColor: includeAudio ? .purple : .gray,
                title: "保留原视频声音",
                subtitle: "AAC 音轨零重编码直通；若原视频为 PCM 等非 AAC 音轨，自动无损重封装视频并智能转码音频。",
                isOn: $includeAudio
            )
        }
        .padding(16)
        .modifier(LiquidGlassCardModifier(cornerRadius: 24, tintOpacity: 0.10))
    }

    private func engineToggleRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(iconColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineSpacing(2)
            }

            Spacer(minLength: 4)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.cyan)
        }
    }

    // MARK: - Bottom Action Deck

    private var bottomActionDeck: some View {
        VStack(spacing: 12) {
            if isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.cyan)
                    Text(workingStatus)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.cyan.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.cyan.opacity(0.45), lineWidth: 1)
                )
            }

            if let feedback {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: feedback.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(feedback.color)

                    Text(feedback.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))

                    Spacer()
                }
                .padding(14)
                .background(feedback.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(feedback.color.opacity(0.45), lineWidth: 1)
                )
            }

            // Primary Convert & Save to Photos button
            Button {
                Task { await convertAndSaveToPhotos() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "livephoto.badge.automatic")
                        .font(.system(size: 19, weight: .bold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("转换并存入系统相册")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Text(disablePlaybackZoom ? "1:1 原画直通 · 已禁用播放放大" : "原画直通 · 标准实况缩放")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .background(
                    LinearGradient(
                        colors: source == nil || isWorking
                            ? [Color.white.opacity(0.10), Color.white.opacity(0.06)]
                            : [Color.cyan.opacity(0.75), Color.blue.opacity(0.70), Color.indigo.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.75), .white.opacity(0.18)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                )
                .shadow(color: source == nil ? .clear : Color.cyan.opacity(0.32), radius: 16, x: 0, y: 8)
                .foregroundStyle(.white.opacity(source == nil || isWorking ? 0.45 : 1.0))
            }
            .disabled(source == nil || isWorking)

            // Secondary actions: In-App Live Photo Preview & Export Raw Pair
            if source != nil {
                HStack(spacing: 10) {
                    Button {
                        Task { await convertForInAppPreviewOnly() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text("生成实况并在 App 内预览")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.9)
                        )
                        .foregroundStyle(.white)
                    }
                    .disabled(isWorking)

                    if let files = generatedFiles {
                        Button {
                            shareItems = [files.photoURL, files.movieURL]
                            showsShareSheet = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("导出配对源文件")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.9)
                            )
                            .foregroundStyle(.white)
                        }
                        .disabled(isWorking)
                    }
                }
            }
        }
    }

    // MARK: - Settings Sheet & Anti-Zoom Technical Sheet

    private var settingsSheetView: some View {
        NavigationStack {
            ZStack {
                LiquidAmbientBackgroundView(
                    palette: currentPalette,
                    isAnimating: dynamicBackgroundMotion,
                    isEnergetic: false
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // Cover Image Format & Aperture
                        VStack(alignment: .leading, spacing: 14) {
                            Label("封面图与画幅采样设置", systemImage: "photo.badge.checkmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("静态封面编码格式")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.8))

                                Picker("静态封面编码格式", selection: $coverFormatRaw) {
                                    ForEach(CoverImageFormat.allCases) { format in
                                        Text(format.title).tag(format.rawValue)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("封面画幅光圈采样模式 (Aperture Mode)")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.8))

                                Picker("画幅光圈模式", selection: $apertureModeRaw) {
                                    ForEach(CoverApertureMode.allCases) { mode in
                                        Text(mode.title).tag(mode.rawValue)
                                    }
                                }
                                .pickerStyle(.segmented)

                                Text("「1:1 编码原始像素」会忽略视频容器中可能存在的 Clean Aperture 裁切框，直接按完整编码像素生成封面，避免封面与视频产生边缘微小缩放差。")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        }
                        .padding(16)
                        .modifier(LiquidGlassCardModifier(cornerRadius: 22, tintOpacity: 0.12))

                        // Liquid Glass & Background Transformation settings
                        VStack(alignment: .leading, spacing: 14) {
                            Label("液态玻璃与流光背景变换", systemImage: "sparkles.rectangle.stack.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("背景流光主题")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.8))

                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                    ForEach(AmbientTheme.allCases) { theme in
                                        let isSelected = ambientTheme == theme
                                        Button {
                                            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                                ambientThemeRaw = theme.rawValue
                                            }
                                        } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: theme.icon)
                                                    .foregroundStyle(isSelected ? .cyan : .white.opacity(0.75))
                                                Text(theme.rawValue)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(.white)
                                                Spacer()
                                                if isSelected {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundStyle(.cyan)
                                                }
                                            }
                                            .padding(12)
                                            .background(
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .fill(isSelected ? Color.cyan.opacity(0.24) : Color.white.opacity(0.08))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .strokeBorder(isSelected ? Color.cyan : Color.white.opacity(0.15), lineWidth: 1)
                                            )
                                        }
                                    }
                                }
                            }

                            Toggle(isOn: $dynamicBackgroundMotion) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("实时流体极光动态变换")
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text("开启后背景色彩场会随时间及视频画面色调进行平滑液态演化。")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.white.opacity(0.65))
                                }
                            }
                            .tint(.cyan)
                        }
                        .padding(16)
                        .modifier(LiquidGlassCardModifier(cornerRadius: 22, tintOpacity: 0.12))
                    }
                    .padding(18)
                }
            }
            .navigationTitle("高级封装与界面设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        showsSettingsSheet = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var antiZoomPrincipleSheetView: some View {
        NavigationStack {
            ZStack {
                LiquidAmbientBackgroundView(
                    palette: currentPalette,
                    isAnimating: false,
                    isEnergetic: false
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("为什么系统相册播放实况照片会默认放大？", systemImage: "magnifyingglass.circle.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.cyan)

                            Text("在 iOS 系统底层框架 PhotosPlayer.framework (ISLivePhotoPlayer._updateScaleIfNeeded) 中，苹果为常规相机拍摄的实况照片硬编码了一个播放缩放逻辑：当长按触发实况回放且 supportsVitality 为 true 时，播放器会在 0.3 秒内将视频画面放大至 1.075 倍（即放大 7.5%），以掩盖相机防抖边缘裁切。")
                                .font(.system(size: 13.5))
                                .foregroundStyle(.white.opacity(0.88))
                                .lineSpacing(4)
                        }
                        .padding(16)
                        .modifier(LiquidGlassCardModifier(cornerRadius: 20, tintOpacity: 0.12))

                        VStack(alignment: .leading, spacing: 10) {
                            Label("本 App 如何从底层强制撤销该放大效果？", systemImage: "checkmark.shield.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.green)

                            Text("1. 注入 QuickTime 级禁用活力缩放标记：\n在配对 MOV 容器层写入 mdta/com.apple.quicktime.live-photo.vitality-disabled = 1 与 transition-vitality-score.v1 = 0.0。当系统相册（PhotosFormats.PFMetadataMovie.hasVitality）读取到该标记时，会将 ISPlayerContent.supportsVitality 设为 false，从而使 ISLivePhotoPlayer 强制保持 scale = 1.0（完全不放大）。\n\n2. 1:1 原始编码像素封面采样：\n使用 AVAssetImageGenerator.ApertureMode.encodedPixels 提取首帧作为静态封面，消除 Clean Aperture 与原始像素尺寸不一致导致的过渡形变。")
                                .font(.system(size: 13.5))
                                .foregroundStyle(.white.opacity(0.88))
                                .lineSpacing(4)
                        }
                        .padding(16)
                        .modifier(LiquidGlassCardModifier(cornerRadius: 20, tintOpacity: 0.12))
                    }
                    .padding(18)
                }
            }
            .navigationTitle("1:1 零缩放技术说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("知道了") {
                        showsAntiZoomPrincipleSheet = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Actions & Helpers

    private func seekPlayer(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @MainActor
    private func updateCoverFramePreview(at seconds: Double) async {
        guard let url = source?.url else { return }
        if let frame = await LivePhotoConverter.extractPreviewFrame(at: url, seconds: seconds, maximumDimension: 480) {
            coverPreviewImage = frame
            withAnimation(.easeInOut(duration: 0.45)) {
                activeAmbientPalette = LivePhotoConverter.extractAmbientPalette(from: frame)
            }
        }
    }

    @MainActor
    private func finishImport(_ result: Result<ImportedVideo, Error>) async {
        showsPhotoPicker = false
        switch result {
        case .success(let imported):
            workingStatus = "正在解析视频编码、画幅与流光色彩…"
            do {
                let spec = try await LivePhotoConverter.inspectVideo(at: imported.url)
                player?.pause()
                player?.replaceCurrentItem(with: nil)
                cleanupGeneratedFiles()
                source?.remove()

                source = imported
                specification = spec
                player = AVPlayer(url: imported.url)
                stageMode = .video
                durationPreset = .full
                trimStartSeconds = 0.0
                trimEndSeconds = spec.durationSeconds
                useCustomCoverTime = false
                customCoverTimeSeconds = 0.0
                coverPreviewImage = spec.thumbnails.first
                withAnimation(.easeInOut(duration: 0.6)) {
                    activeAmbientPalette = spec.ambientPalette
                }
                isWorking = false
            } catch {
                imported.remove()
                isWorking = false
                feedback = .error("无法解析所选视频：\(error.localizedDescription)")
            }
        case .failure(let error):
            isWorking = false
            feedback = .error("无法导入视频：\(error.localizedDescription)")
        }
    }

    @MainActor
    private func convertForInAppPreviewOnly() async {
        guard let source, !isWorking else { return }
        isWorking = true
        workingStatus = "正在无损封装 1:1 实况资源对…"
        feedback = nil
        player?.pause()
        defer { isWorking = false }

        do {
            let directory = try makeTemporaryDirectory()
            let files = try await LivePhotoConverter.convert(
                source.url,
                into: directory,
                options: currentConversionOptions
            )
            cleanupGeneratedFiles()
            generatedFiles = files

            if let livePhoto = await loadPHLivePhoto(from: files) {
                generatedLivePhoto = livePhoto
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    stageMode = .livePhoto
                }
                feedback = .success("实况预览已就绪！可直接在上方长按画面测试 1:1 无放大播放。")
            } else {
                feedback = .success("实况配对文件已生成，可点击「导出配对源文件」或直接存入相册。")
            }
        } catch {
            feedback = .error("生成实况预览失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private func convertAndSaveToPhotos() async {
        guard let source, !isWorking else { return }
        isWorking = true
        workingStatus = "正在无损直通封装并写入系统相册…"
        feedback = nil
        player?.pause()
        defer { isWorking = false }

        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                feedback = .error("请在 iPhone「设置 → 隐私与安全性 → 照片」中允许本 App 添加照片。")
                return
            }

            let directory = try makeTemporaryDirectory()
            let result = try await LivePhotoConverter.convert(
                source.url,
                into: directory,
                options: currentConversionOptions
            )
            cleanupGeneratedFiles()
            generatedFiles = result

            let photoURL = result.photoURL
            let movieURL = result.movieURL
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: photoURL, options: nil)
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: nil)
            }

            if let livePhoto = await loadPHLivePhoto(from: result) {
                generatedLivePhoto = livePhoto
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    stageMode = .livePhoto
                }
            }

            let durationDesc = String(format: "%.2fs", result.outputDurationSeconds)
            let zoomDesc = disablePlaybackZoom ? "1:1 零放大" : "标准缩放"
            feedback = .success("已存入系统相册（时长 \(durationDesc) · \(zoomDesc)），可在「照片 → 实况照片」中查看！")
        } catch {
            feedback = .error("转换或保存失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private func loadPHLivePhoto(from files: LivePhotoFiles) async -> PHLivePhoto? {
        await withCheckedContinuation { continuation in
            var didResume = false
            PHLivePhoto.request(
                withResourceFileURLs: [files.photoURL, files.movieURL],
                placeholderImage: nil,
                targetSize: .zero,
                contentMode: .aspectFit
            ) { livePhoto, info in
                let isDegraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: livePhoto)
            }
        }
    }

    private func cleanupGeneratedFiles() {
        if let old = generatedFiles {
            try? FileManager.default.removeItem(at: old.photoURL.deletingLastPathComponent())
            generatedFiles = nil
        }
        generatedLivePhoto = nil
    }

    private struct Feedback {
        let text: String
        let icon: String
        let color: Color

        static func success(_ text: String) -> Self {
            Self(text: text, icon: "checkmark.seal.fill", color: .cyan)
        }

        static func error(_ text: String) -> Self {
            Self(text: text, icon: "exclamationmark.triangle.fill", color: .red)
        }
    }
}

// MARK: - Dynamic Liquid Ambient Background View

private struct LiquidAmbientBackgroundView: View {
    let palette: [RGBAColor]
    let isAnimating: Bool
    let isEnergetic: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate * (isEnergetic ? 1.8 : 0.55)
            Canvas { context, size in
                let baseRect = CGRect(origin: .zero, size: size)
                context.fill(
                    Path(baseRect),
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.03, green: 0.04, blue: 0.09),
                            Color(red: 0.05, green: 0.05, blue: 0.12),
                            Color(red: 0.02, green: 0.03, blue: 0.07)
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: size.height)
                    )
                )

                let maxDim = max(size.width, size.height)
                for index in 0..<palette.count {
                    let color = palette[index]
                    let phase = Double(index) * 1.57 + t
                    let cx = size.width * (0.5 + 0.34 * cos(phase * 0.73 + Double(index)))
                    let cy = size.height * (0.45 + 0.36 * sin(phase * 0.61 + Double(index) * 0.8))
                    let radius = maxDim * (0.48 + 0.08 * sin(phase * 1.1))
                    let center = CGPoint(x: cx, y: cy)

                    let orbColor = Color(red: color.r, green: color.g, blue: color.b)
                    let gradient = Gradient(stops: [
                        .init(color: orbColor.opacity(0.62), location: 0.0),
                        .init(color: orbColor.opacity(0.28), location: 0.45),
                        .init(color: orbColor.opacity(0.0), location: 1.0)
                    ])
                    context.drawLayer { layer in
                        layer.blendMode = .plusLighter
                        layer.fill(
                            Path(ellipseIn: CGRect(
                                x: center.x - radius,
                                y: center.y - radius,
                                width: radius * 2,
                                height: radius * 2
                            )),
                            with: .radialGradient(
                                gradient,
                                center: center,
                                startRadius: 0,
                                endRadius: radius
                            )
                        )
                    }
                }

                // Liquid caustic specular ribbon
                let ribbonY = size.height * (0.32 + 0.12 * sin(t * 0.5))
                var ribbon = Path()
                ribbon.move(to: CGPoint(x: 0, y: ribbonY))
                ribbon.addCurve(
                    to: CGPoint(x: size.width, y: ribbonY + 60 * cos(t * 0.4)),
                    control1: CGPoint(x: size.width * 0.33, y: ribbonY - 90 * sin(t * 0.6)),
                    control2: CGPoint(x: size.width * 0.66, y: ribbonY + 90 * cos(t * 0.5))
                )
                context.stroke(
                    ribbon,
                    with: .linearGradient(
                        Gradient(colors: [
                            .white.opacity(0.0),
                            .white.opacity(0.10),
                            .cyan.opacity(0.14),
                            .white.opacity(0.0)
                        ]),
                        startPoint: CGPoint(x: 0, y: ribbonY),
                        endPoint: CGPoint(x: size.width, y: ribbonY)
                    ),
                    lineWidth: 70
                )
            }
        }
    }
}

// MARK: - Liquid Glass ViewModifiers

private struct LiquidGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tintOpacity: Double

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(tintOpacity * 1.4),
                                    Color.white.opacity(tintOpacity * 0.35),
                                    Color.cyan.opacity(tintOpacity * 0.45)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.55), location: 0.0),
                                .init(color: .white.opacity(0.14), location: 0.45),
                                .init(color: .cyan.opacity(0.28), location: 0.8),
                                .init(color: .white.opacity(0.32), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.1
                    )
            )
            .shadow(color: Color.black.opacity(0.28), radius: 20, x: 0, y: 10)
    }
}

private struct LiquidGlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.6), .white.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Native PHLivePhotoView Wrapper

private struct LivePhotoPreviewView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let isMuted: Bool
    let playbackTrigger: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.backgroundColor = .clear
        view.livePhoto = livePhoto
        view.isMuted = isMuted
        return view
    }

    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {
        if uiView.livePhoto !== livePhoto {
            uiView.livePhoto = livePhoto
        }
        uiView.isMuted = isMuted
        if context.coordinator.lastPlaybackTrigger != playbackTrigger {
            context.coordinator.lastPlaybackTrigger = playbackTrigger
            uiView.startPlayback(with: .full)
        }
    }

    final class Coordinator {
        var lastPlaybackTrigger = 0
    }
}

// MARK: - Share Sheet Wrapper

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Video Picker & File Import

private struct VideoPhotoPicker: UIViewControllerRepresentable {
    let didStart: @MainActor () -> Void
    let didFinish: @MainActor (Result<ImportedVideo, Error>) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .videos
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: VideoPhotoPicker

        init(parent: VideoPhotoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                parent.dismiss()
                return
            }
            parent.didStart()

            let movieType = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .movie) == true
            } ?? UTType.movie.identifier
            let name = provider.suggestedName
            let didFinish = parent.didFinish
            provider.loadFileRepresentation(forTypeIdentifier: movieType) { url, error in
                // The provider may delete its staged file as soon as this callback returns.
                let result = Result {
                    guard let url else { throw error ?? ImportError.noFile }
                    return try ImportedVideo.copy(at: url, name: name, fallbackType: UTType(movieType))
                }
                Task { @MainActor in didFinish(result) }
            }
        }
    }
}

private struct ImportedVideo: Sendable {
    let url: URL
    let name: String

    static func copy(at url: URL, name: String?, fallbackType: UTType? = nil) throws -> Self {
        let directory = try makeTemporaryDirectory()
        let fileExtension = url.pathExtension.isEmpty
            ? (fallbackType?.preferredFilenameExtension ?? "")
            : url.pathExtension
        let base = directory.appendingPathComponent("source", isDirectory: false)
        let destination = fileExtension.isEmpty ? base : base.appendingPathExtension(fileExtension)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return Self(url: destination, name: name ?? url.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func copyCoordinatedFile(at url: URL) throws -> Self {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var copyResult: Result<Self, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { localURL in
            copyResult = Result { try copy(at: localURL, name: url.lastPathComponent) }
        }
        if let copyResult { return try copyResult.get() }
        if let coordinationError { throw coordinationError }
        throw ImportError.noFile
    }

    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

private enum ImportError: LocalizedError {
    case noFile

    var errorDescription: String? { "所选项目没有提供可读取的视频文件。" }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LivePhotoPreserve-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}
