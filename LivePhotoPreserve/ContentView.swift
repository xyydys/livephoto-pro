import AVFoundation
import AVKit
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Design Tokens

/// "暗房 Studio" design language: graphite darkroom canvas, a single warm Live-yellow accent,
/// native Liquid Glass surfaces (iOS 26) with a material fallback on iOS 17/18.
private enum Studio {
    static let accent = Color(red: 1.0, green: 0.80, blue: 0.26)
    static let positive = Color(red: 0.42, green: 0.90, blue: 0.62)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.30)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.36)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.42)
    static let hairline = Color.white.opacity(0.10)
    static let maxContentWidth: CGFloat = 620
}

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

    var caption: String {
        switch self {
        case .adaptive: return "从当前画面提取色彩"
        case .aurora: return "深蓝与紫罗兰"
        case .solar: return "暖橙与玫瑰金"
        case .frost: return "冷调冰蓝"
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

    var icon: String? {
        switch self {
        case .full: return "infinity"
        case .custom: return "scissors"
        default: return nil
        }
    }
}

enum PreviewStageMode: String, CaseIterable, Identifiable {
    case video = "原片"
    case livePhoto = "实况"

    var id: String { rawValue }
}

private enum InspectorTab: String, CaseIterable, Identifiable {
    case trim = "剪辑"
    case cover = "封面"
    case engine = "引擎"
    case info = "信息"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .trim: return "timeline.selection"
        case .cover: return "photo.on.rectangle"
        case .engine: return "dial.medium"
        case .info: return "info.circle"
        }
    }
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
    @State private var inspectorTab: InspectorTab = .trim
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

    /// The trim window as drawn on the timeline (never nil).
    private var displayedRange: ClosedRange<Double> {
        let total = max(0.1, specification?.durationSeconds ?? 0.1)
        return effectiveTrimRange ?? 0.0...total
    }

    private var effectiveOutputDuration: Double {
        guard let spec = specification else { return 0 }
        if let range = effectiveTrimRange {
            return max(0.1, range.upperBound - range.lowerBound)
        }
        return spec.durationSeconds
    }

    private var displayedCoverTime: Double {
        let range = displayedRange
        guard useCustomCoverTime else { return range.lowerBound }
        return min(max(customCoverTimeSeconds, range.lowerBound), range.upperBound)
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
            StudioBackdrop(
                palette: currentPalette,
                isAnimating: dynamicBackgroundMotion,
                isEnergetic: isWorking
            )
            .ignoresSafeArea()

            if let spec = specification, let source, let player {
                studioWorkspace(spec: spec, source: source, player: player)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                welcomeView
                    .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionDock
        }
        .animation(.smooth(duration: 0.45), value: source?.url)
        .preferredColorScheme(.dark)
        .tint(Studio.accent)
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
            .ignoresSafeArea()
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
            settingsSheet
        }
        .sheet(isPresented: $showsAntiZoomPrincipleSheet) {
            NavigationStack {
                AntiZoomExplainer()
                    .navigationTitle("1:1 零缩放原理")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showsAntiZoomPrincipleSheet = false }
                                .fontWeight(.semibold)
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showsShareSheet) {
            ActivityShareSheet(activityItems: shareItems)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: stageMode) { _, mode in
            if mode == .livePhoto {
                player?.pause()
            }
        }
        .onDisappear {
            player?.pause()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                LiveGlyph(size: 30, isActive: isWorking)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("实况原画")
                            .font(.system(size: 18, weight: .bold))
                        Text("STUDIO")
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(Studio.accent)
                    }
                    Text(disablePlaybackZoom ? "无损直通 · 1:1 零缩放" : "无损直通 · 系统默认缩放")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Studio.secondaryText)
                        .contentTransition(.opacity)
                }
            }
            .foregroundStyle(.white)

            Spacer(minLength: 8)

            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    if source != nil {
                        Menu {
                            importMenuItems
                        } label: {
                            CircleGlassIcon(systemName: "plus")
                        }
                        .disabled(isWorking)
                        .accessibilityLabel("更换视频")
                    }

                    Menu {
                        Picker("流光主题", selection: $ambientThemeRaw) {
                            ForEach(AmbientTheme.allCases) { theme in
                                Label(theme.rawValue, systemImage: theme.icon).tag(theme.rawValue)
                            }
                        }
                        Divider()
                        Toggle(isOn: $dynamicBackgroundMotion) {
                            Label("背景流动", systemImage: "wind")
                        }
                    } label: {
                        CircleGlassIcon(systemName: ambientTheme.icon)
                    }
                    .accessibilityLabel("流光主题")

                    Button {
                        showsSettingsSheet = true
                    } label: {
                        CircleGlassIcon(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("设置")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: Studio.maxContentWidth + 40)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var importMenuItems: some View {
        Button {
            showsPhotoPicker = true
        } label: {
            Label("从相册选择", systemImage: "photo.on.rectangle.angled")
        }
        Button {
            showsFilePicker = true
        } label: {
            Label("从文件导入", systemImage: "folder")
        }
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                LiveRingsHero()
                    .frame(width: 128, height: 128)
                    .padding(.top, 28)

                VStack(alignment: .leading, spacing: 14) {
                    Text("LIVE PHOTO · LOSSLESS")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .tracking(2.2)
                        .foregroundStyle(Studio.accent)

                    Text("把视频\n冲洗成实况。")
                        .font(.system(size: 42, weight: .heavy))
                        .tracking(-0.5)
                        .lineSpacing(2)
                        .foregroundStyle(.white)

                    Text("原视频 H.264 / HEVC 压缩样本比特级直通封装，不重编码、不降画质；任意时长，长按播放不放大。")
                        .font(.system(size: 15))
                        .foregroundStyle(Studio.secondaryText)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    featureRow(
                        index: "01",
                        title: "1:1 零放大播放",
                        detail: "注入 vitality-disabled 元数据，长按时画面不再推进 7.5%。"
                    )
                    Rectangle().fill(Studio.hairline).frame(height: 0.5).padding(.leading, 62)
                    featureRow(
                        index: "02",
                        title: "突破 3 秒限制",
                        detail: "完整全长、3 / 5 / 10 秒预设，或拖动手柄自由截取。"
                    )
                    Rectangle().fill(Studio.hairline).frame(height: 0.5).padding(.leading, 62)
                    featureRow(
                        index: "03",
                        title: "任意封面帧",
                        detail: "默认首帧零跳帧，也可逐帧挑选 Key Photo。"
                    )
                }
                .padding(.vertical, 6)
                .studioGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))

                VStack(spacing: 12) {
                    Button {
                        showsPhotoPicker = true
                    } label: {
                        Label("从相册选择视频", systemImage: "photo.on.rectangle.angled")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .prominentGlassButton()

                    Button {
                        showsFilePicker = true
                    } label: {
                        Label("从文件导入原片", systemImage: "folder")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .regularGlassButton()
                }
                .controlSize(.large)
                .disabled(isWorking)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: Studio.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func featureRow(index: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(index)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Studio.accent)
                .frame(width: 30, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Studio.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Studio Workspace

    private func studioWorkspace(spec: VideoSpecification, source: ImportedVideo, player: AVPlayer) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 22) {
                stage(spec: spec, source: source, player: player)

                GlassSegmented(
                    items: InspectorTab.allCases,
                    selection: $inspectorTab,
                    title: { $0.rawValue },
                    icon: { $0.icon }
                )

                Group {
                    switch inspectorTab {
                    case .trim: trimPanel(spec)
                    case .cover: coverPanel(spec)
                    case .engine: enginePanel
                    case .info: infoPanel(spec)
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 10)),
                    removal: .opacity
                ))
                .animation(.snappy(duration: 0.32), value: inspectorTab)
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: Studio.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: Stage

    private func stageAspect(_ spec: VideoSpecification) -> CGFloat {
        let size = spec.naturalSize
        guard size.width > 0, size.height > 0 else { return 16.0 / 9.0 }
        return max(0.8, min(size.width / size.height, 1.85))
    }

    private func stage(spec: VideoSpecification, source: ImportedVideo, player: AVPlayer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Color.black
                if stageMode == .livePhoto, let livePhoto = generatedLivePhoto {
                    LivePhotoPreviewView(
                        livePhoto: livePhoto,
                        isMuted: !includeAudio,
                        playbackTrigger: livePhotoPlaybackTrigger
                    )
                    .transition(.opacity)
                } else {
                    VideoPlayer(player: player)
                        .accessibilityLabel("原视频预览")
                        .transition(.opacity)
                }
            }
            .aspectRatio(stageAspect(spec), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
            .overlay(alignment: .topLeading) {
                liveBadge
                    .padding(12)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if generatedLivePhoto != nil {
                    GlassSegmented(
                        items: PreviewStageMode.allCases,
                        selection: $stageMode,
                        title: { $0.rawValue },
                        compact: true
                    )
                    .padding(10)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if stageMode == .livePhoto, generatedLivePhoto != nil {
                    Button {
                        livePhotoPlaybackTrigger += 1
                    } label: {
                        Label("播放", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .regularGlassButton()
                    .padding(12)
                    .transition(.opacity)
                }
            }
            .animation(.snappy, value: stageMode)
            .animation(.snappy, value: generatedLivePhoto != nil)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(stageMetaLine(spec))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Studio.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                StatusPill(
                    text: spec.isPassthroughCompatible ? "可直通" : "非标准编码",
                    color: spec.isPassthroughCompatible ? Studio.positive : Studio.warning
                )
            }
            .padding(.horizontal, 6)

            if stageMode == .livePhoto, generatedLivePhoto != nil {
                Label("在画面上长按，检验播放是否保持 1:1", systemImage: "hand.point.up.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Studio.secondaryText)
                    .padding(.horizontal, 6)
                    .transition(.opacity)
            }
        }
    }

    private func stageMetaLine(_ spec: VideoSpecification) -> String {
        "\(spec.resolutionTier) · \(spec.codecName) · \(spec.frameRateText) · " + String(format: "%.1fs", spec.durationSeconds)
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "livephoto")
                .font(.system(size: 12, weight: .bold))
            Text("LIVE")
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.2)
            if effectiveOutputDuration > 3.05 {
                Text(String(format: "%.1fs", effectiveOutputDuration))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .contentTransition(.numericText())
            }
            if disablePlaybackZoom {
                Text("1:1")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Studio.accent, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(.black)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .studioGlass(Capsule())
        .animation(.snappy, value: effectiveOutputDuration)
    }

    // MARK: Trim Panel

    private func trimPanel(_ spec: VideoSpecification) -> some View {
        InspectorCard(title: "时长截取", subtitle: "已解除 3 秒上限") {
            Text(String(format: "%.2fs", effectiveOutputDuration))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Studio.accent)
                .contentTransition(.numericText())
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                if !spec.thumbnails.isEmpty {
                    FilmstripTrimmer(
                        thumbnails: spec.thumbnails,
                        duration: spec.durationSeconds,
                        range: displayedRange,
                        coverTime: displayedCoverTime,
                        isEnabled: spec.durationSeconds > 0.3 && !isWorking,
                        onChange: { handle, seconds in
                            moveTrimHandle(handle, to: seconds, total: spec.durationSeconds)
                        }
                    )
                    .padding(.top, 4)
                }

                HStack {
                    timeReadout(label: "起点", seconds: displayedRange.lowerBound, alignment: .leading)
                    Spacer()
                    timeReadout(label: "时长", seconds: effectiveOutputDuration, alignment: .center, highlighted: true)
                    Spacer()
                    timeReadout(label: "终点", seconds: displayedRange.upperBound, alignment: .trailing)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DurationPreset.allCases) { preset in
                            presetChip(preset, total: spec.durationSeconds)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()

                Label("拖动胶片两端的手柄可自由截取区间", systemImage: "hand.draw")
                    .font(.system(size: 12))
                    .foregroundStyle(Studio.tertiaryText)
            }
        }
    }

    private func timeReadout(label: String, seconds: Double, alignment: HorizontalAlignment, highlighted: Bool = false) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Studio.tertiaryText)
            Text(String(format: "%.2f", seconds))
                .font(.system(size: highlighted ? 22 : 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(highlighted ? Studio.accent : .white)
                .contentTransition(.numericText())
        }
    }

    private func presetChip(_ preset: DurationPreset, total: Double) -> some View {
        let isSelected = durationPreset == preset
        return Button {
            applyPreset(preset, total: total)
        } label: {
            HStack(spacing: 5) {
                if let icon = preset.icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                }
                Text(preset.rawValue)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    Capsule().fill(Studio.accent)
                } else {
                    Capsule().fill(Color.white.opacity(0.07))
                }
            }
            .overlay(Capsule().strokeBorder(Color.white.opacity(isSelected ? 0 : 0.12), lineWidth: 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .sensoryFeedback(.selection, trigger: isSelected)
    }

    // MARK: Cover Panel

    private func coverPanel(_ spec: VideoSpecification) -> some View {
        InspectorCard(title: "封面帧", subtitle: "Key Photo") {
            Text(coverFormat.rawValue)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8))
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                coverPreview(spec)

                GlassSegmented(
                    items: [false, true],
                    selection: $useCustomCoverTime,
                    title: { $0 ? "自选帧" : "片段首帧" },
                    icon: { $0 ? "hand.tap" : "backward.end" }
                )
                .onChange(of: useCustomCoverTime) { _, isCustom in
                    let start = displayedRange.lowerBound
                    if isCustom {
                        customCoverTimeSeconds = start
                    }
                    Task { await updateCoverFramePreview(at: start) }
                }

                if useCustomCoverTime, !spec.thumbnails.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        CoverScrubber(
                            thumbnails: spec.thumbnails,
                            duration: spec.durationSeconds,
                            range: displayedRange,
                            time: displayedCoverTime,
                            onScrub: { setCoverTime($0) }
                        )

                        HStack(spacing: 10) {
                            frameStepButton(systemName: "chevron.left", delta: -1, spec: spec)
                            Spacer()
                            Text(String(format: "%.3f s", displayedCoverTime))
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Studio.accent)
                                .contentTransition(.numericText())
                            Spacer()
                            frameStepButton(systemName: "chevron.right", delta: 1, spec: spec)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Button {
                    showsSettingsSheet = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.badge.checkmark")
                            .foregroundStyle(Studio.accent)
                        Text("封面编码与采样")
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(coverFormat.rawValue) · \(apertureMode == .encodedPixels ? "1:1 像素" : "Clean Aperture")")
                            .foregroundStyle(Studio.secondaryText)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Studio.tertiaryText)
                    }
                    .font(.system(size: 13.5, weight: .medium))
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .animation(.snappy(duration: 0.3), value: useCustomCoverTime)
        }
    }

    private func coverPreview(_ spec: VideoSpecification) -> some View {
        let image = coverPreviewImage ?? spec.thumbnails.first
        return ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(uiImage: UIImage(cgImage: image))
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.05)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(useCustomCoverTime ? "自选封面" : "首帧封面")
                        .font(.system(size: 15, weight: .bold))
                    Text(useCustomCoverTime
                         ? String(format: "取自 %.2fs 处画面", displayedCoverTime)
                         : "封面与播放首帧一致，零跳帧")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                Image(systemName: "key.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 26, height: 26)
                    .background(Studio.accent, in: Circle())
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
        )
    }

    private func frameStepButton(systemName: String, delta: Double, spec: VideoSpecification) -> some View {
        Button {
            let step = 1.0 / max(1.0, spec.nominalFrameRate)
            setCoverTime(displayedCoverTime + delta * step)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
        }
        .regularGlassButton()
        .accessibilityLabel(delta < 0 ? "上一帧" : "下一帧")
    }

    // MARK: Engine Panel

    private var enginePanel: some View {
        InspectorCard(title: "实况引擎", subtitle: "封装元数据调校") {
            Button {
                showsAntiZoomPrincipleSheet = true
            } label: {
                Label("原理", systemImage: "questionmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Studio.accent)
            }
            .buttonStyle(.plain)
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                ZoomGauge(isZoomDisabled: disablePlaybackZoom)

                VStack(spacing: 0) {
                    EngineToggleRow(
                        icon: "arrow.up.left.and.arrow.down.right",
                        tint: Studio.accent,
                        title: "撤销播放放大",
                        detail: "写入 vitality-disabled 与零过渡分值，长按播放保持 1:1。",
                        isOn: $disablePlaybackZoom
                    )
                    Rectangle().fill(Studio.hairline).frame(height: 0.5).padding(.leading, 52)
                    EngineToggleRow(
                        icon: "gauge.with.dots.needle.67percent",
                        tint: Studio.positive,
                        title: "满帧率播放",
                        detail: "写入 full-frame-rate-playback-intent，60 / 120fps 不抽帧。",
                        isOn: $fullFrameRateIntent
                    )
                    Rectangle().fill(Studio.hairline).frame(height: 0.5).padding(.leading, 52)
                    EngineToggleRow(
                        icon: includeAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                        tint: Color(red: 0.72, green: 0.58, blue: 1.0),
                        title: "保留原声",
                        detail: "AAC 零重编码直通；PCM 等自动转为高码率 AAC-LC。",
                        isOn: $includeAudio
                    )
                }
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    // MARK: Info Panel

    private func infoPanel(_ spec: VideoSpecification) -> some View {
        InspectorCard(title: "原片诊断", subtitle: "编码 · 画幅 · 色彩") {
            StatusPill(
                text: spec.isPassthroughCompatible ? "零重编码" : "需注意",
                color: spec.isPassthroughCompatible ? Studio.positive : Studio.warning
            )
        } content: {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                SpecCell(icon: "viewfinder", label: "分辨率", value: spec.resolutionText, detail: spec.resolutionTier)
                SpecCell(icon: "film", label: "视频编码", value: spec.codecName, detail: spec.isPassthroughCompatible ? "支持比特直通" : "不支持直通")
                SpecCell(icon: spec.isHDR ? "sun.max" : "circle.lefthalf.filled", label: "色彩", value: spec.isHDR ? "HDR" : "SDR", detail: spec.colorSpaceLabel)
                SpecCell(icon: "speedometer", label: "帧率", value: spec.frameRateText, detail: "约 \(spec.totalFramesEstimate) 帧")
                SpecCell(icon: "clock", label: "时长", value: String(format: "%.2f s", spec.durationSeconds), detail: String(format: "输出 %.2f s", effectiveOutputDuration))
                SpecCell(icon: "waveform.path.ecg", label: "码率", value: String(format: "%.1f Mbps", spec.estimatedBitrateMbps), detail: spec.fileSizeText)
            }

            HStack(spacing: 10) {
                Image(systemName: spec.hasAudio ? "speaker.wave.2" : "speaker.slash")
                    .foregroundStyle(Studio.accent)
                    .frame(width: 20)
                Text("音轨")
                    .foregroundStyle(Studio.secondaryText)
                Spacer()
                Text(spec.audioSummary)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 10)
        }
    }

    // MARK: - Action Dock

    private var actionDock: some View {
        VStack(spacing: 10) {
            statusBanner

            if source != nil {
                GlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            Task { await convertForInAppPreviewOnly() }
                        } label: {
                            Image(systemName: "livephoto.play")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 34)
                        }
                        .regularGlassButton()
                        .accessibilityLabel("生成实况并在 App 内预览")

                        Button {
                            Task { await convertAndSaveToPhotos() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "square.and.arrow.down.fill")
                                    .font(.system(size: 17, weight: .bold))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("存入相册")
                                        .font(.system(size: 16, weight: .bold))
                                    Text(disablePlaybackZoom ? "1:1 原画直通" : "原画直通 · 标准缩放")
                                        .font(.system(size: 11, weight: .medium))
                                        .opacity(0.7)
                                }
                                Spacer(minLength: 4)
                                Text(String(format: "%.1fs", effectiveOutputDuration))
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .contentTransition(.numericText())
                            }
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                        }
                        .prominentGlassButton()

                        if let files = generatedFiles {
                            Button {
                                shareItems = [files.photoURL, files.movieURL]
                                showsShareSheet = true
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 34)
                            }
                            .regularGlassButton()
                            .accessibilityLabel("导出配对源文件")
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .controlSize(.large)
                    .disabled(isWorking)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: Studio.maxContentWidth + 20)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.35), value: isWorking)
        .animation(.snappy(duration: 0.35), value: feedback?.text)
        .animation(.snappy(duration: 0.35), value: generatedFiles?.identifier)
    }

    @ViewBuilder
    private var statusBanner: some View {
        if isWorking {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(Studio.accent)
                Text(workingStatus)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .studioGlass(Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let feedback {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: feedback.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(feedback.color)
                Text(feedback.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    self.feedback = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Studio.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
            .padding(16)
            .studioGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: feedback.color.opacity(0.14))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("封面编码格式", selection: $coverFormatRaw) {
                        ForEach(CoverImageFormat.allCases) { format in
                            Text(format.title).tag(format.rawValue)
                        }
                    }
                    Picker("画幅采样", selection: $apertureModeRaw) {
                        ForEach(CoverApertureMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                } header: {
                    Text("封面")
                } footer: {
                    Text("「1:1 编码原始像素」忽略容器中的 Clean Aperture 裁切框，按完整编码像素生成封面，避免封面与视频之间的边缘微缩放。")
                }

                Section {
                    ForEach(AmbientTheme.allCases) { theme in
                        Button {
                            withAnimation(.smooth) { ambientThemeRaw = theme.rawValue }
                        } label: {
                            themeRow(theme)
                        }
                        .buttonStyle(.plain)
                    }
                    Toggle(isOn: $dynamicBackgroundMotion) {
                        Label("背景流动", systemImage: "wind")
                    }
                } header: {
                    Text("流光背景")
                } footer: {
                    Text("开启后背景色彩场会随时间与画面色调平滑演化；转换时流速会加快。")
                }

                Section {
                    NavigationLink {
                        AntiZoomExplainer()
                            .navigationTitle("1:1 零缩放原理")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("1:1 零缩放原理", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    LabeledContent("版本", value: appVersion)
                } header: {
                    Text("关于")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showsSettingsSheet = false }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Studio.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func themeRow(_ theme: AmbientTheme) -> some View {
        let colors = theme.palette(videoPalette: theme == .adaptive ? (activeAmbientPalette ?? specification?.ambientPalette) : nil)
        return HStack(spacing: 14) {
            HStack(spacing: -6) {
                ForEach(0..<colors.count, id: \.self) { index in
                    let c = colors[index]
                    Circle()
                        .fill(Color(red: c.r, green: c.g, blue: c.b))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.rawValue)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                Text(theme.caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Studio.secondaryText)
            }
            Spacer()
            if ambientTheme == theme {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Studio.accent)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Timeline Helpers

    private func applyPreset(_ preset: DurationPreset, total: Double) {
        withAnimation(.snappy(duration: 0.3)) {
            durationPreset = preset
            switch preset {
            case .full:
                trimStartSeconds = 0.0
                trimEndSeconds = total
            case .threeSeconds, .fiveSeconds, .tenSeconds:
                trimStartSeconds = 0.0
                trimEndSeconds = min(preset.maxSeconds ?? total, total)
            case .custom:
                if trimEndSeconds <= trimStartSeconds {
                    trimStartSeconds = 0.0
                    trimEndSeconds = total
                }
            }
        }
        seekPlayer(to: displayedRange.lowerBound)
    }

    private func moveTrimHandle(_ handle: FilmstripTrimmer.Handle, to seconds: Double, total: Double) {
        if durationPreset != .custom {
            let current = displayedRange
            trimStartSeconds = current.lowerBound
            trimEndSeconds = current.upperBound
            durationPreset = .custom
        }
        let minimumGap = 0.2
        switch handle {
        case .lower:
            trimStartSeconds = max(0.0, min(seconds, trimEndSeconds - minimumGap))
            seekPlayer(to: trimStartSeconds)
        case .upper:
            trimEndSeconds = min(total, max(seconds, trimStartSeconds + minimumGap))
            seekPlayer(to: trimEndSeconds)
        }
    }

    private func setCoverTime(_ seconds: Double) {
        let range = displayedRange
        let upper = max(range.lowerBound, range.upperBound - 0.02)
        let clamped = min(max(seconds, range.lowerBound), upper)
        customCoverTimeSeconds = clamped
        seekPlayer(to: clamped)
        Task { await updateCoverFramePreview(at: clamped) }
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
                inspectorTab = .trim
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
                feedback = .success("实况预览已就绪，在上方画面长按即可检验 1:1 播放。")
            } else {
                feedback = .success("实况配对文件已生成，可导出源文件或直接存入相册。")
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
                feedback = .error("请在「设置 → 隐私与安全性 → 照片」中允许本 App 添加照片。")
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
            feedback = .success("已存入系统相册 · \(durationDesc) · \(zoomDesc)")
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
            Self(text: text, icon: "checkmark.circle.fill", color: Studio.positive)
        }

        static func error(_ text: String) -> Self {
            Self(text: text, icon: "exclamationmark.triangle.fill", color: Studio.danger)
        }
    }
}

// MARK: - Liquid Glass Abstractions

private extension View {
    /// Native Liquid Glass on iOS 26 (Xcode 26 SDK); translucent material fallback elsewhere.
    @ViewBuilder
    func studioGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let base: Glass = tint.map { Glass.regular.tint($0) } ?? Glass.regular
            self.glassEffect(base.interactive(interactive), in: shape)
        } else {
            self.modifier(FallbackGlassModifier(shape: shape, tint: tint))
        }
        #else
        self.modifier(FallbackGlassModifier(shape: shape, tint: tint))
        #endif
    }

    @ViewBuilder
    func prominentGlassButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(Studio.accent)
        } else {
            self.buttonStyle(FallbackCapsuleButtonStyle(isProminent: true))
        }
        #else
        self.buttonStyle(FallbackCapsuleButtonStyle(isProminent: true))
        #endif
    }

    @ViewBuilder
    func regularGlassButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(FallbackCapsuleButtonStyle(isProminent: false))
        }
        #else
        self.buttonStyle(FallbackCapsuleButtonStyle(isProminent: false))
        #endif
    }
}

/// Groups neighbouring glass shapes so they blend and morph together on iOS 26.
private struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct FallbackGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(tint ?? Color.white.opacity(0.04))
                }
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.white.opacity(0.06), Color.white.opacity(0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            }
            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }
}

