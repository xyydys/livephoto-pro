import AVFoundation
import AVKit
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Design Tokens

private enum Theme {
    /// Calm periwinkle blue used for primary actions and selection.
    static let accent = Color(red: 0.42, green: 0.60, blue: 1.0)
    /// Lighter tint of the accent for small highlights on dark glass.
    static let accentSoft = Color(red: 0.70, green: 0.80, blue: 1.0)
    static let success = Color(red: 0.45, green: 0.86, blue: 0.64)
    static let caution = Color(red: 1.0, green: 0.72, blue: 0.40)
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.45)
    static let primaryText = Color.white.opacity(0.95)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.40)
    static let separator = Color.white.opacity(0.08)
    static let fill = Color.white.opacity(0.06)
    static let maxContentWidth: CGFloat = 600
}

enum BackdropStyle: String, CaseIterable, Identifiable {
    case ambience = "画面氛围"
    case pure = "纯净深色"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .ambience: return "以当前封面帧柔焦铺底"
        case .pure: return "安静的深色渐变"
        }
    }
}

enum DurationPreset: String, CaseIterable, Identifiable {
    case full = "完整"
    case threeSeconds = "3 秒"
    case fiveSeconds = "5 秒"
    case tenSeconds = "10 秒"
    case custom = "自定义"

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
    case video = "原片"
    case livePhoto = "实况"

    var id: String { rawValue }
}

private enum StudioTab: String, CaseIterable, Identifiable {
    case duration = "时长"
    case cover = "封面"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .duration: return "timeline.selection"
        case .cover: return "photo"
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
    @State private var studioTab: StudioTab = .duration
    @State private var showsSpecDetails = false
    @State private var generatedFiles: LivePhotoFiles?
    @State private var generatedLivePhoto: PHLivePhoto?
    @State private var livePhotoPlaybackTrigger = 0
    @State private var isWorking = false
    @State private var workingStatus = "正在处理…"
    @State private var feedback: Feedback?
    @State private var justSaved = false
    @State private var successPulse = 0
    @State private var errorPulse = 0

    // User-configurable conversion options
    @AppStorage("LP_disablePlaybackZoom") private var disablePlaybackZoom = true
    @AppStorage("LP_fullFrameRateIntent") private var fullFrameRateIntent = true
    @AppStorage("LP_includeAudio") private var includeAudio = true
    @AppStorage("LP_coverFormat") private var coverFormatRaw = CoverImageFormat.jpeg.rawValue
    @AppStorage("LP_apertureMode") private var apertureModeRaw = CoverApertureMode.encodedPixels.rawValue
    @AppStorage("LP_backdropStyle") private var backdropStyleRaw = BackdropStyle.ambience.rawValue
    @AppStorage("LP_hapticsEnabled") private var hapticsEnabled = true

    // Timeline trimming & cover frame controls
    @State private var durationPreset: DurationPreset = .full
    @State private var trimStartSeconds: Double = 0.0
    @State private var trimEndSeconds: Double = 0.0
    @State private var useCustomCoverTime = false
    @State private var customCoverTimeSeconds: Double = 0.0
    @State private var coverPreviewImage: CGImage?
    @State private var backdropImage: CGImage?
    @State private var backdropToken = 0

    private var coverFormat: CoverImageFormat {
        CoverImageFormat(rawValue: coverFormatRaw) ?? .jpeg
    }

    private var apertureMode: CoverApertureMode {
        CoverApertureMode(rawValue: apertureModeRaw) ?? .encodedPixels
    }

