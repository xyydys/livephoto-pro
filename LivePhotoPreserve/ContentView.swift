import AVFoundation
import AVKit
import CoreImage
import Photos
import PhotosUI
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Duration & Stage

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
    @State private var shareItems: [URL] = []
    @State private var showsShareSheet = false
    @State private var showsPaywall = false
    @State private var showsPaywallFromSettings = false

    // Preview & conversion state
    @State private var stageMode: PreviewStageMode = .video
    @State private var generatedFiles: LivePhotoFiles?
    @State private var generatedLivePhoto: PHLivePhoto?
    @State private var livePhotoPlaybackTrigger = 0
    @State private var isWorking = false
    @State private var workingStatus = "正在处理…"
    @State private var feedback: Feedback?
    @State private var justSaved = false

    // User-configurable conversion options
    @AppStorage("LP_disablePlaybackZoom") private var disablePlaybackZoom = true
    @AppStorage("LP_fullFrameRateIntent") private var fullFrameRateIntent = true
    @AppStorage("LP_includeAudio") private var includeAudio = true
    @AppStorage("LP_coverFormat") private var coverFormatRaw = CoverImageFormat.jpeg.rawValue
    @AppStorage("LP_apertureMode") private var apertureModeRaw = CoverApertureMode.encodedPixels.rawValue
    @AppStorage("LP_hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("LP_proDemoUnlocked") private var proUnlocked = false
    @AppStorage("LP_proBannerDismissed") private var proBannerDismissed = false

    // Timeline trimming & cover frame controls
    @State private var durationPreset: DurationPreset = .full
    @State private var trimStartSeconds: Double = 0.0
    @State private var trimEndSeconds: Double = 0.0
    @State private var useCustomCoverTime = false
    @State private var customCoverTimeSeconds: Double = 0.0
    @State private var coverPreviewImage: CGImage?

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
            disablePlaybackZoom: export.zoomOff,
            fullFrameRatePlaybackIntent: export.highRate,
            includeAudio: export.audio,
            coverFormat: CoverImageFormat(rawValue: export.format) ?? .jpeg,
            apertureMode: CoverApertureMode(rawValue: export.aperture) ?? .encodedPixels,
            trimRange: range,
            customCoverTimeSeconds: coverTime
        )
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var clipNavigation
    @Namespace private var editorNamespace
    private struct EditorRoute: Hashable {
        let sourceID: String?
    }

    @State private var editorPath: [EditorRoute] = []
    private var editorOpen: Bool { !editorPath.isEmpty }
    @State private var library = VideoLibrary()
    @State private var albumID: String?
    @State private var showsExportSheet = false
    @State private var advancedDefaults = false
    @State private var advancedExport = false
    @State private var editingCover = false
    @State private var showsTrimPresets = false
    @State private var draggingHandle: Int?
    @State private var playhead = 0.0
    @State private var isPlaying = false
    @State private var export = ExportPreferences()
    @State private var playbackObserver: Any?
    @State private var timelineFrames: [CGImage?] = []
    @State private var editorBackdrop: CGImage?
    @State private var lastScrubSeek = 0.0

    private struct ExportPreferences {
        var zoomOff = true
        var highRate = true
        var audio = true
        var format = CoverImageFormat.jpeg.rawValue
        var aperture = CoverApertureMode.encodedPixels.rawValue
    }

    private var inheritedExport: ExportPreferences {
        ExportPreferences(zoomOff: disablePlaybackZoom, highRate: fullFrameRateIntent,
                          audio: includeAudio, format: coverFormatRaw, aperture: apertureModeRaw)
    }

    private var spring: Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84)
    }

    var body: some View {
        NavigationStack(path: $editorPath) {
            pickerHome
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: EditorRoute.self) { route in
                    EditorDestination { dismiss in editor(onBack: dismiss) }
                        .toolbar(.hidden, for: .navigationBar)
                        .editorTransition(sourceID: reduceMotion ? nil : route.sourceID, in: clipNavigation)
                }
        }
        .sheet(isPresented: $showsPhotoPicker) {
            VideoPhotoPicker(didStart: {
                showsPhotoPicker = false
                feedback = nil
                workingStatus = "正在载入视频…"
                isWorking = true
            }, didFinish: { result in
                Task { await finishImport(result) }
            })
        }
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.movie, .video]) { result in
            guard case .success(let url) = result else { return }
            feedback = nil
            workingStatus = "正在载入视频…"
            isWorking = true
            Task { @MainActor in
                let imported = await Task.detached(priority: .userInitiated) {
                    Result { try ImportedVideo.copyCoordinatedFile(at: url) }
                }.value
                await finishImport(imported)
            }
        }
        .sheet(isPresented: $showsSettingsSheet) { settingsPanel }
        .sheet(isPresented: $showsExportSheet) { exportPanel }
        .sheet(isPresented: $showsShareSheet) { ActivityShareSheet(activityItems: shareItems) }
        .fullScreenCover(isPresented: $showsPaywall) {
            ProPaywallView(isUnlocked: $proUnlocked, hapticsEnabled: hapticsEnabled)
        }
        .onChange(of: editorOpen) { _, opened in
            if !opened {
                stopPlayback()
                feedback = nil
                showsTrimPresets = false
            }
        }
        .task(id: feedback?.id) {
            guard let notice = feedback, !notice.isError else { return }
            do { try await Task.sleep(for: .milliseconds(1800)) } catch { return }
            guard feedback?.id == notice.id else { return }
            withAnimation(.easeOut(duration: 0.22)) { feedback = nil }
        }
        .sensoryFeedback(trigger: feedback?.id) { _, newID in
            guard hapticsEnabled, newID != nil, let notice = feedback else { return nil }
            return notice.isError ? .error : .success
        }
        .sensoryFeedback(trigger: durationPreset) { _, _ in hapticsEnabled ? .selection : nil }
        .sensoryFeedback(trigger: editingCover) { _, _ in hapticsEnabled ? .selection : nil }
        .sensoryFeedback(trigger: stageMode) { _, _ in hapticsEnabled ? .impact(weight: .light) : nil }
        .onDisappear { stopPlayback() }
        .task { library.refresh() }
    }

    // MARK: - Home

    private var pickerHome: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            homeWithEdges
                .allowsHitTesting(!isWorking)
        }
        .overlay(alignment: .bottom) {
            if !editorOpen {
                statusOverlay
                    .padding(.bottom, 16)
                    .allowsHitTesting(feedback?.isError == true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if !editorOpen { library.refresh(in: currentAlbum) }
        }
    }

    private var currentAlbum: PHAssetCollection? {
        library.albums.first { $0.localIdentifier == albumID }
    }

    private var albumTitle: String {
        currentAlbum?.localizedTitle ?? "所有视频"
    }

    @ViewBuilder private var homeWithEdges: some View {
        if #available(iOS 26.0, *) {
            homeContent
                .safeAreaBar(edge: .top, spacing: 0) { homeHeader }
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: 14).allowsHitTesting(false).accessibilityHidden(true)
                }
                .scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            homeContent
                .safeAreaInset(edge: .top, spacing: 0) {
                    homeHeader.background(.regularMaterial)
                }
        }
    }

    private var homeHeader: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 0) {
                Text("LivePhoto Pro")
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .accessibilityAddTraits(.isHeader)
                if proUnlocked {
                    Label("Pro+ 已解锁", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ProStyle.gradient)
                        .transition(.blurReplace)
                }
            }
            Spacer(minLength: 0)
            StudioGlassGroup(spacing: 8) {
                HStack(spacing: 9) {
                    if !proUnlocked {
                        Button {
                            showsPaywall = true
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(ProStyle.gradient)
                                .symbolEffect(.pulse, options: .repeat(2), value: proBannerDismissed)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .studioGlass(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("LivePhoto Pro+")
                        .transition(.scale.combined(with: .opacity))
                    }
                    Menu {
                        Button("所有视频") { selectAlbum(nil) }
                        ForEach(library.albums, id: \.localIdentifier) { album in
                            Button(album.localizedTitle ?? "相簿") { selectAlbum(album) }
                        }
                        Divider()
                        Button("系统照片选择器", systemImage: "photo.on.rectangle") { showsPhotoPicker = true }
                        Button("从文件导入", systemImage: "folder") { showsFilePicker = true }
                    } label: {
                        HStack(spacing: 5) {
                            Text("相簿").font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                        .studioGlass(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        advancedDefaults = false
                        showsSettingsSheet = true
                    } label: {
                        circleControl("gearshape")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("设置")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 3)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .animation(spring, value: proUnlocked)
    }

    private func selectAlbum(_ album: PHAssetCollection?) {
        withAnimation(spring) { albumID = album?.localIdentifier }
        library.refresh(in: album)
    }

    @ViewBuilder private var homeContent: some View {
        if library.canBrowse {
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("library-top")
                    if !proUnlocked && !proBannerDismissed {
                        proBanner
                    }
                    librarySectionHeader
                    if !library.videos.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                            ForEach(library.videos) { entry in
                                videoTile(entry)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 9)
                    } else if library.isLoading || !library.hasLoaded {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                            ForEach(0..<9) { index in
                                ShimmerTile(delay: Double(index) * 0.06)
                                    .aspectRatio(0.86, contentMode: .fit)
                            }
                        }
                        .padding(.horizontal, 16)
                        .accessibilityLabel("正在载入视频")
                    } else {
                        ContentUnavailableView("没有视频", systemImage: "film",
                                               description: Text("可从右上角的「相簿」选取视频。"))
                            .padding(.top, 40)
                    }
                }
                .scrollIndicators(.hidden)
                .refreshable { library.refresh(in: currentAlbum) }
                .onChange(of: albumID) { _, _ in
                    withAnimation(spring) { proxy.scrollTo("library-top") }
                }
                .animation(spring, value: proBannerDismissed)
                .animation(spring, value: proUnlocked)
            }
        } else {
            permissionView
        }
    }

    private var librarySectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(albumTitle)
                .font(.title3.weight(.semibold))
                .contentTransition(.interpolate)
            if library.hasLoaded {
                Text("\(library.videos.count) 个视频")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(library.videos.count)))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .animation(spring, value: library.videos.count)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var proBanner: some View {
        Button {
            showsPaywall = true
        } label: {
            HStack(spacing: 12) {
                ProGlyph(size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("解锁 LivePhoto Pro+")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("批量转换 · 导出预设 · iCloud 同步")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("免费试用")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(ProStyle.gradient, in: Capsule())
            }
            .padding(12)
            .padding(.trailing, 4)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(ProStyle.gradient(opacity: colorScheme == .dark ? 0.16 : 0.10))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(ProStyle.gradient(opacity: 0.35), lineWidth: 0.8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(spring) { proBannerDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.thinMaterial, in: Circle())
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 10, y: -12)
            .accessibilityLabel("隐藏推广")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: -8)),
            removal: .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
        ))
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "livephoto.play")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .padding(.bottom, 4)
            Text("选择一段视频")
                .font(.title2.bold())
            Text("视频样本原样封装为实况照片，不重编码、不降画质。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showsPhotoPicker = true
            } label: {
                Text("从照片选择").font(.body.weight(.semibold)).padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.top, 6)
            if library.canRequest {
                Button("在首页显示我的视频") {
                    Task { await library.requestAccess() }
                }
                .font(.subheadline.weight(.medium))
            } else {
                Button("管理照片权限") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.subheadline.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func circleControl(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .imageScale(.medium)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .studioGlass(Circle())
    }

    @ViewBuilder
    private func videoTile(_ entry: LibraryVideo) -> some View {
        let id = entry.id
        let tile = Button {
            guard !isWorking else { return }
            feedback = nil
            isWorking = true
            workingStatus = "正在载入视频…"
            Task { @MainActor in
                let result: Result<ImportedVideo, Error>
                do { result = .success(try await ImportedVideo.fromPhotoAsset(entry.asset)) }
                catch { result = .failure(error) }
                await finishImport(result, assetID: id)
            }
        } label: {
            LibraryThumbnail(asset: entry.asset, assetID: id,
                             entrance: library.entranceRank(for: id),
                             didEnter: { library.markEntered(id) })
                .aspectRatio(0.86, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .accessibilityLabel("视频，\(timestamp(entry.asset.duration))")
        .accessibilityIdentifier("home.video.\(id)")
        if #available(iOS 18.0, *), !reduceMotion {
            tile.matchedTransitionSource(id: id, in: clipNavigation)
        } else { tile }
    }

    // MARK: - Editor

    private func editor(onBack: @escaping () -> Void) -> some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                previewStage(onBack: onBack)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsTrimPresets, let specification {
                    presetChips(specification)
                        .padding(.top, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let specification {
                    filmstrip(specification)
                        .padding(.vertical, 10)
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                        .background(Color(uiColor: .systemBackground))
                        .zIndex(1)
                }
                Rectangle().fill(Color(uiColor: .separator).opacity(0.4)).frame(height: 1)
                editorDock
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .systemBackground))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: source?.url) {
            guard let url = source?.url, let spec = specification else { return }
            let frames = await LivePhotoConverter.filmstripFrames(at: url, duration: spec.durationSeconds)
            guard !Task.isCancelled, source?.url == url else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                timelineFrames = frames
            }
            if !useCustomCoverTime { coverPreviewImage = frames.first.flatMap { $0 } }
            if let first = frames.first.flatMap({ $0 }) {
                let backdrop = await Task.detached(priority: .utility) {
                    BackdropRenderer.render(first)
                }.value
                guard !Task.isCancelled, source?.url == url else { return }
                withAnimation(.easeInOut(duration: 0.6)) { editorBackdrop = backdrop }
            }
        }
        .task(id: useCustomCoverTime ? customCoverTimeSeconds : nil) {
            guard editingCover, useCustomCoverTime, let url = source?.url else { return }
            let selectedTime = customCoverTimeSeconds
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            let image = await LivePhotoConverter.extractPreviewFrame(at: url, seconds: selectedTime,
                                                                       maximumDimension: 480)
            guard !Task.isCancelled, source?.url == url, customCoverTimeSeconds == selectedTime else { return }
            if let image { coverPreviewImage = image }
        }
        .onDisappear { stopPlayback() }
    }

    private func previewStage(onBack: @escaping () -> Void) -> some View {
        ZStack {
            previewMedia
                .ignoresSafeArea(.container, edges: .top)
                .accessibilityHidden(stageMode == .video)
        }
        .overlay(alignment: .top) {
            StudioGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        stopPlayback()
                        onBack()
                    } label: {
                        circleControl("chevron.left")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回视频")
                    .accessibilityIdentifier("editor.back")
                    Spacer(minLength: 4)
                    if stageMode == .livePhoto {
                        liveBadge
                            .transition(.blurReplace.combined(with: .scale(0.85)))
                    }
                    Spacer(minLength: 4)
                    Menu {
                        Button("预览实况", systemImage: "livephoto") { Task { await convertForInAppPreviewOnly() } }
                        if stageMode == .livePhoto {
                            Button("回到原视频", systemImage: "film") { withAnimation(spring) { stageMode = .video } }
                        }
                        Button("本次导出选项", systemImage: "slider.horizontal.3") {
                            advancedExport = false
                            showsExportSheet = true
                        }
                        Button("导出配对文件", systemImage: "square.and.arrow.up") {
                            if let files = generatedFiles {
                                shareItems = [files.photoURL, files.movieURL]
                                showsShareSheet = true
                            }
                        }
                        .disabled(generatedFiles == nil)
                    } label: {
                        circleControl("ellipsis")
                    }
                    .buttonStyle(.plain).accessibilityLabel("更多")
                    .disabled(isWorking)
                    saveButton
                }
            }
            .padding(.horizontal, 15).padding(.top, 8)
            .foregroundStyle(.white).environment(\.colorScheme, .dark)
            .animation(spring, value: stageMode)
        }
        .overlay(alignment: .bottomLeading) {
            Button(action: togglePlayback) {
                circleControl(isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white).environment(\.colorScheme, .dark)
            .padding(15).accessibilityLabel(isPlaying ? "暂停" : "播放")
            .disabled(isWorking)
        }
        .overlay(alignment: .bottom) {
            statusOverlay.padding(.horizontal, 58).padding(.bottom, 18)
                .allowsHitTesting(feedback?.isError == true)
        }
        .accessibilityElement(children: .contain)
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "livephoto")
                .font(.system(size: 13, weight: .semibold))
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            Text("实况")
                .font(.footnote.weight(.semibold))
            if export.zoomOff {
                Text("1:1")
                    .font(.caption2.weight(.heavy).monospacedDigit())
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .studioGlass(Capsule(), interactive: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(export.zoomOff ? "实况预览，1:1 不放大" : "实况预览")
    }

    private var saveButton: some View {
        Button {
            Task { await convertAndSaveToPhotos() }
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    if isWorking {
                        ProgressView().controlSize(.small).tint(.white)
                            .transition(.blurReplace)
                    } else {
                        Image(systemName: justSaved ? "checkmark" : "square.and.arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .transition(.blurReplace)
                    }
                }
                .frame(width: 20)
                Text(isWorking ? "处理中" : (justSaved ? "已保存" : "保存"))
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.interpolate)
            }
            .padding(.horizontal, 14).frame(height: 44)
            .contentShape(Rectangle())
            .studioGlass(Capsule(), tint: justSaved ? .green.opacity(0.75) : Color.accentColor.opacity(0.85))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .animation(spring, value: isWorking)
        .animation(spring, value: justSaved)
        .accessibilityLabel(justSaved ? "已保存到相册" : "保存到相册")
    }

    private var previewMedia: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let editorBackdrop, !fillsPortrait {
                    Image(decorative: editorBackdrop, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .overlay(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.2))
                        .transition(.opacity)
                }
                if stageMode == .livePhoto, let generatedLivePhoto {
                    LivePhotoPreviewView(livePhoto: generatedLivePhoto, isMuted: !export.audio,
                                         playbackTrigger: livePhotoPlaybackTrigger, fillsPortrait: fillsPortrait)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .transition(.opacity)
                } else if let player {
                    OriginalVideoSurface(player: player, fillsPortrait: fillsPortrait)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: stageMode)
        }
    }

    private var fillsPortrait: Bool {
        guard let size = specification?.naturalSize, size.height > 0 else { return false }
        return abs(size.width / size.height - 9.0 / 16.0) < 0.012
    }

    private var editorDock: some View {
        HStack(spacing: 6) {
            dockButton(title: "裁剪", icon: "scissors", isActive: showsTrimPresets) {
                stopPlayback()
                withAnimation(spring) {
                    showsTrimPresets.toggle()
                    if showsTrimPresets { editingCover = false }
                }
            }
            dockButton(title: editingCover ? "完成" : "封面",
                       icon: editingCover ? "checkmark" : "photo",
                       isActive: editingCover) {
                stopPlayback()
                stageMode = .video
                if !editingCover {
                    let beginning = effectiveTrimRange?.lowerBound ?? 0
                    playhead = useCustomCoverTime ? customCoverTimeSeconds : beginning
                    seekPlayer(to: playhead)
                }
                withAnimation(spring) {
                    editingCover.toggle()
                    if editingCover { showsTrimPresets = false }
                }
            }
            dockButton(title: "重播", icon: "arrow.counterclockwise", isActive: false, action: replay)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .studioGlass(Capsule())
        .disabled(isWorking)
    }

    private func dockButton(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.caption2.weight(.medium))
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .frame(width: 62, height: 44)
            .background {
                if isActive {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.14))
                        .matchedGeometryEffect(id: "dock.selection", in: editorNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func presetChips(_ spec: VideoSpecification) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DurationPreset.allCases) { preset in
                    let isSelected = durationPreset == preset
                    Button {
                        withAnimation(spring) { setPreset(preset, spec: spec) }
                    } label: {
                        HStack(spacing: 5) {
                            if preset == .full {
                                Image(systemName: "infinity").font(.system(size: 11, weight: .bold))
                            }
                            Text(preset.rawValue)
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .matchedGeometryEffect(id: "preset.selection", in: editorNamespace)
                            } else {
                                Capsule().fill(Color(uiColor: .tertiarySystemFill))
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 18)
        }
        .scrollClipDisabled()
    }

    private func filmstrip(_ spec: VideoSpecification) -> some View {
        let total = max(0.1, spec.durationSeconds)
        let range = effectiveTrimRange ?? 0...total
        return VStack(spacing: 6) {
            HStack {
                Text(timestamp(range.lowerBound))
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: editingCover ? "photo" : "timer")
                        .font(.system(size: 9, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(editingCover ? "封面 \(preciseTimestamp(playhead))" : "片段 \(preciseTimestamp(effectiveOutputDuration))")
                }
                .foregroundStyle(editingCover ? Color.accentColor : Color.primary)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                Spacer()
                Text(timestamp(range.upperBound))
            }
            .font(.caption2.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
            .animation(spring, value: editingCover)
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                let start = width * CGFloat(range.lowerBound / total)
                let end = width * CGFloat(range.upperBound / total)
                let marker = width * CGFloat(min(1, max(0, playhead / total)))
                ZStack(alignment: .leading) {
                    HStack(spacing: 1) {
                        ForEach(0..<8) { index in
                            GeometryReader { box in
                                if timelineFrames.indices.contains(index), let frame = timelineFrames[index] {
                                    Image(decorative: frame, scale: 1)
                                        .resizable().scaledToFill()
                                        .frame(width: box.size.width, height: box.size.height).clipped()
                                        .transition(.opacity)
                                } else {
                                    Color(uiColor: .tertiarySystemFill)
                                }
                            }
                        }
                    }
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { scrub(to: Double($0.location.x / width) * total, within: range, live: true) }
                        .onEnded { scrub(to: Double($0.location.x / width) * total, within: range) })
                    if !editingCover {
                        Color.black.opacity(0.42).frame(width: max(0, start))
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9, style: .continuous))
                            .allowsHitTesting(false)
                        Color.black.opacity(0.42).frame(width: max(0, width - end)).offset(x: end)
                            .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 9, topTrailingRadius: 9, style: .continuous))
                            .allowsHitTesting(false)
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(draggingHandle == nil ? Color.white.opacity(0.9) : Color.accentColor, lineWidth: 2)
                            .frame(width: max(2, end - start), height: 48)
                            .offset(x: start)
                            .allowsHitTesting(false)
                        trimHandle(x: start, leading: true, width: width, total: total, range: range)
                        trimHandle(x: end, leading: false, width: width, total: total, range: range)
                    }
                    Capsule()
                        .fill(editingCover ? Color.accentColor : .white)
                        .frame(width: 3, height: 54)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .offset(x: marker - 1.5)
                        .allowsHitTesting(false)
                    if editingCover, let coverPreviewImage {
                        Image(decorative: coverPreviewImage, scale: 1)
                            .resizable().scaledToFill()
                            .frame(width: 72, height: 46).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                            .offset(x: min(max(0, marker - 36), width - 72), y: -58)
                            .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .coordinateSpace(name: "strip")
                .animation(spring, value: editingCover)
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: draggingHandle)
            }
            .frame(height: 48)
            .padding(.horizontal, 9)
            .accessibilityElement()
            .accessibilityLabel(editingCover ? "选择封面" : "播放位置")
            .accessibilityValue(timestamp(playhead))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: scrub(to: playhead + 0.25, within: range)
                case .decrement: scrub(to: playhead - 0.25, within: range)
                @unknown default: break
                }
            }
        }
        .padding(.horizontal, 18)
        .disabled(isWorking)
    }

    private func trimHandle(x: CGFloat, leading: Bool, width: CGFloat, total: Double,
                            range: ClosedRange<Double>) -> some View {
        let index = leading ? 0 : 1
        let isActive = draggingHandle == index
        return Image(systemName: leading ? "chevron.compact.left" : "chevron.compact.right")
            .font(.system(size: 13, weight: .heavy))
            .foregroundStyle(isActive ? Color.white : Color.black.opacity(0.65))
            .frame(width: 15, height: 48)
            .background(isActive ? Color.accentColor : .white,
                        in: UnevenRoundedRectangle(topLeadingRadius: leading ? 9 : 0,
                                                   bottomLeadingRadius: leading ? 9 : 0,
                                                   bottomTrailingRadius: leading ? 0 : 9,
                                                   topTrailingRadius: leading ? 0 : 9,
                                                   style: .continuous))
            .scaleEffect(y: isActive ? 1.1 : 1)
            .frame(width: 30, height: 48)
            .contentShape(Rectangle())
            .offset(x: x - 15)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
                if draggingHandle != index { draggingHandle = index }
                let seconds = max(0, min(total, Double(value.location.x / width) * total))
                if durationPreset != .custom {
                    trimStartSeconds = range.lowerBound
                    trimEndSeconds = range.upperBound
                    durationPreset = .custom
                }
                if generatedFiles != nil { invalidateOutput() }
                if leading { trimStartSeconds = min(seconds, max(0, trimEndSeconds - 0.1)) }
                else { trimEndSeconds = max(seconds, min(total, trimStartSeconds + 0.1)) }
                scrub(to: leading ? trimStartSeconds : trimEndSeconds,
                      within: trimStartSeconds...trimEndSeconds, live: true)
            }.onEnded { _ in
                draggingHandle = nil
                scrub(to: leading ? trimStartSeconds : trimEndSeconds,
                      within: trimStartSeconds...trimEndSeconds)
            })
            .sensoryFeedback(trigger: isActive) { _, active in hapticsEnabled && active ? .selection : nil }
            .accessibilityLabel(leading ? "裁剪起点" : "裁剪终点")
    }

    private var statusOverlay: some View {
        ZStack {
            if isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(workingStatus)
                        .contentTransition(.interpolate)
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 11)
                .studioGlass(Capsule(), interactive: false)
                .transition(.blurReplace.combined(with: .scale(0.9)))
            } else if let feedback {
                Button {
                    withAnimation(spring) { self.feedback = nil }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: feedback.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(feedback.color)
                            .symbolEffect(.bounce, value: feedback.id)
                        Text(feedback.text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .studioGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain).padding(.horizontal, 18)
                .transition(.blurReplace.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82), value: isWorking)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82), value: feedback?.id)
    }

    // MARK: - Settings

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var settingsPanel: some View {
        NavigationStack {
            Form {
                Section {
                    proStatusCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    Toggle(isOn: $disablePlaybackZoom) {
                        SettingsLabel(title: "防止播放放大", subtitle: "长按播放保持 1:1 原画比例",
                                      icon: "arrow.up.left.and.arrow.down.right", color: .blue)
                    }
                    Toggle(isOn: $includeAudio) {
                        SettingsLabel(title: "保留声音", subtitle: "AAC 直通，其他格式自动转码",
                                      icon: "speaker.wave.2.fill", color: .pink)
                    }
                    Toggle(isOn: $fullFrameRateIntent) {
                        SettingsLabel(title: "高帧率播放", subtitle: "60 / 120 fps 回放不抽帧",
                                      icon: "gauge.with.dots.needle.67percent", color: .green)
                    }
                } header: {
                    Text("默认导出")
                } footer: {
                    Text("新打开的视频会沿用这些设置；也可在编辑页「更多 → 本次导出选项」里单独调整。")
                }

                Section {
                    Picker(selection: $coverFormatRaw) {
                        Text("JPEG").tag(CoverImageFormat.jpeg.rawValue)
                        Text("HEIC").tag(CoverImageFormat.heic.rawValue)
                    } label: {
                        SettingsLabel(title: "封面格式", icon: "photo.fill", color: .orange)
                    }
                    Picker(selection: $apertureModeRaw) {
                        Text("完整像素").tag(CoverApertureMode.encodedPixels.rawValue)
                        Text("有效画面").tag(CoverApertureMode.cleanAperture.rawValue)
                    } label: {
                        SettingsLabel(title: "封面取景", icon: "crop", color: .purple)
                    }
                } header: {
                    Text("封面")
                } footer: {
                    Text("「完整像素」按编码尺寸生成封面，与视频画面严格对齐，推荐保持默认。")
                }

                Section {
                    Toggle(isOn: $hapticsEnabled) {
                        SettingsLabel(title: "触感反馈", icon: "hand.tap.fill", color: .teal)
                    }
                } header: {
                    Text("交互")
                }

                Section {
                    NavigationLink {
                        AntiZoomExplainer()
                    } label: {
                        SettingsLabel(title: "1:1 防放大原理", icon: "info.circle.fill", color: .indigo)
                    }
                    NavigationLink {
                        VerifyGuideView()
                    } label: {
                        SettingsLabel(title: "校验导出文件", icon: "checkmark.seal.fill", color: .mint)
                    }
                    LabeledContent {
                        Text(appVersion).monospacedDigit()
                    } label: {
                        SettingsLabel(title: "版本", icon: "number", color: .gray)
                    }
                } header: {
                    Text("关于")
                } footer: {
                    VStack(spacing: 4) {
                        Image(systemName: "livephoto")
                            .font(.system(size: 18, weight: .light))
                        Text("无损 · 原画 · 实况")
                    }
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22)
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showsSettingsSheet = false }.fontWeight(.semibold) } }
            .fullScreenCover(isPresented: $showsPaywallFromSettings) {
                ProPaywallView(isUnlocked: $proUnlocked, hapticsEnabled: hapticsEnabled)
            }
        }
        .presentationDragIndicator(.visible)
        .sensoryFeedback(trigger: coverFormatRaw) { _, _ in hapticsEnabled ? .selection : nil }
        .sensoryFeedback(trigger: apertureModeRaw) { _, _ in hapticsEnabled ? .selection : nil }
    }

    private var proStatusCard: some View {
        Button {
            showsPaywallFromSettings = true
        } label: {
            HStack(spacing: 14) {
                ProGlyph(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LivePhoto Pro+")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(proUnlocked ? "已解锁全部功能（演示）" : "批量转换、导出预设与 iCloud 同步")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.interpolate)
                }
                Spacer(minLength: 4)
                Image(systemName: proUnlocked ? "checkmark.seal.fill" : "chevron.right")
                    .font(.system(size: proUnlocked ? 20 : 14, weight: .semibold))
                    .foregroundStyle(proUnlocked ? AnyShapeStyle(ProStyle.gradient) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(ProStyle.gradient(opacity: colorScheme == .dark ? 0.18 : 0.10))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(ProStyle.gradient(opacity: 0.4), lineWidth: 0.8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .animation(spring, value: proUnlocked)
    }

    private var exportPanel: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $export.zoomOff) {
                        SettingsLabel(title: "防止播放放大", icon: "arrow.up.left.and.arrow.down.right", color: .blue)
                    }
                    Toggle(isOn: $export.audio) {
                        SettingsLabel(title: "保留声音", icon: "speaker.wave.2.fill", color: .pink)
                    }
                } header: { Text("仅对当前视频生效") }
                Section {
                    advancedSection(expanded: $advancedExport, highRate: $export.highRate,
                                    format: $export.format, aperture: $export.aperture)
                }
            }
            .navigationTitle("本次导出").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showsExportSheet = false }.fontWeight(.semibold) } }
        }
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
        .onChange(of: export.zoomOff) { _, _ in invalidateOutput() }
        .onChange(of: export.highRate) { _, _ in invalidateOutput() }
        .onChange(of: export.audio) { _, _ in invalidateOutput() }
        .onChange(of: export.format) { _, _ in invalidateOutput() }
        .onChange(of: export.aperture) { _, _ in invalidateOutput() }
    }

    private func advancedSection(expanded: Binding<Bool>, highRate: Binding<Bool>, format: Binding<String>,
                                 aperture: Binding<String>) -> some View {
        DisclosureGroup(isExpanded: expanded.animation(spring)) {
            Toggle("高帧率播放", isOn: highRate)
            Picker("封面格式", selection: format) {
                ForEach(CoverImageFormat.allCases) { choice in Text(choice.rawValue).tag(choice.rawValue) }
            }
            Picker("封面取景", selection: aperture) {
                Text("完整像素").tag(CoverApertureMode.encodedPixels.rawValue)
                Text("有效画面").tag(CoverApertureMode.cleanAperture.rawValue)
            }
        } label: {
            SettingsLabel(title: "高级", icon: "slider.horizontal.3", color: .gray)
        }
    }

    // MARK: - Editing Helpers

    private func invalidateOutput() {
        cleanupGeneratedFiles()
        stageMode = .video
        feedback = nil
        justSaved = false
    }

    private func setPreset(_ preset: DurationPreset, spec: VideoSpecification) {
        stopPlayback()
        if preset == .custom {
            trimStartSeconds = effectiveTrimRange?.lowerBound ?? 0
            trimEndSeconds = effectiveTrimRange?.upperBound ?? spec.durationSeconds
        }
        durationPreset = preset
        invalidateOutput()
        playhead = effectiveTrimRange?.lowerBound ?? 0
        seekPlayer(to: playhead)
    }

    private func scrub(to seconds: Double, within range: ClosedRange<Double>, live: Bool = false) {
        if isPlaying { stopPlayback() }
        let time = min(max(seconds, range.lowerBound), range.upperBound)
        playhead = time
        stageMode = .video
        let now = ProcessInfo.processInfo.systemUptime
        if !live || now - lastScrubSeek >= 0.075 {
            lastScrubSeek = now
            seekPlayer(to: time, approximate: live)
        }
        if editingCover {
            if generatedFiles != nil { invalidateOutput() }
            useCustomCoverTime = true
            customCoverTimeSeconds = min(time, max(range.lowerBound, range.upperBound - 0.02))
            if !timelineFrames.isEmpty, let duration = specification?.durationSeconds, duration > 0 {
                let index = Int((customCoverTimeSeconds / duration * Double(timelineFrames.count - 1)).rounded())
                if let frame = timelineFrames[min(timelineFrames.count - 1, max(0, index))] {
                    coverPreviewImage = frame
                }
            }
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func preciseTimestamp(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, seconds) : 0
        let minutes = Int(value) / 60
        return String(format: "%d:%04.1f", minutes, value - Double(minutes * 60))
    }

    private func stopPlayback() {
        if let playbackObserver { player?.removeTimeObserver(playbackObserver) }
        playbackObserver = nil
        player?.pause()
        isPlaying = false
    }

    private func replay() {
        if stageMode == .livePhoto { livePhotoPlaybackTrigger += 1; return }
        stopPlayback()
        playhead = effectiveTrimRange?.lowerBound ?? 0
        seekPlayer(to: playhead)
        togglePlayback()
    }

    private func togglePlayback() {
        if stageMode == .livePhoto { livePhotoPlaybackTrigger += 1; return }
        if isPlaying { stopPlayback(); return }
        guard let player, let specification else { return }
        let range = effectiveTrimRange ?? 0...specification.durationSeconds
        if playhead < range.lowerBound || playhead >= range.upperBound - 0.04 {
            seekPlayer(to: range.lowerBound)
        }
        isPlaying = true
        player.isMuted = !export.audio
        player.play()
        playbackObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.10, preferredTimescale: 600), queue: .main
        ) { time in
            Task { @MainActor in
                guard isPlaying, time.seconds.isFinite else { return }
                playhead = time.seconds
                if playhead >= range.upperBound - 0.025 || player.currentItem?.duration.seconds == playhead {
                    stopPlayback()
                }
            }
        }
    }

    // MARK: - Actions & Helpers

    private func seekPlayer(to seconds: Double, approximate: Bool = false) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let tolerance = approximate ? CMTime(seconds: 0.12, preferredTimescale: 600) : .zero
        player?.currentItem?.cancelPendingSeeks()
        player?.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    @MainActor
    private func finishImport(_ result: Result<ImportedVideo, Error>, assetID: String? = nil) async {
        showsPhotoPicker = false
        switch result {
        case .success(let imported):
            workingStatus = "正在解析视频…"
            do {
                let spec = try await LivePhotoConverter.inspectVideo(at: imported.url, thumbnailCount: 0)
                stopPlayback()
                player?.replaceCurrentItem(with: nil)
                cleanupGeneratedFiles()
                source?.remove()

                source = imported
                specification = spec
                export = inheritedExport
                playhead = 0
                editingCover = false
                showsTrimPresets = false
                justSaved = false
                player = AVPlayer(url: imported.url)
                stageMode = .video
                durationPreset = .full
                trimStartSeconds = 0.0
                trimEndSeconds = spec.durationSeconds
                useCustomCoverTime = false
                customCoverTimeSeconds = 0.0
                timelineFrames = []
                coverPreviewImage = nil
                editorBackdrop = nil
                isWorking = false
                editorPath.append(EditorRoute(sourceID: assetID))
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
        workingStatus = "正在生成预览…"
        feedback = nil
        stopPlayback()
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
                withAnimation(spring) {
                    stageMode = .livePhoto
                }
                feedback = .success("长按画面即可预览实况")
            } else {
                feedback = .success("实况配对文件已生成，可在「更多」中导出或直接保存。")
            }
        } catch {
            feedback = .error("生成实况预览失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private func convertAndSaveToPhotos() async {
        guard let source, !isWorking else { return }
        isWorking = true
        workingStatus = "正在存入相册…"
        feedback = nil
        justSaved = false
        stopPlayback()
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
                withAnimation(spring) {
                    stageMode = .livePhoto
                }
            }

            feedback = .success(String(format: "已存入相册 · %.1f 秒实况", result.outputDurationSeconds))
            justSaved = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation(spring) { justSaved = false }
            }
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
        let id = UUID()
        let text: String
        let icon: String
        let color: Color
        let isError: Bool

        static func success(_ text: String) -> Self {
            Self(text: text, icon: "checkmark.circle.fill", color: .green, isError: false)
        }

        static func error(_ text: String) -> Self {
            Self(text: text, icon: "exclamationmark.triangle.fill", color: .red, isError: true)
        }
    }
}