private struct FallbackCapsuleButtonStyle: ButtonStyle {
    let isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                if isProminent {
                    Capsule().fill(Studio.accent)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay(Capsule().strokeBorder(Color.white.opacity(isProminent ? 0.35 : 0.18), lineWidth: 0.8))
            .opacity(isEnabled ? 1.0 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Reusable Components

private struct CircleGlassIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .contentShape(Circle())
            .studioGlass(Circle(), interactive: true)
    }
}

private struct GlassSegmented<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    var icon: ((Item) -> String)? = nil
    var compact: Bool = false

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                segment(item)
            }
        }
        .padding(4)
        .studioGlass(Capsule())
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func segment(_ item: Item) -> some View {
        let isSelected = item == selection
        return Button {
            withAnimation(.snappy(duration: 0.3)) {
                selection = item
            }
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon(item))
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                }
                Text(title(item))
                    .font(.system(size: compact ? 12 : 13.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.78))
            .padding(.horizontal, compact ? 11 : 10)
            .padding(.vertical, compact ? 6 : 10)
            .frame(maxWidth: compact ? nil : .infinity)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Studio.accent)
                        .matchedGeometryEffect(id: "segment", in: namespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct InspectorCard<Trailing: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Studio.tertiaryText)
                }
                Spacer()
                trailing
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
        }
        .padding(20)
        .studioGlass(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color, radius: 4)
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

