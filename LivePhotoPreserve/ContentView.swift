import AVFoundation
import AVKit
import Photos
import PhotosUI
import Observation
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
    @State private var editorOpen = false
    @State private var transitionID: String?
    @State private var library = VideoLibrary()
    @State private var albumID: String?
    @State private var firstGridHasEntered = false
    @State private var visibleRowsSettled = false
    @State private var showsExportSheet = false
    @State private var advancedDefaults = false
    @State private var advancedExport = false
    @State private var editingCover = false
    @State private var playhead = 0.0
    @State private var isPlaying = false
    @State private var export = ExportPreferences()
    @State private var playbackObserver: Any?

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

    var body: some View {
        NavigationStack {
            pickerHome
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $editorOpen) {
                    if #available(iOS 18.0, *), let transitionID, !reduceMotion {
                        editor.toolbar(.hidden, for: .navigationBar)
                            .navigationTransition(.zoom(sourceID: transitionID, in: clipNavigation))
                    } else {
                        editor.toolbar(.hidden, for: .navigationBar)
                    }
                }
        }
        .sheet(isPresented: $showsPhotoPicker) {
            VideoPhotoPicker(didStart: {
                showsPhotoPicker = false
                feedback = nil
                transitionID = nil
                workingStatus = "正在载入视频…"
                isWorking = true
            }, didFinish: { result in
                Task { await finishImport(result) }
            })
        }
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.movie, .video]) { result in
            guard case .success(let url) = result else { return }
            transitionID = nil
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
        .onChange(of: editorOpen) { _, opened in
            if !opened { stopPlayback() }
        }
        .onDisappear { stopPlayback() }
        .task { library.refresh() }
    }

    private var pickerHome: some View {
        ZStack(alignment: .bottom) {
            studioBackground
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("LIVEPHOTO PRO")
                        .font(.caption.weight(.semibold)).tracking(3)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        advancedDefaults = false
                        showsSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape").font(.system(size: 19))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).studioGlass(Circle())
                    .accessibilityLabel("设置")
                }
                HStack {
                    Text("视频").font(.largeTitle.bold())
                    Spacer()
                    Menu {
                        Button("所有视频") { albumID = nil; library.refresh() }
                        ForEach(library.albums, id: \.localIdentifier) { album in
                            Button(album.localizedTitle ?? "相簿") {
                                albumID = album.localIdentifier
                                library.refresh(in: album)
                            }
                        }
                        Divider()
                        Button("系统照片选择器", systemImage: "photo.on.rectangle") {
                            showsPhotoPicker = true
                        }
                    } label: {
                        Label("相簿", systemImage: "chevron.down")
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .studioGlass(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if library.canBrowse {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Color.clear.frame(height: 0).id("library-top")
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                                ForEach(Array(library.videos.enumerated()), id: \.offset) { index, asset in
                                    videoTile(asset).id(asset.localIdentifier)
                                        .offset(y: visibleRowsSettled || index >= 9 || reduceMotion ? 0 : -CGFloat(index / 3) * 12)
                                        .opacity(visibleRowsSettled || index < 3 || index >= 9 || reduceMotion ? 1 : 0.55)
                                        .animation(.easeOut(duration: 0.19).delay(Double(index / 3) * 0.03), value: visibleRowsSettled)
                                }
                            }
                            .padding(.bottom, 76)
                            if library.videos.isEmpty {
                                ContentUnavailableView("没有视频", systemImage: "film", description: Text("也可以从「文件」导入。"))
                            }
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: albumID) { _, _ in proxy.scrollTo("library-top") }
                    }
                    .task(id: library.videos.isEmpty) {
                        guard !library.videos.isEmpty, !firstGridHasEntered else { return }
                        firstGridHasEntered = true
                        try? await Task.sleep(for: .milliseconds(25))
                        visibleRowsSettled = true
                    }
                } else {
                    Spacer()
                    VStack(spacing: 14) {
                        Image(systemName: "play.rectangle").font(.system(size: 35, weight: .light))
                        Text("选择一段视频").font(.title2.bold())
                        Button("从照片选择") { showsPhotoPicker = true }
                            .buttonStyle(.borderedProminent)
                        if library.canRequest {
                            Button("在首页显示我的视频") {
                                Task { await library.requestAccess() }
                            }
                        } else {
                            Button("管理照片权限") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Button {
                showsFilePicker = true
            } label: {
                Label("文件", systemImage: "folder")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 21).frame(height: 48)
            }
            .buttonStyle(.plain).studioGlass(Capsule())
            .padding(.bottom, 10)
            if !editorOpen { statusOverlay.padding(.bottom, 68) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if !editorOpen { library.refresh(in: library.albums.first { $0.localIdentifier == albumID }) }
        }
    }

    @ViewBuilder
    private func videoTile(_ asset: PHAsset) -> some View {
        let tile = Button {
            guard !isWorking else { return }
            transitionID = asset.localIdentifier
            feedback = nil
            isWorking = true
            workingStatus = "正在载入视频…"
            Task { @MainActor in
                let result: Result<ImportedVideo, Error>
                do { result = .success(try await ImportedVideo.fromPhotoAsset(asset)) }
                catch { result = .failure(error) }
                await finishImport(result)
            }
        } label: {
            LibraryThumbnail(asset: asset)
                .aspectRatio(0.86, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("视频，\(timestamp(asset.duration))")
        if #available(iOS 18.0, *), !reduceMotion {
            tile.matchedTransitionSource(id: asset.localIdentifier, in: clipNavigation)
        } else { tile }
    }

    private var studioBackground: some View {
        let palette = currentPalette
        return ZStack {
            Color(uiColor: .systemBackground)
            LinearGradient(colors: [Color(red: 0.63, green: 0.81, blue: 0.94).opacity(colorScheme == .dark ? 0.15 : 0.47),
                                    Color(uiColor: .systemBackground)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let tone = palette.first {
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !dynamicBackgroundMotion || reduceMotion)) { context in
                    let phase = dynamicBackgroundMotion && !reduceMotion
                        ? sin(context.date.timeIntervalSinceReferenceDate / 4) : 0
                    RadialGradient(colors: [Color(red: Double(tone.r), green: Double(tone.g), blue: Double(tone.b)).opacity(0.17), .clear],
                                   center: UnitPoint(x: 0.62 + phase * 0.13, y: 0.22), startRadius: 10, endRadius: 480)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var editor: some View {
        ZStack(alignment: .bottom) {
            studioBackground
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 13) {
                        previewStage(height: max(215, geo.size.height - 190))
                        if let specification { filmstrip(specification) }
                        editorDock
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.hidden)
            }
            statusOverlay.padding(.bottom, 74)
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

    private func previewStage(height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            ZStack {
                Color.black.opacity(0.85)
                if stageMode == .livePhoto, let generatedLivePhoto {
                    LivePhotoPreviewView(livePhoto: generatedLivePhoto, isMuted: !export.audio,
                                         playbackTrigger: livePhotoPlaybackTrigger)
                } else if let player {
                    if let poster = specification?.thumbnails.first {
                        Image(decorative: poster, scale: 1).resizable().scaledToFit()
                            .accessibilityHidden(true)
                    }
                    OriginalVideoSurface(player: player)
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 45, height: 45)
                }
                .buttonStyle(.plain).studioGlass(Circle())
                .foregroundStyle(.white).environment(\.colorScheme, .dark)
                .padding(16).accessibilityLabel(isPlaying ? "暂停" : "播放")
            }
            HStack(spacing: 8) {
                Button {
                    stopPlayback()
                    editorOpen = false
                } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).studioGlass(Circle()).accessibilityLabel("返回视频")
                .disabled(isWorking)
                Spacer(minLength: 4)
                Menu {
                    Button("预览实况", systemImage: "livephoto") { Task { await convertForInAppPreviewOnly() } }
                    if stageMode == .livePhoto {
                        Button("回到原视频", systemImage: "film") { stageMode = .video }
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
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        .studioGlass(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("更多")
                .disabled(isWorking)
                Button {
                    Task { await convertAndSaveToPhotos() }
                } label: {
                    Label("保存", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).frame(height: 44)
                }
                .buttonStyle(.plain).studioGlass(Capsule())
                .disabled(isWorking)
            }
            .padding(.horizontal, 15).padding(.top, 8)
            .foregroundStyle(.white).environment(\.colorScheme, .dark)
            .background(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 100).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var editorDock: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(DurationPreset.allCases) { preset in
                    Button {
                        if let spec = specification { setPreset(preset, spec: spec) }
                        editingCover = false
                    } label: {
                        if durationPreset == preset { Label(preset.rawValue, systemImage: "checkmark") }
                        else { Text(preset.rawValue) }
                    }
                }
            } label: {
                dockLabel("裁剪", icon: "scissors")
            }
            .buttonStyle(.plain)
            Button {
                stopPlayback()
                stageMode = .video
                if !editingCover {
                    let beginning = effectiveTrimRange?.lowerBound ?? 0
                    playhead = useCustomCoverTime ? customCoverTimeSeconds : beginning
                    seekPlayer(to: playhead)
                }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { editingCover.toggle() }
            } label: {
                dockLabel(editingCover ? "完成" : "封面", icon: editingCover ? "checkmark" : "photo")
            }
            .buttonStyle(.plain)
            Button(action: replay) {
                dockLabel("重播", icon: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .studioGlass(Capsule())
        .disabled(isWorking)
    }

    private func dockLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium))
            Text(title).font(.caption2.weight(.medium))
        }
        .frame(minWidth: 49, minHeight: 44)
    }

    private func filmstrip(_ spec: VideoSpecification) -> some View {
        let total = max(0.1, spec.durationSeconds)
        let range = effectiveTrimRange ?? 0...total
        return VStack(spacing: 5) {
            HStack {
                Text(timestamp(range.lowerBound))
                Spacer()
                Text(editingCover ? "封面 · \(timestamp(playhead))" : "片段 · \(timestamp(effectiveOutputDuration))")
                Spacer()
                Text(timestamp(range.upperBound))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                let start = width * CGFloat(range.lowerBound / total)
                let end = width * CGFloat(range.upperBound / total)
                let marker = width * CGFloat(min(1, max(0, playhead / total)))
                ZStack(alignment: .leading) {
                    HStack(spacing: 1) {
                        ForEach(Array(spec.thumbnails.enumerated()), id: \.offset) { _, frame in
                            GeometryReader { box in
                                Image(decorative: frame, scale: 1)
                                    .resizable().scaledToFill()
                                    .frame(width: box.size.width, height: box.size.height).clipped()
                            }
                        }
                    }
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
                        scrub(to: Double(value.location.x / width) * total, within: range)
                    })
                    if !editingCover {
                        Color.black.opacity(0.36).frame(width: max(0, start)).allowsHitTesting(false)
                        Color.black.opacity(0.36).frame(width: max(0, width - end)).offset(x: end).allowsHitTesting(false)
                        trimHandle(x: start, leading: true, width: width, total: total, range: range)
                        trimHandle(x: end, leading: false, width: width, total: total, range: range)
                    }
                    Rectangle().fill(editingCover ? Color.accentColor : .white)
                        .frame(width: 2, height: 58).offset(x: marker - 1)
                        .allowsHitTesting(false)
                }
                .coordinateSpace(name: "strip")
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
            if editingCover, let coverPreviewImage {
                Image(decorative: coverPreviewImage, scale: 1)
                    .resizable().scaledToFill().frame(width: 61, height: 39).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5) }
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18)
        .disabled(isWorking)
    }

    private func trimHandle(x: CGFloat, leading: Bool, width: CGFloat, total: Double,
                            range: ClosedRange<Double>) -> some View {
        Image(systemName: "line.3.horizontal")
            .rotationEffect(.degrees(90)).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.65))
            .frame(width: 15, height: 46)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            .frame(width: 30, height: 48)
            .contentShape(Rectangle())
            .offset(x: x - 15)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
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
                      within: trimStartSeconds...trimEndSeconds)
            })
            .accessibilityLabel(leading ? "裁剪起点" : "裁剪终点")
    }

    private var statusOverlay: some View {
        VStack {
            if isWorking {
                HStack(spacing: 9) { ProgressView(); Text(workingStatus) }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            } else if let feedback {
                Button {
                    self.feedback = nil
                } label: {
                    Label(feedback.text, systemImage: feedback.icon)
                        .font(.footnote.weight(.medium))
                        .padding(11)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain).padding(.horizontal, 18)
            }
        }
    }

    private var settingsPanel: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("背景主题", selection: $ambientThemeRaw) {
                        ForEach(AmbientTheme.allCases) { theme in Text(theme.rawValue).tag(theme.rawValue) }
                    }
                    Toggle("背景动效", isOn: $dynamicBackgroundMotion)
                }
                Section("默认导出") {
                    Toggle("防止播放放大", isOn: $disablePlaybackZoom)
                    Toggle("保留声音", isOn: $includeAudio)
                    advancedSection(expanded: $advancedDefaults, highRate: $fullFrameRateIntent,
                                    format: $coverFormatRaw, aperture: $apertureModeRaw)
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showsSettingsSheet = false } } }
        }
        .presentationDragIndicator(.visible)
    }

    private var exportPanel: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("防止播放放大", isOn: $export.zoomOff)
                    Toggle("保留声音", isOn: $export.audio)
                } header: { Text("仅对当前视频生效") }
                Section {
                    advancedSection(expanded: $advancedExport, highRate: $export.highRate,
                                    format: $export.format, aperture: $export.aperture)
                }
            }
            .navigationTitle("本次导出").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showsExportSheet = false } } }
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
        DisclosureGroup("高级", isExpanded: expanded) {
            Toggle("高帧率播放", isOn: highRate)
            Picker("封面格式", selection: format) {
                ForEach(CoverImageFormat.allCases) { choice in Text(choice.rawValue).tag(choice.rawValue) }
            }
            Picker("封面取景", selection: aperture) {
                Text("完整像素").tag(CoverApertureMode.encodedPixels.rawValue)
                Text("有效画面").tag(CoverApertureMode.cleanAperture.rawValue)
            }
        }
    }

    private func invalidateOutput() {
        cleanupGeneratedFiles()
        stageMode = .video
        feedback = nil
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

    private func scrub(to seconds: Double, within range: ClosedRange<Double>) {
        stopPlayback()
        let time = min(max(seconds, range.lowerBound), range.upperBound)
        playhead = time
        stageMode = .video
        seekPlayer(to: time)
        if editingCover {
            if generatedFiles != nil { invalidateOutput() }
            useCustomCoverTime = true
            customCoverTimeSeconds = min(time, max(range.lowerBound, range.upperBound - 0.02))
            let frames = specification?.thumbnails ?? []
            if !frames.isEmpty, let duration = specification?.durationSeconds, duration > 0 {
                let index = Int((customCoverTimeSeconds / duration * Double(frames.count - 1)).rounded())
                coverPreviewImage = frames[min(frames.count - 1, max(0, index))]
            }
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        return String(format: "%d:%02d", s / 60, s % 60)
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
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
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

    private func seekPlayer(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @MainActor
    private func finishImport(_ result: Result<ImportedVideo, Error>) async {
        showsPhotoPicker = false
        switch result {
        case .success(let imported):
            workingStatus = "正在解析视频编码、画幅与流光色彩…"
            do {
                let spec = try await LivePhotoConverter.inspectVideo(at: imported.url)
                stopPlayback()
                player?.replaceCurrentItem(with: nil)
                cleanupGeneratedFiles()
                source?.remove()

                source = imported
                specification = spec
                export = inheritedExport
                playhead = 0
                editingCover = false
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
                editorOpen = true
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
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    stageMode = .livePhoto
                }
                feedback = nil
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
        workingStatus = "正在存入相册…"
        feedback = nil
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
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    stageMode = .livePhoto
                }
            }

            feedback = .success("已存入相册")
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

private extension View {
    @ViewBuilder func studioGlass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay { shape.stroke(.white.opacity(0.28), lineWidth: 1).allowsHitTesting(false) }
        }
    }
}

@Observable @MainActor
private final class VideoLibrary {
    private(set) var videos: [PHAsset] = []
    private(set) var albums: [PHAssetCollection] = []
    private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var canBrowse: Bool { status == .authorized || status == .limited }
    var canRequest: Bool { status == .notDetermined }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh()
    }

    func refresh(in album: PHAssetCollection? = nil) {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canBrowse else { videos = []; albums = []; return }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = album.map { PHAsset.fetchAssets(in: $0, options: options) }
            ?? PHAsset.fetchAssets(with: options)
        var items: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in items.append(asset) }
        videos = items
        if album == nil {
            var collections: [PHAssetCollection] = []
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
                .enumerateObjects { collection, _, _ in collections.append(collection) }
            albums = collections
        }
    }
}

private struct LibraryThumbnail: View {
    let asset: PHAsset
    @State private var thumbnail: UIImage?
    @State private var request: PHImageRequestID?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                Color(uiColor: .secondarySystemFill)
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
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
            guard thumbnail == nil, request == nil else { return }
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 380, height: 440),
                                                            contentMode: .aspectFill, options: options) { image, info in
                guard let image, (info?[PHImageCancelledKey] as? Bool) != true else { return }
                Task { @MainActor in thumbnail = image }
            }
        }
        .onDisappear {
            if let request { PHImageManager.default().cancelImageRequest(request) }
            request = nil
        }
        .accessibilityHidden(true)
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
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> Surface {
        let surface = Surface()
        surface.videoLayer.videoGravity = .resizeAspect
        surface.videoLayer.player = player
        return surface
    }
    func updateUIView(_ uiView: Surface, context: Context) {
        if uiView.videoLayer.player !== player { uiView.videoLayer.player = player }
    }
}