// MARK: - Pro+ Style

private enum ProStyle {
    static let colors: [Color] = [
        Color(red: 0.36, green: 0.46, blue: 1.00),
        Color(red: 0.62, green: 0.38, blue: 0.98),
        Color(red: 1.00, green: 0.50, blue: 0.52)
    ]

    static var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func gradient(opacity: Double) -> LinearGradient {
        LinearGradient(
            colors: colors.map { $0.opacity(opacity) },
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Small squircle mark used for Pro+ entry points.
private struct ProGlyph: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(ProStyle.gradient)
            Image(systemName: "livephoto")
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(.white)
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.2, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: size * 0.27, y: -size * 0.27)
        }
        .frame(width: size, height: size)
        .shadow(color: ProStyle.colors[1].opacity(0.35), radius: size * 0.18, y: size * 0.08)
        .accessibilityHidden(true)
    }
}

private struct SettingsLabel: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Placeholder tile with a soft, slow pulse while the library is loading.
private struct ShimmerTile: View {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(uiColor: .secondarySystemFill))
            .phaseAnimator(reduceMotion ? [Double(1.0)] : [Double(1.0), 0.55]) { content, opacity in
                content.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.9).delay(delay)
            }
    }
}

// MARK: - Pro+ Paywall (demo)

private enum ProPlan: String, CaseIterable, Identifiable {
    case yearly, monthly, lifetime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yearly: return "年度"
        case .monthly: return "月度"
        case .lifetime: return "终身"
        }
    }

    var price: String {
        switch self {
        case .yearly: return "¥98"
        case .monthly: return "¥12"
        case .lifetime: return "¥198"
        }
    }

    var detail: String {
        switch self {
        case .yearly: return "7 天免费试用，约 ¥8.2 / 月"
        case .monthly: return "按月订阅，随时取消"
        case .lifetime: return "一次购买，永久使用"
        }
    }

    var badge: String? {
        self == .yearly ? "省 32%" : nil
    }

    var callToAction: String {
        switch self {
        case .yearly: return "开始 7 天免费试用"
        case .monthly: return "以 ¥12 / 月订阅"
        case .lifetime: return "以 ¥198 永久解锁"
        }
    }
}