private struct SpecCell: View {
    let icon: String
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Studio.accent)
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Studio.tertiaryText)
            }
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Studio.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct EngineToggleRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn.animation(.snappy)) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isOn ? tint : Studio.tertiaryText)
                    .frame(width: 32, height: 32)
                    .background((isOn ? tint : Color.white).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Studio.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Studio.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }
}

/// Visualises the playback zoom factor that iOS applies on long-press.
private struct ZoomGauge: View {
    let isZoomDisabled: Bool

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Studio.accent.opacity(0.85), Color.orange.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(6)
                    .scaleEffect(isZoomDisabled ? 1.0 : 1.18)
                Image(systemName: "livephoto")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.7))
                    .scaleEffect(isZoomDisabled ? 1.0 : 1.18)
            }
            .frame(width: 84, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(isZoomDisabled ? "1.000×" : "1.075×")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isZoomDisabled ? Studio.accent : .white)
                    .contentTransition(.numericText())
                Text(isZoomDisabled ? "长按播放时画面保持原始比例" : "系统默认：0.3s 内推进放大 7.5%")
                    .font(.system(size: 12))
                    .foregroundStyle(Studio.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: isZoomDisabled)
    }
}

private struct FilmstripView: View {
    let thumbnails: [CGImage]

    var body: some View {
        GeometryReader { geo in
            let count = max(1, thumbnails.count)
            let cellWidth = max(1, (geo.size.width - CGFloat(count - 1)) / CGFloat(count))
            HStack(spacing: 1) {
                ForEach(thumbnails.indices, id: \.self) { index in
                    Image(uiImage: UIImage(cgImage: thumbnails[index]))
                        .resizable()
                        .scaledToFill()
                        .frame(width: cellWidth, height: geo.size.height)
                        .clipped()
                }
            }
        }
        .background(Color.white.opacity(0.05))
    }
}