    private var backdropStyle: BackdropStyle {
        BackdropStyle(rawValue: backdropStyleRaw) ?? .ambience
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
            AmbienceBackdrop(
                image: backdropStyle == .ambience ? backdropImage : nil,
                token: backdropToken
            )

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    header
                        .reveal(0)

                    if let spec = specification, let source, let player {
                        Group {
                            stageCard(spec: spec, source: source, player: player)
                                .reveal(1)
                            studioCard(spec)
                                .reveal(2)
                            engineCard
                                .reveal(3)
                            footnote
                                .reveal(4)
                        }
                        .id(source.url)
                    } else {
                        welcomeCard
                            .reveal(1)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: Theme.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if source != nil {
                actionDock
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let feedback {
                ToastView(feedback: feedback) {
                    withAnimation(.smooth(duration: 0.35)) { self.feedback = nil }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .frame(maxWidth: Theme.maxContentWidth)
                .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top)))
                .zIndex(2)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: source?.url)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: feedback?.id)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .sensoryFeedback(trigger: successPulse) { _, _ in hapticsEnabled ? .success : nil }
        .sensoryFeedback(trigger: errorPulse) { _, _ in hapticsEnabled ? .error : nil }
        .sensoryFeedback(trigger: studioTab) { _, _ in hapticsEnabled ? .selection : nil }
        .sensoryFeedback(trigger: stageMode) { _, _ in hapticsEnabled ? .selection : nil }
        .sensoryFeedback(trigger: durationPreset) { _, _ in hapticsEnabled ? .selection : nil }
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
            SettingsView(
                coverFormatRaw: $coverFormatRaw,
                apertureModeRaw: $apertureModeRaw,
                backdropStyleRaw: $backdropStyleRaw,
                hapticsEnabled: $hapticsEnabled,
                previewImage: backdropImage
            )
        }
        .sheet(isPresented: $showsAntiZoomPrincipleSheet) {
            NavigationStack {
                AntiZoomExplainer()
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("实况原画")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                HStack(spacing: 6) {
                    Circle()
                        .fill(disablePlaybackZoom ? Theme.success : Theme.tertiaryText)
                        .frame(width: 6, height: 6)
                    Text(disablePlaybackZoom ? "无损直通 · 1:1 零缩放" : "无损直通 · 系统默认缩放")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.interpolate)
                }
                .animation(.smooth, value: disablePlaybackZoom)
            }

            Spacer(minLength: 8)

            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    if source != nil {
                        Menu {
                            importMenuItems
                        } label: {
                            GlassIcon(systemName: "plus")
                        }
                        .disabled(isWorking)
                        .accessibilityLabel("更换视频")
                        .transition(.scale.combined(with: .opacity))
                    }

                    Button {
                        showsSettingsSheet = true
                    } label: {
                        GlassIcon(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("设置")
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
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

    private var welcomeCard: some View {
        VStack(spacing: 26) {
            BreathingLiveIcon()
                .frame(width: 112, height: 112)
                .padding(.top, 18)

            VStack(spacing: 10) {
                Text("让视频成为实况照片")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                Text("原画样本直通封装，不重编码；\n任意时长，长按播放时画面不再放大。")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            VStack(spacing: 12) {
                Button {
                    showsPhotoPicker = true
                } label: {
                    Label("从相册选择视频", systemImage: "photo.on.rectangle.angled")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .prominentGlassButton()

                Button {
                    showsFilePicker = true
                } label: {
                    Label("从文件导入", systemImage: "folder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .regularGlassButton()
            }
            .controlSize(.large)
            .disabled(isWorking)

            if isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(workingStatus)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
                .transition(.blurReplace)
            }

            HStack(spacing: 0) {
                welcomeFeature(icon: "arrow.up.left.and.arrow.down.right", title: "1:1 播放")
                Rectangle().fill(Theme.separator).frame(width: 0.5, height: 34)
                welcomeFeature(icon: "infinity", title: "不限时长")
                Rectangle().fill(Theme.separator).frame(width: 0.5, height: 34)
                welcomeFeature(icon: "square.stack.3d.down.right", title: "原画直通")
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .studioGlass(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .animation(.smooth, value: isWorking)
    }

    private func welcomeFeature(icon: String, title: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accentSoft)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Stage Card

    private func stageAspect(_ spec: VideoSpecification) -> CGFloat {
        let size = spec.naturalSize
        guard size.width > 0, size.height > 0 else { return 16.0 / 9.0 }
        return max(0.8, min(size.width / size.height, 1.85))
    }

    private func stageCard(spec: VideoSpecification, source: ImportedVideo, player: AVPlayer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(String(format: "%.2f 秒 · ", spec.durationSeconds) + spec.fileSizeText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer(minLength: 8)
                if generatedLivePhoto != nil {
                    GlassSegmented(
                        items: PreviewStageMode.allCases,
                        selection: $stageMode,
                        title: { $0.rawValue },
                        compact: true
                    )
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 4)

            ZStack {
                Color.black
                if stageMode == .livePhoto, let livePhoto = generatedLivePhoto {
                    LivePhotoPreviewView(
                        livePhoto: livePhoto,
                        isMuted: !includeAudio,
                        playbackTrigger: livePhotoPlaybackTrigger
                    )
                    .transition(.blurReplace)
                } else {
                    VideoPlayer(player: player)
                        .accessibilityLabel("原视频预览")
                        .transition(.blurReplace)
                }
            }
            .aspectRatio(stageAspect(spec), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
            )
            .overlay(alignment: .topLeading) {
                liveBadge
                    .padding(10)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if stageMode == .livePhoto, generatedLivePhoto != nil {
                    HStack {
                        Label("长按画面播放", systemImage: "hand.point.up.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .studioGlass(Capsule())
                        Spacer()
                        Button {
                            livePhotoPlaybackTrigger += 1
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                        }
                        .regularGlassButton()
                        .accessibilityLabel("播放实况")
                    }
                    .padding(10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.smooth(duration: 0.4), value: stageMode)
            .animation(.smooth(duration: 0.4), value: generatedLivePhoto != nil)

            specDisclosure(spec)
        }
        .padding(14)
        .studioGlass(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "livephoto")
                .font(.system(size: 12, weight: .semibold))
            Text("实况")
                .font(.system(size: 12, weight: .semibold))
            if effectiveOutputDuration > 3.05 {
                Text(String(format: "%.1fs", effectiveOutputDuration))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .studioGlass(Capsule())
        .animation(.smooth, value: effectiveOutputDuration)
    }

    private func specDisclosure(_ spec: VideoSpecification) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    showsSpecDetails.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(spec.isPassthroughCompatible ? Theme.success : Theme.caution)
                        .frame(width: 7, height: 7)
                    Text([spec.resolutionTier, spec.codecName, spec.frameRateText, spec.isHDR ? "HDR" : nil]
                        .compactMap { $0 }
                        .joined(separator: "  ·  "))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .rotationEffect(.degrees(showsSpecDetails ? 180 : 0))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsSpecDetails ? "收起原片信息" : "展开原片信息")

            if showsSpecDetails {
                VStack(spacing: 0) {
                    specRow("分辨率", spec.resolutionText)
                    specRow("编码", spec.codecName + (spec.isPassthroughCompatible ? " · 可直通" : " · 不可直通"))
                    specRow("色彩", spec.colorSpaceLabel)
                    specRow("帧率", "\(spec.frameRateText) · 约 \(spec.totalFramesEstimate) 帧")
                    specRow("码率", String(format: "%.1f Mbps", spec.estimatedBitrateMbps))
                    specRow("音轨", spec.audioSummary, isLast: true)
                }
                .padding(.horizontal, 14)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -8)),
                    removal: .opacity
                ))
            }
        }
    }

    private func specRow(_ label: String, _ value: String, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Text(value)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.system(size: 13))
            .padding(.vertical, 11)
            if !isLast {
                Rectangle().fill(Theme.separator).frame(height: 0.5)
            }
        }
    }

    // MARK: - Studio Card (duration & cover)

    private func studioCard(_ spec: VideoSpecification) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("剪辑")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                GlassSegmented(
                    items: StudioTab.allCases,
                    selection: $studioTab,
                    title: { $0.rawValue },
                    icon: { $0.icon },
                    compact: true
                )
            }

            ZStack(alignment: .top) {
                if studioTab == .duration {
                    durationPane(spec)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: -16)),
                            removal: .opacity.combined(with: .offset(x: -16))
                        ))
                } else {
                    coverPane(spec)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 16)),
                            removal: .opacity.combined(with: .offset(x: 16))
                        ))
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.88), value: studioTab)
        }
        .padding(20)
        .studioGlass(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    private func durationPane(_ spec: VideoSpecification) -> some View {
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
            }

            HStack(alignment: .firstTextBaseline) {
                timeReadout(String(format: "%.2f", displayedRange.lowerBound), caption: "起点")
                Spacer()
                VStack(spacing: 2) {
                    Text(String(format: "%.2f", effectiveOutputDuration))
                        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.primaryText)
                        .contentTransition(.numericText())
                    Text("秒 · 实况时长")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
                timeReadout(String(format: "%.2f", displayedRange.upperBound), caption: "终点", trailing: true)
            }
            .animation(.smooth(duration: 0.25), value: displayedRange)

            presetBar(total: spec.durationSeconds)
        }
    }

    private func timeReadout(_ value: String, caption: String, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .contentTransition(.numericText())
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private func presetBar(total: Double) -> some View {
        HStack(spacing: 6) {
            ForEach(DurationPreset.allCases) { preset in
                let isSelected = durationPreset == preset
                Button {
                    applyPreset(preset, total: total)
                } label: {
                    Text(preset.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            if isSelected {
                                Capsule().fill(Theme.accent.opacity(0.9))
                            } else {
                                Capsule().fill(Theme.fill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(isWorking)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: durationPreset)
    }

    private func coverPane(_ spec: VideoSpecification) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                coverThumbnail(spec)

                VStack(alignment: .leading, spacing: 6) {
                    Text(useCustomCoverTime ? "自选封面帧" : "片段首帧")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .contentTransition(.interpolate)
                    Text(useCustomCoverTime
                         ? String(format: "取自 %.2f 秒处", displayedCoverTime)
                         : "与播放起点一致，过渡零跳帧")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.numericText())
                    Text("\(coverFormat.rawValue) · \(apertureMode == .encodedPixels ? "1:1 编码像素" : "Clean Aperture")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }

            GlassSegmented(
                items: [false, true],
                selection: $useCustomCoverTime,
                title: { $0 ? "自选帧" : "首帧" }
            )
            .onChange(of: useCustomCoverTime) { _, isCustom in
                let start = displayedRange.lowerBound
                if isCustom {
                    customCoverTimeSeconds = start
                }
                Task { await updateCoverFramePreview(at: start) }
            }

            if useCustomCoverTime, !spec.thumbnails.isEmpty {
                VStack(spacing: 14) {
                    CoverScrubber(
                        thumbnails: spec.thumbnails,
                        duration: spec.durationSeconds,
                        range: displayedRange,
                        time: displayedCoverTime,
                        loupeImage: coverPreviewImage,
                        onScrub: { setCoverTime($0) }
                    )

                    HStack {
                        frameStepButton(systemName: "backward.frame.fill", delta: -1, spec: spec)
                        Spacer()
                        Text(String(format: "%.3f s", displayedCoverTime))
                            .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                            .contentTransition(.numericText())
                        Spacer()
                        frameStepButton(systemName: "forward.frame.fill", delta: 1, spec: spec)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: useCustomCoverTime)
    }

    private func coverThumbnail(_ spec: VideoSpecification) -> some View {
        let image = coverPreviewImage ?? spec.thumbnails.first
        return ZStack {
            if let image {
                Image(uiImage: UIImage(cgImage: image))
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
                    .id(ObjectIdentifier(image))
            } else {
                Theme.fill
            }
        }
        .frame(width: 92, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
        .animation(.easeInOut(duration: 0.25), value: image.map { ObjectIdentifier($0) })
    }

    private func frameStepButton(systemName: String, delta: Double, spec: VideoSpecification) -> some View {
        Button {
            let step = 1.0 / max(1.0, spec.nominalFrameRate)
            setCoverTime(displayedCoverTime + delta * step)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 20, height: 20)
        }
        .regularGlassButton()
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(delta < 0 ? "上一帧" : "下一帧")
    }

    // MARK: - Engine Card

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("实况引擎")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Button {
                    showsAntiZoomPrincipleSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text("原理")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accentSoft)
                }
                .buttonStyle(.plain)
            }

            ZoomIllustration(isZoomDisabled: disablePlaybackZoom)

            VStack(spacing: 0) {
                EngineToggleRow(
                    icon: "arrow.up.left.and.arrow.down.right",
                    tint: Theme.accent,
                    title: "撤销播放放大",
                    detail: "长按播放时保持 1:1 原画比例",
                    isOn: $disablePlaybackZoom,
                    hapticsEnabled: hapticsEnabled
                )
                Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 56)
                EngineToggleRow(
                    icon: "gauge.with.dots.needle.67percent",
                    tint: Theme.success,
                    title: "满帧率播放",
                    detail: "60 / 120fps 回放不抽帧",
                    isOn: $fullFrameRateIntent,
                    hapticsEnabled: hapticsEnabled
                )
                Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 56)
                EngineToggleRow(
                    icon: includeAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    tint: Color(red: 0.74, green: 0.62, blue: 1.0),
                    title: "保留原声",
                    detail: "AAC 直通，其他格式转为 AAC-LC",
                    isOn: $includeAudio,
                    hapticsEnabled: hapticsEnabled
                )
            }
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(20)
        .studioGlass(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    private var footnote: some View {
        Text("压缩视频样本比特级写入配对 MOV，画质与原片一致。")
            .font(.system(size: 12))
            .foregroundStyle(Theme.tertiaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
    }

    // MARK: - Action Dock

    private var actionDock: some View {
        GlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                if !isWorking {
                    Button {
                        Task { await convertForInAppPreviewOnly() }
                    } label: {
                        Image(systemName: "livephoto.play")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Theme.primaryText)
                            .frame(width: 30, height: 32)
                    }
                    .regularGlassButton()
                    .accessibilityLabel("生成并在 App 内预览")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                Button {
                    Task { await convertAndSaveToPhotos() }
                } label: {
                    primaryLabel
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .prominentGlassButton()
                .allowsHitTesting(!isWorking)

                if !isWorking, let files = generatedFiles {
                    Button {
                        shareItems = [files.photoURL, files.movieURL]
                        showsShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Theme.primaryText)
                            .frame(width: 30, height: 32)
                    }
                    .regularGlassButton()
                    .accessibilityLabel("导出配对源文件")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: Theme.maxContentWidth)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isWorking)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: generatedFiles?.identifier)
    }

    @ViewBuilder
    private var primaryLabel: some View {
        ZStack {
            if isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text(workingStatus)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .transition(.blurReplace)
            } else if justSaved {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .symbolEffect(.bounce, value: justSaved)
                    Text("已存入相册")
                        .font(.system(size: 16, weight: .semibold))
                }
                .transition(.blurReplace)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16, weight: .semibold))
                    Text("存入相册")
                        .font(.system(size: 16, weight: .semibold))
                    Text(String(format: "%.1fs", effectiveOutputDuration))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .opacity(0.7)
                        .contentTransition(.numericText())
                }
                .transition(.blurReplace)
            }
        }
        .foregroundStyle(.white)
        .animation(.smooth(duration: 0.35), value: isWorking)
        .animation(.smooth(duration: 0.35), value: justSaved)
    }

    // MARK: - Timeline Helpers

    private func applyPreset(_ preset: DurationPreset, total: Double) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
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
            setBackdrop(frame)
        }
    }

    private func setBackdrop(_ image: CGImage?) {
        backdropImage = image
        backdropToken &+= 1
    }

    @MainActor
    private func present(_ newFeedback: Feedback) {
        feedback = newFeedback
        if newFeedback.isError {
            errorPulse += 1
        } else {
            successPulse += 1
        }
        let id = newFeedback.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(newFeedback.isError ? 6 : 4))
            if feedback?.id == id {
                withAnimation(.smooth(duration: 0.4)) { feedback = nil }
            }
        }
    }

    @MainActor
    private func finishImport(_ result: Result<ImportedVideo, Error>) async {
        showsPhotoPicker = false
        switch result {
        case .success(let imported):
            workingStatus = "正在解析视频…"
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
                studioTab = .duration
                showsSpecDetails = false
                justSaved = false
                durationPreset = .full
                trimStartSeconds = 0.0
                trimEndSeconds = spec.durationSeconds
                useCustomCoverTime = false
                customCoverTimeSeconds = 0.0
                coverPreviewImage = spec.thumbnails.first
                setBackdrop(spec.thumbnails.first)
                isWorking = false
            } catch {
                imported.remove()
                isWorking = false
                present(.error("无法解析所选视频：\(error.localizedDescription)"))
            }
        case .failure(let error):
            isWorking = false
            present(.error("无法导入视频：\(error.localizedDescription)"))
        }
    }

    @MainActor
    private func convertForInAppPreviewOnly() async {
        guard let source, !isWorking else { return }
        isWorking = true
        workingStatus = "正在封装实况…"
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
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    stageMode = .livePhoto
                }
                present(.success("实况预览已就绪", detail: "在画面上长按，检验播放是否保持 1:1。"))
            } else {
                present(.success("配对文件已生成", detail: "可导出源文件，或直接存入相册。"))
            }
        } catch {
            present(.error("生成实况预览失败：\(error.localizedDescription)"))
        }
    }

    @MainActor
    private func convertAndSaveToPhotos() async {
        guard let source, !isWorking else { return }
        isWorking = true
        workingStatus = "正在写入相册…"
        feedback = nil
        player?.pause()
        defer { isWorking = false }

        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                present(.error("请在「设置 → 隐私与安全性 → 照片」中允许本 App 添加照片。"))
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
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    stageMode = .livePhoto
                }
            }

            let durationDesc = String(format: "%.2f 秒", result.outputDurationSeconds)
            let zoomDesc = disablePlaybackZoom ? "1:1 零放大" : "标准缩放"
            present(.success("已存入系统相册", detail: "\(durationDesc) · \(zoomDesc)"))
            justSaved = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.4))
                justSaved = false
            }
        } catch {
            present(.error("转换或保存失败：\(error.localizedDescription)"))
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
}