private struct ProPaywallView: View {
    @Binding var isUnlocked: Bool
    let hapticsEnabled: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var plan: ProPlan = .yearly
    @State private var appeared = false
    @State private var isPurchasing = false
    @State private var purchased = false
    @State private var demoAlertTitle = ""
    @State private var demoAlertMessage = ""
    @State private var showsDemoAlert = false
    @Namespace private var planNamespace

    private static let features: [(icon: String, title: String, detail: String)] = [
        ("square.stack.3d.up.fill", "批量转换", "一次选择多段视频，排队无损封装"),
        ("slider.horizontal.3", "导出预设", "保存常用时长、封面与音频参数"),
        ("icloud.fill", "iCloud 同步", "预设在 iPhone 与 iPad 之间同步"),
        ("wand.and.stars", "智能封面", "自动挑选清晰、无模糊的关键帧")
    ]

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            LinearGradient(colors: [ProStyle.colors[0].opacity(0.16), ProStyle.colors[1].opacity(0.06), .clear],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    hero
                    featureList
                    planPicker
                    Text("演示页面 · 不会发起任何真实扣费")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 8)
                }
                .padding(.horizontal, 22)
                .padding(.top, 36)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) { purchaseBar }

            if purchased {
                successOverlay
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !purchased {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(.thinMaterial, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14)
                .padding(.top, 6)
                .accessibilityLabel("关闭")
            }
        }
        .alert(demoAlertTitle, isPresented: $showsDemoAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(demoAlertMessage)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.85)) { appeared = true }
        }
        .sensoryFeedback(trigger: plan) { _, _ in hapticsEnabled ? .selection : nil }
        .sensoryFeedback(trigger: purchased) { _, done in hapticsEnabled && done ? .success : nil }
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: purchased)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84), value: isUnlocked)
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ProHeroMark()
                .frame(width: 124, height: 124)
                .scaleEffect(appeared ? 1 : 0.7)
                .opacity(appeared ? 1 : 0)
            VStack(spacing: 6) {
                Text("LivePhoto Pro+")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("为每一帧都认真的人")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .offset(y: appeared ? 0 : 12)
            .opacity(appeared ? 1 : 0)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(Self.features.enumerated()), id: \.offset) { index, feature in
                HStack(spacing: 14) {
                    Image(systemName: feature.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(ProStyle.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title).font(.subheadline.weight(.semibold))
                        Text(feature.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .offset(x: appeared ? 0 : -18)
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85)
                    .delay(0.12 + Double(index) * 0.06), value: appeared)
            }
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var planPicker: some View {
        VStack(spacing: 10) {
            ForEach(ProPlan.allCases) { item in
                planRow(item)
            }
        }
        .offset(y: appeared ? 0 : 20)
        .opacity(appeared ? 1 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85).delay(0.3), value: appeared)
    }

    private func planRow(_ item: ProPlan) -> some View {
        let isSelected = plan == item
        return Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { plan = item }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Color.clear : Color.secondary.opacity(0.4), lineWidth: 1.5)
                    if isSelected {
                        Circle().fill(ProStyle.gradient)
                            .transition(.scale.combined(with: .opacity))
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .transition(.scale)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title).font(.headline)
                        if let badge = item.badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(ProStyle.gradient, in: Capsule())
                        }
                    }
                    Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(item.price)
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                if isSelected {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(ProStyle.gradient(opacity: 0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(ProStyle.gradient, lineWidth: 2)
                        }
                        .matchedGeometryEffect(id: "plan.selection", in: planNamespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var purchaseBar: some View {
        VStack(spacing: 10) {
            if isUnlocked && !purchased {
                Label("已解锁 LivePhoto Pro+（演示）", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ProStyle.gradient)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(ProStyle.gradient(opacity: 0.12), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(ProStyle.gradient(opacity: 0.45), lineWidth: 1)
                    }
                Button("重置为未解锁（重新体验演示）") {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84)) {
                        isUnlocked = false
                    }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            } else {
                Button {
                    purchase()
                } label: {
                    ZStack {
                        if isPurchasing {
                            ProgressView().tint(.white)
                                .transition(.blurReplace)
                        } else {
                            Text(plan.callToAction)
                                .font(.headline)
                                .contentTransition(.interpolate)
                                .transition(.blurReplace)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(ProStyle.gradient, in: Capsule())
                    .shadow(color: ProStyle.colors[1].opacity(0.35), radius: 14, y: 6)
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                .disabled(isPurchasing)
                .animation(.spring(response: 0.38, dampingFraction: 0.82), value: plan)
                .animation(.smooth(duration: 0.3), value: isPurchasing)

                HStack(spacing: 18) {
                    Button("恢复购买") {
                        showDemoInfo("恢复购买", "演示环境中没有可恢复的购买记录。")
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Button("使用条款") {
                        showDemoInfo("使用条款", "此页面为订阅界面演示，不会发起任何真实扣费或交易。")
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Button("隐私政策") {
                        showDemoInfo("隐私政策", "所有视频转换与封面提取均在本地设备离线完成，不会上传至云端。")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func showDemoInfo(_ title: String, _ message: String) {
        demoAlertTitle = title
        demoAlertMessage = message
        showsDemoAlert = true
    }

    private var successOverlay: some View {
        ZStack {
            Color(uiColor: .systemBackground).opacity(0.94).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(ProStyle.gradient)
                    .symbolEffect(.bounce, value: purchased)
                Text("欢迎加入 Pro+")
                    .font(.title.bold())
                Text("演示模式已解锁全部功能入口。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    dismiss()
                } label: {
                    Text("开始使用")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 40)
                        .frame(height: 50)
                        .background(ProStyle.gradient, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .padding(.top, 8)
            }
            .padding(30)
        }
    }

    private func purchase() {
        guard !isPurchasing else { return }
        isPurchasing = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            isPurchasing = false
            isUnlocked = true
            purchased = true
        }
    }
}

/// Live Photo rings drawn with the Pro+ gradient; the dotted ring drifts slowly.
private struct ProHeroMark: View {
    @State private var rotation = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(ProStyle.gradient(opacity: 0.14))
            Circle()
                .stroke(AngularGradient(colors: ProStyle.colors + [ProStyle.colors[0]], center: .center),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0.1, 9]))
                .padding(10)
                .rotationEffect(.degrees(rotation))
            Circle()
                .stroke(ProStyle.gradient, lineWidth: 3.5)
                .padding(30)
            Circle()
                .fill(ProStyle.gradient)
                .padding(46)
                .phaseAnimator(reduceMotion ? [CGFloat(1)] : [CGFloat(1), CGFloat(0.86)]) { content, scale in
                    content.scaleEffect(scale)
                } animation: { _ in .easeInOut(duration: 1.4) }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 28).repeatForever(autoreverses: false)) { rotation = 360 }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Explainer Pages

private struct AntiZoomExplainer: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top, spacing: 20) {
                    comparison(title: "系统默认", factor: "1.075×", zooming: true)
                    comparison(title: "LivePhoto Pro", factor: "1.000×", zooming: false)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                step(1, "为什么会放大", "系统相册在播放支持「活力」效果的实况照片时，会在长按的 0.3 秒内把画面推进到 1.075 倍，用来掩盖相机防抖产生的边缘。")
                step(2, "如何撤销", "导出时在配对视频中写入 vitality-disabled 与零过渡分值。系统读取后不再启用该效果，播放始终保持 1:1。")
                step(3, "封面同样对齐", "封面按完整编码像素生成，避免有效画面裁切与原始尺寸不一致造成的细微形变。")
            }
            .padding(22)
        }
        .navigationTitle("1:1 防放大原理")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func comparison(title: String, factor: String, zooming: Bool) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                ZoomingSample(isZooming: zooming)
                    .padding(10)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .frame(width: 120, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(factor)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(zooming ? Color.primary : Color.accentColor)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func step(_ index: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(index)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A miniature photo that loops the system's long-press push-in when `isZooming` is true.
private struct ZoomingSample: View {
    let isZooming: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: isZooming
                                     ? [Color.gray.opacity(0.55), Color.gray.opacity(0.3)]
                                     : [Color.accentColor, Color.accentColor.opacity(0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.9))
        }
        .phaseAnimator(isZooming && !reduceMotion ? [CGFloat(1), CGFloat(1), CGFloat(1.16), CGFloat(1.16)] : [CGFloat(1)]) { content, scale in
            content.scaleEffect(scale)
        } animation: { _ in .easeInOut(duration: 0.6) }
    }
}

private struct VerifyGuideView: View {
    var body: some View {
        List {
            Section {
                Text("在「更多 → 导出配对文件」中取得 MOV 后，可在电脑上运行项目附带的脚本，逐包对比原片与导出文件的压缩视频数据、时间戳、分辨率、方向与色彩参数。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            Section {
                Text("python3 scripts/verify-video.py source.mp4 exported-paired.mov")
                    .font(.system(.footnote, design: .monospaced))
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

/// Renders a small, softly blurred copy of a frame once per clip, used behind letterboxed media.
private enum BackdropRenderer {
    nonisolated(unsafe) private static let context = CIContext()

    nonisolated static func render(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let longest = max(input.extent.width, input.extent.height)
        guard longest > 0 else { return nil }
        let scale = 120.0 / longest
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 9)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.2,
                kCIInputBrightnessKey: -0.08
            ])
            .cropped(to: small.extent)
        return context.createCGImage(blurred, from: small.extent)
    }
}

private struct LivePhotoPreviewView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let isMuted: Bool
    let playbackTrigger: Int
    let fillsPortrait: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = fillsPortrait ? .scaleAspectFill : .scaleAspectFit
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
        uiView.contentMode = fillsPortrait ? .scaleAspectFill : .scaleAspectFit
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

private struct EditorDestination<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let content: (@escaping () -> Void) -> Content

    var body: some View {
        content { dismiss() }
    }
}

private struct StudioGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

private extension View {
    @ViewBuilder func editorTransition(sourceID: String?, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *), let sourceID {
            navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else { self }
    }

    @ViewBuilder func studioGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            let base: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            self.glassEffect(interactive ? base.interactive() : base, in: shape)
        } else {
            self.background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint {
                        shape.fill(tint.opacity(0.45))
                    }
                }
            }
            .overlay {
                shape.stroke(.white.opacity(0.28), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct LibraryVideo: Identifiable {
    let id: String
    let asset: PHAsset
    let position: Int
}

@Observable @MainActor
private final class VideoLibrary {
    private(set) var videos: [LibraryVideo] = []
    private(set) var albums: [PHAssetCollection] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var entranceIDs: [String: Int] = [:]
    @ObservationIgnored private var enteredIDs: Set<String> = []
    var canBrowse: Bool { status == .authorized || status == .limited }
    var canRequest: Bool { status == .notDetermined }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh()
    }

    func entranceRank(for id: String) -> Int? { enteredIDs.contains(id) ? nil : entranceIDs[id] }
    func markEntered(_ id: String) { enteredIDs.insert(id) }

    func refresh(in album: PHAssetCollection? = nil) {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let request = UUID()
        requestID = request
        guard canBrowse else { videos = []; albums = []; isLoading = false; return }
        isLoading = true
        let albumID = album?.localIdentifier
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.snapshot(albumID: albumID)
            }.value
            guard requestID == request else { return }
            if !hasLoaded {
                entranceIDs = Dictionary(uniqueKeysWithValues: snapshot.videos.prefix(9).map { ($0.id, $0.position) })
            }
            if videos.map(\.id) != snapshot.videos.map(\.id) { videos = snapshot.videos }
            if albumID == nil { albums = snapshot.albums }
            hasLoaded = true
            isLoading = false
        }
    }

    private struct Snapshot: @unchecked Sendable {
        // PhotoKit assets and collections are immutable snapshots.
        let videos: [LibraryVideo]
        let albums: [PHAssetCollection]
    }

    nonisolated private static func snapshot(albumID: String?) -> Snapshot {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let album = albumID.flatMap { PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0], options: nil).firstObject }
        let result = album.map { PHAsset.fetchAssets(in: $0, options: options) }
            ?? PHAsset.fetchAssets(with: options)
        var videos: [LibraryVideo] = []
        result.enumerateObjects { asset, index, _ in
            videos.append(LibraryVideo(id: asset.localIdentifier, asset: asset, position: index))
        }
        var albums: [PHAssetCollection] = []
        if albumID == nil {
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
                .enumerateObjects { collection, _, _ in albums.append(collection) }
        }
        return Snapshot(videos: videos, albums: albums)
    }
}

private struct LibraryThumbnail: View {
    let asset: PHAsset
    let assetID: String
    let entrance: Int?
    let didEnter: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = true
    @State private var entranceTask: Task<Void, Never>?
    @MainActor private static let manager = PHCachingImageManager()
    @MainActor private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 90
        cache.totalCostLimit = 35 * 1024 * 1024
        return cache
    }()
    @State private var thumbnail: UIImage?
    @State private var request: PHImageRequestID?
    @State private var requestToken: UUID?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                Color(uiColor: .secondarySystemFill)
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(revealed ? 1 : 0.88)
                        .offset(y: revealed ? 0 : -19)
                        .opacity(revealed ? 1 : 0)
                        .clipped().allowsHitTesting(false)
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                let seconds = max(0, Int(asset.duration))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4))
                    .padding(5)
            }
        }
        .onAppear {
            guard request == nil else { return }
            if let cached = Self.cache.object(forKey: assetID as NSString) {
                show(cached)
                return
            }
            let token = UUID()
            requestToken = token
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            request = Self.manager.requestImage(for: asset, targetSize: CGSize(width: 300, height: 350),
                                                contentMode: .aspectFill, options: options) { image, info in
                guard let image, (info?[PHImageCancelledKey] as? Bool) != true else { return }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                Task { @MainActor in
                    guard requestToken == token else { return }
                    show(image)
                    if !degraded {
                        let pixels = Int(image.size.width * image.size.height * image.scale * image.scale)
                        Self.cache.setObject(image, forKey: assetID as NSString, cost: pixels * 4)
                    }
                }
            }
        }
        .onDisappear {
            entranceTask?.cancel()
            entranceTask = nil
            revealed = true
            requestToken = nil
            if let request { Self.manager.cancelImageRequest(request) }
            request = nil
            thumbnail = nil
        }
        .accessibilityHidden(true)
    }

    private func show(_ image: UIImage) {
        guard thumbnail == nil, let entrance, !reduceMotion else {
            thumbnail = image
            if reduceMotion { didEnter() }
            return
        }
        revealed = false
        thumbnail = image
        didEnter()
        entranceTask = Task { @MainActor in
            let stagger = 18 + (entrance / 3) * 30 + (entrance % 3) * 13
            do { try await Task.sleep(for: .milliseconds(stagger)) } catch { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.79)) { revealed = true }
        }
    }
}

private extension ImportedVideo {
    static func fromPhotoAsset(_ asset: PHAsset) async throws -> Self {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video }) else { throw ImportError.noFile }
        let directory = try makeTemporaryDirectory()
        let name = resource.originalFilename
        let ext = (name as NSString).pathExtension
        let url = directory.appendingPathComponent("source").appendingPathExtension(ext.isEmpty ? "mov" : ext)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            return Self(url: url, name: name)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

private struct OriginalVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let fillsPortrait: Bool
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> Surface {
        let surface = Surface()
        surface.videoLayer.videoGravity = fillsPortrait ? .resizeAspectFill : .resizeAspect
        surface.videoLayer.player = player
        return surface
    }
    func updateUIView(_ uiView: Surface, context: Context) {
        if uiView.videoLayer.player !== player { uiView.videoLayer.player = player }
        let gravity: AVLayerVideoGravity = fillsPortrait ? .resizeAspectFill : .resizeAspect
        if uiView.videoLayer.videoGravity != gravity { uiView.videoLayer.videoGravity = gravity }
    }
}