/// Filmstrip with two draggable yellow handles bounding the Live Photo clip.
private struct FilmstripTrimmer: View {
    enum Handle { case lower, upper }

    let thumbnails: [CGImage]
    let duration: Double
    let range: ClosedRange<Double>
    let coverTime: Double
    let isEnabled: Bool
    let onChange: (Handle, Double) -> Void

    let stripHeight: CGFloat = 60
    let handleWidth: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let total = max(duration, 0.01)
            let lowerX = CGFloat(range.lowerBound / total) * width
            let upperX = CGFloat(range.upperBound / total) * width
            let coverX = CGFloat(coverTime / total) * width

            ZStack(alignment: .topLeading) {
                FilmstripView(thumbnails: thumbnails)
                    .frame(width: width, height: stripHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Rectangle()
                    .fill(Color.black.opacity(0.66))
                    .frame(width: max(0, lowerX), height: stripHeight)
                Rectangle()
                    .fill(Color.black.opacity(0.66))
                    .frame(width: max(0, width - upperX), height: stripHeight)
                    .offset(x: upperX)

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Studio.accent, lineWidth: 3)
                    .frame(width: max(handleWidth * 2, upperX - lowerX), height: stripHeight)
                    .offset(x: min(lowerX, width - handleWidth * 2))

                Capsule()
                    .fill(Color.white)
                    .frame(width: 2, height: stripHeight + 10)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: coverX - 1, y: -5)