// MARK: - Feedback & Toast

private struct Feedback: Equatable {
    let id = UUID()
    let title: String
    let detail: String?
    let isError: Bool

    var icon: String { isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill" }
    var color: Color { isError ? Theme.danger : Theme.success }

    static func success(_ title: String, detail: String? = nil) -> Self {
        Self(title: title, detail: detail, isError: false)
    }

    static func error(_ title: String) -> Self {
        Self(title: title, detail: nil, isError: true)
    }
}

private struct ToastView: View {
    let feedback: Feedback
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: feedback.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(feedback.color)
                .symbolEffect(.bounce, value: feedback.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = feedback.detail {
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .studioGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture(perform: onDismiss)
        .gesture(
            DragGesture(minimumDistance: 8).onEnded { value in
                if value.translation.height < -10 { onDismiss() }
            }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("轻点关闭")
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Binding var coverFormatRaw: String
    @Binding var apertureModeRaw: String
    @Binding var backdropStyleRaw: String
    @Binding var hapticsEnabled: Bool
    let previewImage: CGImage?

    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    settingsHeader
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                Section {
                    ForEach(CoverImageFormat.allCases) { format in
                        ChoiceRow(
                            title: format == .jpeg ? "JPEG" : "HEIC",
                            detail: format == .jpeg ? "100% 质量，兼容性最佳" : "高效编码，体积更小",
                            isSelected: coverFormatRaw == format.rawValue
                        ) {
                            coverFormatRaw = format.rawValue
                        }
                    }
                } header: {
                    Text("封面格式")
                }

                Section {
                    ForEach(CoverApertureMode.allCases) { mode in
                        ChoiceRow(
                            title: mode == .encodedPixels ? "1:1 编码像素" : "Clean Aperture",
                            detail: mode == .encodedPixels ? "按完整编码像素采样，封面与视频严格对齐" : "遵循容器裁切框，与常规播放器一致",
                            isSelected: apertureModeRaw == mode.rawValue
                        ) {
                            apertureModeRaw = mode.rawValue
                        }
                    }
                } header: {
                    Text("封面采样")
                } footer: {
                    Text("推荐使用「1:1 编码像素」，可避免封面与视频之间出现边缘微缩放。")
                }

                Section {
                    HStack(spacing: 12) {
                        ForEach(BackdropStyle.allCases) { style in
                            BackdropOption(
                                style: style,
                                previewImage: previewImage,
                                isSelected: backdropStyleRaw == style.rawValue
                            ) {
                                withAnimation(.smooth(duration: 0.4)) {
                                    backdropStyleRaw = style.rawValue
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)

                    Toggle(isOn: $hapticsEnabled) {
                        Label("触感反馈", systemImage: "hand.tap")
                    }
                } header: {
                    Text("外观与交互")
                }

                Section {
                    NavigationLink {
                        AntiZoomExplainer()
                    } label: {
                        Label("1:1 零缩放是如何实现的", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    NavigationLink {
                        VerifyGuideView()
                    } label: {
                        Label("校验导出文件", systemImage: "checkmark.seal")
                    }
                    if let url = URL(string: "https://github.com/xyydys/livephoto-pro") {
                        Link(destination: url) {
                            HStack {
                                Label("项目主页", systemImage: "chevron.left.forwardslash.chevron.right")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("了解更多")
                } footer: {
                    Text("无损 · 原画 · 实况")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .animation(.smooth(duration: 0.3), value: coverFormatRaw)
            .animation(.smooth(duration: 0.3), value: apertureModeRaw)
        }
        .tint(Theme.accent)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .sensoryFeedback(trigger: coverFormatRaw) { _, _ in hapticsEnabled ? .selection : nil }
        .sensoryFeedback(trigger: apertureModeRaw) { _, _ in hapticsEnabled ? .selection : nil }
        .sensoryFeedback(trigger: backdropStyleRaw) { _, _ in hapticsEnabled ? .selection : nil }
    }

    private var settingsHeader: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Color(red: 0.55, green: 0.42, blue: 0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "livephoto")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.white)
            }
            .frame(width: 76, height: 76)
            .shadow(color: Theme.accent.opacity(0.4), radius: 16, y: 8)

            Text("实况原画 Pro")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("版本 \(appVersion)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

private struct ChoiceRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .opacity(isSelected ? 1 : 0)
                    .scaleEffect(isSelected ? 1 : 0.4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct BackdropOption: View {
    let style: BackdropStyle
    let previewImage: CGImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.08, green: 0.09, blue: 0.12), Color(red: 0.02, green: 0.02, blue: 0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    if style == .ambience {
                        if let previewImage {
                            Image(uiImage: UIImage(cgImage: previewImage))
                                .resizable()
                                .scaledToFill()
                                .blur(radius: 14)
                                .opacity(0.7)
                        } else {
                            LinearGradient(
                                colors: [Theme.accent.opacity(0.55), Color(red: 0.85, green: 0.5, blue: 0.6).opacity(0.4)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .blur(radius: 10)
                        }
                    }
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.white.opacity(0.16))
                            .frame(height: 26)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.white.opacity(0.10))
                            .frame(height: 14)
                    }
                    .padding(12)
                }
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 0.6)
                )

                VStack(spacing: 2) {
                    Text(style.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.accentSoft : .primary)
                    Text(style.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct VerifyGuideView: View {
    var body: some View {
        List {
            Section {
                Text("从配对源文件导出 MOV 后，可在电脑上运行项目附带的脚本，对比原片与导出文件的压缩视频包 SHA-256、时间戳、分辨率、方向与色彩参数。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            Section {
                Text("python3 scripts/verify-video.py source.mp4 exported-paired.mov")
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            } header: {
                Text("命令")
            } footer: {
                Text("退出码 0 表示压缩视频样本与几何属性完全一致。")
            }
        }
        .navigationTitle("校验导出文件")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Anti-Zoom Explainer

private struct AntiZoomExplainer: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top, spacing: 18) {
                    comparison(title: "系统默认", factor: "1.075×", animated: true)
                    comparison(title: "实况原画", factor: "1.000×", animated: false)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                step(
                    index: 1,
                    title: "为什么会放大",
                    body: "系统 PhotosPlayer 在实况照片支持 vitality 时，会在长按播放的 0.3 秒内把画面推进到 1.075 倍，用来掩盖相机防抖的边缘裁切。"
                )
                step(
                    index: 2,
                    title: "如何撤销",
                    body: "在配对 MOV 中写入 live-photo.vitality-disabled = 1 与 transition-vitality-score = 0。系统读取后不再启用 vitality，播放器始终保持 1.0 倍。"
                )
                step(
                    index: 3,
                    title: "封面同样 1:1",
                    body: "封面按完整编码像素采样，避免 Clean Aperture 与原始尺寸不一致造成的过渡形变。"
                )
            }
            .padding(22)
        }
        .navigationTitle("1:1 零缩放")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func comparison(title: String, factor: String, animated: Bool) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                ZoomingSample(isZooming: animated, highlighted: !animated)
                    .padding(10)
            }
            .frame(width: 120, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(factor)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(animated ? Color.primary : Theme.accentSoft)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func step(index: Int, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(index)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(body)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A miniature "photo" that loops the system's long-press push-in when `isZooming` is true.
private struct ZoomingSample: View {
    let isZooming: Bool
    let highlighted: Bool

    var body: some View {
        sample
            .phaseAnimator(isZooming ? [1.0, 1.0, 1.16, 1.16] : [1.0]) { content, scale in
                content.scaleEffect(scale)
            } animation: { _ in
                .easeInOut(duration: 0.6)
            }
            .id(isZooming)
    }

    private var sample: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: highlighted
                            ? [Theme.accent, Color(red: 0.55, green: 0.42, blue: 0.95)]
                            : [Color.white.opacity(0.35), Color.white.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - Engine Components

private struct EngineToggleRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool
    let hapticsEnabled: Bool

    var body: some View {
        Toggle(isOn: $isOn.animation(.spring(response: 0.4, dampingFraction: 0.8))) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn ? tint : Theme.tertiaryText)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
                    .background((isOn ? tint : Color.white).opacity(isOn ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .tint(Theme.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .sensoryFeedback(trigger: isOn) { _, _ in hapticsEnabled ? .impact(weight: .light) : nil }
    }
}

/// Inline demonstration of the long-press zoom factor the current settings will produce.
private struct ZoomIllustration: View {
    let isZoomDisabled: Bool

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                ZoomingSample(isZooming: !isZoomDisabled, highlighted: isZoomDisabled)
                    .padding(7)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .frame(width: 78, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(isZoomDisabled ? "1.000×" : "1.075×")
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isZoomDisabled ? Theme.accentSoft : Theme.primaryText)
                    .contentTransition(.numericText(value: isZoomDisabled ? 1.0 : 1.075))
                Text(isZoomDisabled ? "长按播放时画面保持原始比例" : "长按播放时系统会推进放大 7.5%")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .contentTransition(.interpolate)
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isZoomDisabled)
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
            self.buttonStyle(.glassProminent).tint(Theme.accent)
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

    /// Staggered entrance: content rises softly out of a light blur.
    func reveal(_ index: Int) -> some View {
        modifier(RevealModifier(index: index))
    }
}

private struct RevealModifier: ViewModifier {
    let index: Int
    @State private var isShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : 22)
            .blur(radius: isShown || reduceMotion ? 0 : 10)
            .scaleEffect(isShown || reduceMotion ? 1 : 0.98, anchor: .top)
            .onAppear {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.86).delay(Double(index) * 0.07)) {
                    isShown = true
                }
            }
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
                    shape.fill(tint ?? Color.white.opacity(0.03))
                }
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.white.opacity(0.04), Color.white.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
            }
            .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
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
                    Capsule().fill(
                        LinearGradient(
                            colors: [Theme.accent, Color(red: 0.36, green: 0.50, blue: 0.96)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay(Capsule().strokeBorder(Color.white.opacity(isProminent ? 0.3 : 0.14), lineWidth: 0.6))
            .opacity(isEnabled ? 1.0 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Reusable Components

private struct GlassIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Theme.primaryText)
            .frame(width: 42, height: 42)
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
        .padding(3)
        .studioGlass(Capsule())
    }

    private func segment(_ item: Item) -> some View {
        let isSelected = item == selection
        return Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                selection = item
            }
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon(item))
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title(item))
                    .font(.system(size: compact ? 13 : 14, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : Theme.secondaryText)
            .padding(.horizontal, compact ? 12 : 10)
            .padding(.vertical, compact ? 6 : 9)
            .frame(maxWidth: compact ? nil : .infinity)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Theme.accent.opacity(0.9))
                        .matchedGeometryEffect(id: "segment", in: namespace)
                        .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FilmstripView: View {
    let thumbnails: [CGImage]

    var body: some View {
        GeometryReader { geo in
            let count = max(1, thumbnails.count)
            let cellWidth = max(1, geo.size.width / CGFloat(count))
            HStack(spacing: 0) {
                ForEach(thumbnails.indices, id: \.self) { index in
                    Image(uiImage: UIImage(cgImage: thumbnails[index]))
                        .resizable()
                        .scaledToFill()
                        .frame(width: cellWidth, height: geo.size.height)
                        .clipped()
                }
            }
        }
        .background(Theme.fill)
    }
}

/// Filmstrip with two slim draggable handles bounding the Live Photo clip.
private struct FilmstripTrimmer: View {
    enum Handle { case lower, upper }

    let thumbnails: [CGImage]
    let duration: Double
    let range: ClosedRange<Double>
    let coverTime: Double
    let isEnabled: Bool
    let onChange: (Handle, Double) -> Void

    @State private var activeHandle: Handle?

    let stripHeight: CGFloat = 52
    let handleWidth: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let total = max(duration, 0.01)
            let lowerX = CGFloat(range.lowerBound / total) * width
            let upperX = CGFloat(range.upperBound / total) * width
            let coverX = CGFloat(coverTime / total) * width
            let frameX = min(lowerX, width - handleWidth * 2)
            let frameWidth = max(handleWidth * 2, upperX - frameX)

            ZStack(alignment: .topLeading) {
                FilmstripView(thumbnails: thumbnails)
                    .frame(width: width, height: stripHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: max(0, lowerX), height: stripHeight)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, style: .continuous))
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: max(0, width - upperX), height: stripHeight)
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 12, topTrailingRadius: 12, style: .continuous))
                    .offset(x: upperX)

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 2.5)
                    .frame(width: frameWidth, height: stripHeight)
                    .offset(x: frameX)
                    .shadow(color: .black.opacity(0.3), radius: 4)

                Capsule()
                    .fill(Theme.accentSoft)
                    .frame(width: 2, height: stripHeight - 12)
                    .offset(x: coverX - 1, y: 6)
                    .allowsHitTesting(false)

                handleView(.lower, width: width, total: total)
                    .position(x: frameX + handleWidth / 2, y: stripHeight / 2)
                handleView(.upper, width: width, total: total)
                    .position(x: frameX + frameWidth - handleWidth / 2, y: stripHeight / 2)
            }
            .coordinateSpace(.named("trimmer"))
        }
        .frame(height: stripHeight)
        .opacity(isEnabled ? 1 : 0.55)
        .sensoryFeedback(.selection, trigger: activeHandle)
    }

    private func handleView(_ handle: Handle, width: CGFloat, total: Double) -> some View {
        let isActive = activeHandle == handle
        return ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: handle == .lower ? 12 : 0,
                bottomLeadingRadius: handle == .lower ? 12 : 0,
                bottomTrailingRadius: handle == .upper ? 12 : 0,
                topTrailingRadius: handle == .upper ? 12 : 0,
                style: .continuous
            )
            .fill(Color.white)
            Capsule()
                .fill(Color.black.opacity(0.35))
                .frame(width: 2.5, height: 16)
        }
        .frame(width: handleWidth, height: stripHeight)
        .scaleEffect(y: isActive ? 1.08 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isActive)
        .frame(width: 44, height: stripHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("trimmer"))
                .onChanged { value in
                    guard isEnabled else { return }
                    if activeHandle != handle { activeHandle = handle }
                    let x = min(max(0, value.location.x), width)
                    onChange(handle, Double(x / width) * total)
                }
                .onEnded { _ in activeHandle = nil }
        )
        .accessibilityLabel(handle == .lower ? "截取起点" : "截取终点")
    }
}