                handleView(.lower, width: width, total: total)
                    .position(x: min(lowerX, width - handleWidth * 2) + handleWidth / 2, y: stripHeight / 2)
                handleView(.upper, width: width, total: total)
                    .position(x: max(upperX, handleWidth * 2) - handleWidth / 2, y: stripHeight / 2)
            }
            .coordinateSpace(.named("trimmer"))
        }
        .frame(height: stripHeight)
        .opacity(isEnabled ? 1 : 0.6)
    }

    private func handleView(_ handle: Handle, width: CGFloat, total: Double) -> some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: handle == .lower ? 12 : 0,
                bottomLeadingRadius: handle == .lower ? 12 : 0,
                bottomTrailingRadius: handle == .upper ? 12 : 0,
                topTrailingRadius: handle == .upper ? 12 : 0,
                style: .continuous
            )
            .fill(Studio.accent)
            Image(systemName: handle == .lower ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(.black.opacity(0.75))
        }
        .frame(width: handleWidth, height: stripHeight)
        .frame(width: 44, height: stripHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("trimmer"))
                .onChanged { value in
                    guard isEnabled else { return }
                    let x = min(max(0, value.location.x), width)
                    onChange(handle, Double(x / width) * total)
                }
        )
        .accessibilityLabel(handle == .lower ? "截取起点" : "截取终点")
    }
}

/// Filmstrip scrubber with a playhead used to choose the Key Photo frame.
private struct CoverScrubber: View {
    let thumbnails: [CGImage]
    let duration: Double
    let range: ClosedRange<Double>
    let time: Double
    let onScrub: (Double) -> Void

    let stripHeight: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let total = max(duration, 0.01)
            let lowerX = CGFloat(range.lowerBound / total) * width
            let upperX = CGFloat(range.upperBound / total) * width
            let playX = CGFloat(time / total) * width

            ZStack(alignment: .topLeading) {
                FilmstripView(thumbnails: thumbnails)
                    .frame(width: width, height: stripHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Rectangle()
                    .fill(Color.black.opacity(0.7))
                    .frame(width: max(0, lowerX), height: stripHeight)
                Rectangle()
                    .fill(Color.black.opacity(0.7))
                    .frame(width: max(0, width - upperX), height: stripHeight)
                    .offset(x: upperX)

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Studio.accent)
                    .frame(width: 5, height: stripHeight + 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.35), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .offset(x: min(max(0, playX - 2.5), width - 5), y: -7)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = min(max(0, value.location.x), width)
                        let seconds = Double(x / width) * total
                        onScrub(min(max(seconds, range.lowerBound), range.upperBound))
                    }
            )
        }
        .frame(height: stripHeight)
        .padding(.vertical, 7)
        .accessibilityLabel("封面帧选择")
    }
}