/// Filmstrip scrubber with a playhead and a floating loupe while dragging.
private struct CoverScrubber: View {
    let thumbnails: [CGImage]
    let duration: Double
    let range: ClosedRange<Double>
    let time: Double
    let loupeImage: CGImage?
    let onScrub: (Double) -> Void

    @State private var isDragging = false

    let stripHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let total = max(duration, 0.01)
            let lowerX = CGFloat(range.lowerBound / total) * width
            let upperX = CGFloat(range.upperBound / total) * width
            let playX = min(max(0, CGFloat(time / total) * width), width)

            ZStack(alignment: .topLeading) {
                FilmstripView(thumbnails: thumbnails)
                    .frame(width: width, height: stripHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Rectangle()
                    .fill(Color.black.opacity(0.62))
                    .frame(width: max(0, lowerX), height: stripHeight)
                Rectangle()
                    .fill(Color.black.opacity(0.62))
                    .frame(width: max(0, width - upperX), height: stripHeight)
                    .offset(x: upperX)

                Capsule()
                    .fill(Color.white)
                    .frame(width: 4, height: stripHeight + 12)
                    .shadow(color: .black.opacity(0.45), radius: 3)
                    .offset(x: min(max(0, playX - 2), width - 4), y: -6)

                if isDragging, let loupeImage {
                    Image(uiImage: UIImage(cgImage: loupeImage))
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.white, lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
                        .offset(x: min(max(0, playX - 42), width - 84), y: -100)
                        .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isDragging = true }
                        }
                        let x = min(max(0, value.location.x), width)
                        let seconds = Double(x / width) * total
                        onScrub(min(max(seconds, range.lowerBound), range.upperBound))
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isDragging = false }
                    }
            )
        }
        .frame(height: stripHeight)
        .padding(.vertical, 6)
        .zIndex(1)
        .accessibilityLabel("封面帧选择")
    }
}