/// Small animated Live Photo glyph (dotted ring · solid ring · core).
private struct LiveGlyph: View {
    let size: CGFloat
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let angle = isActive ? timeline.date.timeIntervalSinceReferenceDate * 120 : 0
            ZStack {
                Circle()
                    .stroke(Studio.accent, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round, dash: [0.1, size * 0.13]))
                    .rotationEffect(.degrees(angle))
                Circle()
                    .stroke(Studio.accent, lineWidth: size * 0.07)
                    .padding(size * 0.19)
                Circle()
                    .fill(Studio.accent)
                    .padding(size * 0.36)
            }
            .frame(width: size, height: size)
        }
    }
}

/// Large hero rendition of the Live Photo glyph for the welcome screen.
private struct LiveRingsHero: View {
    @State private var rotation = 0.0
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Studio.accent.opacity(0.35), .clear], center: .center, startRadius: 4, endRadius: 80))
                .scaleEffect(breathe ? 1.15 : 0.9)
            Circle()
                .stroke(Studio.accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [0.1, 11]))
                .rotationEffect(.degrees(rotation))
            Circle()
                .stroke(Studio.accent, lineWidth: 4)
                .padding(26)
            Circle()
                .fill(Studio.accent)
                .padding(46)
                .scaleEffect(breathe ? 1.0 : 0.88)
        }
        .onAppear {
            withAnimation(.linear(duration: 24).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Anti-Zoom Explainer

private struct AntiZoomExplainer: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    comparisonFrame(title: "系统默认", factor: "1.075×", scale: 1.16, highlighted: false)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Studio.tertiaryText)
                    comparisonFrame(title: "实况原画", factor: "1.000×", scale: 1.0, highlighted: true)
                }
                .frame(maxWidth: .infinity)

                section(
                    number: "01",
                    title: "为什么会放大？",
                    body: "PhotosPlayer.framework 中的 ISLivePhotoPlayer._updateScaleIfNeeded 会在 supportsVitality 为 true 时，于长按播放的 0.3 秒内把画面推进到 1.075 倍，用来掩盖相机防抖的边缘裁切。"
                )
                section(
                    number: "02",
                    title: "如何撤销？",
                    body: "在配对 MOV 的 QuickTime 元数据中写入 com.apple.quicktime.live-photo.vitality-disabled = 1 与 transition-vitality-score.v1 = 0.0。PFMetadataMovie.hasVitality 因此返回 false，播放器始终保持 scale = 1.0。"
                )
                section(
                    number: "03",
                    title: "封面同样 1:1",
                    body: "静态封面以 AVAssetImageGenerator.ApertureMode.encodedPixels 采样完整编码像素，避免 Clean Aperture 与原始尺寸不一致造成的过渡形变。"
                )
            }
            .padding(22)
        }
    }

    private func comparisonFrame(title: String, factor: String, scale: CGFloat, highlighted: Bool) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(highlighted ? Studio.accent : Color.white.opacity(0.35))
                    .padding(8)
                    .scaleEffect(scale)
            }
            .frame(width: 110, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(factor)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(highlighted ? Studio.accent : .white)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Studio.secondaryText)
        }
    }

    private func section(number: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Studio.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                Text(body)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Studio Backdrop

/// Darkroom backdrop: an animated mesh of the active palette on iOS 18+, drifting orbs on iOS 17.
private struct StudioBackdrop: View {
    let palette: [RGBAColor]
    let isAnimating: Bool
    let isEnergetic: Bool

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.035, blue: 0.045)

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate * (isEnergetic ? 1.6 : 0.35)
                if #available(iOS 18.0, *) {
                    meshLayer(t: t)
                } else {
                    orbLayer(t: t)
                }
            }
            .opacity(0.9)

            // Vignette keeps the editorial darkroom contrast for text legibility.
            RadialGradient(
                colors: [Color.clear, Color.black.opacity(0.65)],
                center: .center,
                startRadius: 120,
                endRadius: 720
            )
            LinearGradient(
                colors: [Color.black.opacity(0.15), Color.black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(.easeInOut(duration: 0.8), value: palette)
    }

    private func color(_ index: Int, dim: Double) -> Color {
        let c = palette.isEmpty ? RGBAColor(r: 0.2, g: 0.2, b: 0.3) : palette[index % palette.count]
        return Color(red: c.r * dim, green: c.g * dim, blue: c.b * dim)
    }

    @available(iOS 18.0, *)
    private func meshLayer(t: Double) -> some View {
        let w0 = Float(sin(t) * 0.12)
        let w1 = Float(sin(t + 1.3) * 0.14)
        let w2 = Float(sin(t + 2.1) * 0.16)
        let w3 = Float(sin(t + 0.7) * 0.14)
        let w4 = Float(sin(t + 2.9) * 0.14)
        let w5 = Float(sin(t + 3.7) * 0.12)
        var points: [SIMD2<Float>] = []
        points.append(SIMD2<Float>(0, 0))
        points.append(SIMD2<Float>(0.5 + w0, 0))
        points.append(SIMD2<Float>(1, 0))
        points.append(SIMD2<Float>(0, 0.5 + w1))
        points.append(SIMD2<Float>(0.5 + w2, 0.45 + w3))
        points.append(SIMD2<Float>(1, 0.5 + w4))
        points.append(SIMD2<Float>(0, 1))
        points.append(SIMD2<Float>(0.5 + w5, 1))
        points.append(SIMD2<Float>(1, 1))
        let ink = Color(red: 0.03, green: 0.03, blue: 0.04)
        let colors: [Color] = [
            color(0, dim: 0.85), ink, color(1, dim: 0.75),
            ink, color(2, dim: 0.55), ink,
            color(3, dim: 0.7), ink, color(0, dim: 0.5)
        ]
        return MeshGradient(width: 3, height: 3, points: points, colors: colors, smoothsColors: true)
    }

    private func orbLayer(t: Double) -> some View {
        Canvas { context, size in
            let maxDim = max(size.width, size.height)
            for index in 0..<max(1, palette.count) {
                let phase = Double(index) * 1.57 + t
                let center = CGPoint(
                    x: size.width * (0.5 + 0.36 * cos(phase * 0.73 + Double(index))),
                    y: size.height * (0.45 + 0.38 * sin(phase * 0.61 + Double(index) * 0.8))
                )
                let radius = maxDim * (0.46 + 0.06 * sin(phase * 1.1))
                let orb = color(index, dim: 1.0)
                context.drawLayer { layer in
                    layer.blendMode = .plusLighter
                    layer.fill(
                        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                        with: .radialGradient(
                            Gradient(colors: [orb.opacity(0.5), orb.opacity(0.0)]),
                            center: center,
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                }
            }
        }
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