/// Live Photo glyph that gently breathes; the dotted ring drifts slowly.
private struct BreathingLiveIcon: View {
    @State private var rotation = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.accent.opacity(0.28), .clear], center: .center, startRadius: 2, endRadius: 60))
                .phaseAnimator([0.9, 1.1]) { content, scale in
                    content.scaleEffect(scale)
                } animation: { _ in .easeInOut(duration: 2.6) }
            Circle()
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [0.1, 9]))
                .padding(10)
                .rotationEffect(.degrees(rotation))
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 2.5)
                .padding(30)
            Circle()
                .fill(Color.white)
                .padding(44)
                .phaseAnimator([1.0, 0.86]) { content, scale in
                    content.scaleEffect(scale)
                } animation: { _ in .easeInOut(duration: 1.3) }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Backdrop

/// Quiet backdrop: a deep gradient, optionally overlaid by a heavily diffused copy of the current cover frame.
private struct AmbienceBackdrop: View {
    let image: CGImage?
    let token: Int

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.075, blue: 0.10), Color(red: 0.02, green: 0.02, blue: 0.03)],
                startPoint: .top,
                endPoint: .bottom
            )

            if let image {
                Color.clear
                    .overlay {
                        Image(uiImage: UIImage(cgImage: image))
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 80, opaque: true)
                            .saturation(1.2)
                            .scaleEffect(1.2)
                    }
                    .clipped()
                    .opacity(0.55)
                    .id(token)
                    .transition(.opacity)
            }

            LinearGradient(
                colors: [Color.black.opacity(0.10), Color.black.opacity(0.35), Color.black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(.easeInOut(duration: 0.9), value: token)
        .animation(.easeInOut(duration: 0.6), value: image == nil)
        .ignoresSafeArea()
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
