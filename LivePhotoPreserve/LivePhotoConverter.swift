import AVFoundation
import AudioToolbox
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct LivePhotoFiles: Sendable {
    let photoURL: URL
    let movieURL: URL
    let identifier: String
    let coverTimeSeconds: Double
    let outputDurationSeconds: Double
}

enum CoverImageFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case heic = "HEIC"

    var id: String { rawValue }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }

    var title: String {
        switch self {
        case .jpeg: return "JPEG 最高质量"
        case .heic: return "HEIC 高效原画"
        }
    }
}

enum CoverApertureMode: String, CaseIterable, Identifiable, Sendable {
    case encodedPixels = "encodedPixels"
    case cleanAperture = "cleanAperture"

    var id: String { rawValue }

    var avApertureMode: AVAssetImageGenerator.ApertureMode {
        switch self {
        case .encodedPixels: return .encodedPixels
        case .cleanAperture: return .cleanAperture
        }
    }

    var title: String {
        switch self {
        case .encodedPixels: return "1:1 编码原始像素"
        case .cleanAperture: return "标准 Clean Aperture"
        }
    }
}

struct ConversionOptions: Sendable, Equatable {
    /// Writes QuickTime movie-level `com.apple.quicktime.live-photo.vitality-disabled = 1`
    /// and zero vitality transition score so iOS `ISLivePhotoPlayer._updateScaleIfNeeded`
    /// keeps playback scale at `1.0` instead of zooming in to `1.075x`.
    var disablePlaybackZoom: Bool = true

    /// Writes `com.apple.quicktime.full-frame-rate-playback-intent = 1` so 60fps/120fps
    /// clips play at full frame rate in Photos.
    var fullFrameRatePlaybackIntent: Bool = true

    /// Preserves original audio track (passthrough for AAC, automatic AAC-LC remux for PCM).
    var includeAudio: Bool = true

    /// Still cover image container format.
    var coverFormat: CoverImageFormat = .jpeg

    /// Aperture mode used when sampling the cover image from the video track.
    var apertureMode: CoverApertureMode = .encodedPixels

    /// Optional custom time range in seconds `[start, end]`. `nil` converts the entire video without any 3s limit.
    var trimRange: ClosedRange<Double>? = nil

    /// Optional custom cover frame timestamp (in seconds, in the source video timeline).
    /// `nil` uses the first frame of the output clip for seamless zero-jump playback.
    var customCoverTimeSeconds: Double? = nil

    static let `default` = ConversionOptions()
}

struct RGBAColor: Sendable, Equatable {
    let r: Double
    let g: Double
    let b: Double
}

struct VideoSpecification: Sendable {
    let durationSeconds: Double
    let naturalSize: CGSize
    let rawPixelSize: CGSize
    let codecName: String
    let isPassthroughCompatible: Bool
    let nominalFrameRate: Double
    let estimatedBitrateMbps: Double
    let fileSizeBytes: Int64
    let isHDR: Bool
    let colorSpaceLabel: String
    let hasAudio: Bool
    let audioSummary: String
    let ambientPalette: [RGBAColor]
    let thumbnails: [CGImage]

    var resolutionText: String {
        "\(Int(naturalSize.width.rounded())) × \(Int(naturalSize.height.rounded()))"
    }

    var resolutionTier: String {
        let maxDim = max(naturalSize.width, naturalSize.height)
        if maxDim >= 3800 { return "4K UHD" }
        if maxDim >= 2500 { return "2.7K QHD" }
        if maxDim >= 1900 { return "1080P FHD" }
        if maxDim >= 1200 { return "720P HD" }
        return "SD"
    }

    var frameRateText: String {
        if nominalFrameRate >= 115 {
            return String(format: "%.0f fps", nominalFrameRate)
        } else if abs(nominalFrameRate.rounded() - nominalFrameRate) < 0.05 {
            return String(format: "%.0f fps", nominalFrameRate)
        } else {
            return String(format: "%.2f fps", nominalFrameRate)
        }
    }

    var fileSizeText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSizeBytes)
    }

    var totalFramesEstimate: Int {
        max(1, Int((durationSeconds * max(nominalFrameRate, 1)).rounded()))
    }
}

private struct ConversionError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

struct LivePhotoConverter {
    /// Inspects the imported video to extract technical specifications, filmstrip thumbnails,
    /// and a harmonic ambient color palette for the Liquid Glass dynamic background.
    static func inspectVideo(at url: URL, thumbnailCount: Int = 8) async throws -> VideoSpecification {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else {
            throw ConversionError("无法读取视频时长，请确认文件未损坏。")
        }

        let videos = try await asset.loadTracks(withMediaType: .video)
        guard let video = videos.first else {
            throw ConversionError("未检测到视频画面轨道。")
        }

        let naturalSize = try await video.load(.naturalSize)
        let preferredTransform = try await video.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))

        let nominalFrameRate = Double(try await video.load(.nominalFrameRate))
        let estimatedDataRate = Double(try await video.load(.estimatedDataRate))
        let descriptions = try await video.load(.formatDescriptions)

        var codecName = "Unknown"
        var isPassthroughCompatible = false
        var isHDR = false
        var colorSpaceLabel = "Rec.709 SDR"

        if let format = descriptions.first {
            let codec = CMFormatDescriptionGetMediaSubType(format)
            switch codec {
            case kCMVideoCodecType_HEVC:
                codecName = "HEVC (H.265)"
                isPassthroughCompatible = true
            case kCMVideoCodecType_H264:
                codecName = "H.264 (AVC)"
                isPassthroughCompatible = true
            case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes4444:
                codecName = "Apple ProRes"
            default:
                codecName = fourCharString(codec)
            }

            if let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] {
                let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
                if extensions["DolbyVision"] != nil || extensions["dvcC"] != nil || extensions["dvvC"] != nil {
                    isHDR = true
                    colorSpaceLabel = "Dolby Vision HDR"
                } else if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
                    isHDR = true
                    colorSpaceLabel = "HLG HDR"
                } else if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
                    isHDR = true
                    colorSpaceLabel = "HDR10 (PQ)"
                } else if primaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String) {
                    colorSpaceLabel = "Display P3 广色域"
                }
            }
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var hasAudio = false
        var audioSummary = "无音轨"
        if let audioTrack = audioTracks.first {
            hasAudio = true
            let audioDescs = try await audioTrack.load(.formatDescriptions)
            if let audioFormat = audioDescs.first {
                let subType = CMFormatDescriptionGetMediaSubType(audioFormat)
                if subType == kAudioFormatMPEG4AAC {
                    audioSummary = "AAC-LC 原声直通"
                } else {
                    audioSummary = "\(fourCharString(subType)) 智能转 AAC"
                }
            } else {
                audioSummary = "含音频轨道"
            }
        }

        let fileSizeBytes: Int64 = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let fallbackBitrateMbps = duration.seconds > 0
            ? (Double(fileSizeBytes) * 8.0 / duration.seconds / 1_000_000.0)
            : 0
        let bitrateMbps = estimatedDataRate > 0 ? (estimatedDataRate / 1_000_000.0) : fallbackBitrateMbps

        // Generate filmstrip thumbnails and sample ambient colors
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        var thumbnails: [CGImage] = []
        let count = max(1, thumbnailCount)
        for index in 0..<count {
            let fraction = count == 1 ? 0.0 : Double(index) / Double(count - 1)
            let sampleSeconds = min(max(0.0, duration.seconds * fraction), max(0.0, duration.seconds - 0.02))
            let time = CMTime(seconds: sampleSeconds, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                thumbnails.append(cgImage)
            }
        }

        let palette = thumbnails.first.map { extractAmbientPalette(from: $0) } ?? defaultAmbientPalette

        return VideoSpecification(
            durationSeconds: duration.seconds,
            naturalSize: orientedSize.width > 0 && orientedSize.height > 0 ? orientedSize : naturalSize,
            rawPixelSize: naturalSize,
            codecName: codecName,
            isPassthroughCompatible: isPassthroughCompatible,
            nominalFrameRate: nominalFrameRate > 0 ? nominalFrameRate : 30.0,
            estimatedBitrateMbps: bitrateMbps,
            fileSizeBytes: fileSizeBytes,
            isHDR: isHDR,
            colorSpaceLabel: colorSpaceLabel,
            hasAudio: hasAudio,
            audioSummary: audioSummary,
            ambientPalette: palette,
            thumbnails: thumbnails
        )
    }

    /// Samples a single frame from the video at the exact requested timestamp for cover preview.
    static func extractPreviewFrame(at url: URL, seconds: Double, maximumDimension: CGFloat = 960) async -> CGImage? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .encodedPixels
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        return try? generator.copyCGImage(at: time, actualTime: nil)
    }

    /// Extracts a 4-color harmonic palette from any `CGImage` to drive dynamic background morphing.
    static func extractAmbientPalette(from image: CGImage) -> [RGBAColor] {
        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return defaultAmbientPalette
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let quadrants: [(Range<Int>, Range<Int>)] = [
            (0..<4, 0..<4),
            (4..<8, 0..<4),
            (0..<4, 4..<8),
            (4..<8, 4..<8)
        ]

        var colors: [RGBAColor] = []
        for (xRange, yRange) in quadrants {
            var rSum = 0.0
            var gSum = 0.0
            var bSum = 0.0
            var count = 0.0
            for y in yRange {
                for x in xRange {
                    let offset = (y * width + x) * 4
                    rSum += Double(pixels[offset]) / 255.0
                    gSum += Double(pixels[offset + 1]) / 255.0
                    bSum += Double(pixels[offset + 2]) / 255.0
                    count += 1.0
                }
            }
            var r = rSum / count
            var g = gSum / count
            var b = bSum / count
            // Boost saturation slightly and clamp luminance so glass text remains legible
            let avg = (r + g + b) / 3.0
            r = min(max(avg + (r - avg) * 1.45, 0.08), 0.85)
            g = min(max(avg + (g - avg) * 1.45, 0.08), 0.85)
            b = min(max(avg + (b - avg) * 1.45, 0.12), 0.90)
            colors.append(RGBAColor(r: r, g: g, b: b))
        }
        return colors.count == 4 ? colors : defaultAmbientPalette
    }

    private static let defaultAmbientPalette: [RGBAColor] = [
        RGBAColor(r: 0.10, g: 0.25, b: 0.58),
        RGBAColor(r: 0.35, g: 0.14, b: 0.56),
        RGBAColor(r: 0.06, g: 0.48, b: 0.62),
        RGBAColor(r: 0.16, g: 0.12, b: 0.34)
    ]

    /// Converts a video into a paired Live Photo (still cover + QuickTime MOV) without any 3-second limit,
    /// preserving original compressed video samples and injecting anti-zoom metadata when requested.
    static func convert(
        _ url: URL,
        into directory: URL,
        options: ConversionOptions = .default
    ) async throws -> LivePhotoFiles {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // If the user selected a non-zero start trim offset, losslessly pre-slice via AVAssetExportPresetPassthrough
        // so the sliced asset starts cleanly at 0 with intact GOP structure.
        var workingURL = url
        var temporaryTrimmedURL: URL?
        var coverOffsetInWorkingAsset: Double?

        let initialAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let fullDuration = try await initialAsset.load(.duration)
        guard fullDuration.isNumeric, fullDuration.seconds > 0 else {
            throw ConversionError("无法读取有效的视频时长。")
        }

        var endLimitSeconds: Double?
        if let trimRange = options.trimRange {
            let clampedStart = max(0.0, min(trimRange.lowerBound, fullDuration.seconds - 0.05))
            let clampedEnd = max(clampedStart + 0.1, min(trimRange.upperBound, fullDuration.seconds))
            let needsStartTrim = clampedStart > 0.02
            let needsEndTrim = clampedEnd < fullDuration.seconds - 0.02

            if needsStartTrim {
                let sliceURL = directory.appendingPathComponent("pretrim-\(UUID().uuidString).mov")
                let startCM = CMTime(seconds: clampedStart, preferredTimescale: 600)
                let durationCM = CMTime(seconds: clampedEnd - clampedStart, preferredTimescale: 600)
                try await passthroughTrim(
                    asset: initialAsset,
                    timeRange: CMTimeRange(start: startCM, duration: durationCM),
                    outputURL: sliceURL
                )
                workingURL = sliceURL
                temporaryTrimmedURL = sliceURL
                if let customCover = options.customCoverTimeSeconds {
                    coverOffsetInWorkingAsset = max(0.0, min(customCover - clampedStart, clampedEnd - clampedStart - 0.01))
                }
            } else {
                if needsEndTrim {
                    endLimitSeconds = clampedEnd
                }
                if let customCover = options.customCoverTimeSeconds {
                    coverOffsetInWorkingAsset = max(0.0, min(customCover, clampedEnd - 0.01))
                }
            }
        } else if let customCover = options.customCoverTimeSeconds {
            coverOffsetInWorkingAsset = max(0.0, min(customCover, fullDuration.seconds - 0.01))
        }

        defer {
            if let temporaryTrimmedURL {
                try? fileManager.removeItem(at: temporaryTrimmedURL)
            }
        }

        let asset = AVURLAsset(url: workingURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let assetDuration = try await asset.load(.duration)
        guard assetDuration.isNumeric, assetDuration.seconds > 0 else {
            throw ConversionError("无法识别待转换视频片段的时长。")
        }

        let effectiveDurationSeconds = min(endLimitSeconds ?? assetDuration.seconds, assetDuration.seconds)
        let effectiveDuration = CMTime(seconds: effectiveDurationSeconds, preferredTimescale: assetDuration.timescale > 0 ? assetDuration.timescale : 600)

        let videos = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard let video = videos.first else {
            throw ConversionError("请选择包含有效视频画面轨道的短片。")
        }

        let identifier = UUID().uuidString
        let photoURL = directory.appendingPathComponent(identifier + "." + options.coverFormat.fileExtension)
        let movieURL = directory.appendingPathComponent(identifier + ".mov")

        do {
            let reader = try AVAssetReader(asset: asset)
            if endLimitSeconds != nil {
                reader.timeRange = CMTimeRange(start: .zero, duration: effectiveDuration)
            }
            let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
            let videoCopy = try await makeVideoTrackCopy(video, reader: reader, writer: writer)
            let transform = try await video.load(.preferredTransform)
            guard supportsCoverTransform(transform) else {
                throw ConversionError("视频带有非标准方向或斜切缩放矩阵，无法保证封面与视频的构图 1:1 一致。")
            }
            videoCopy.input.transform = transform
            let timescale = try await video.load(.naturalTimeScale)
            guard timescale > 0 else { throw ConversionError("无法读取视频时间刻度。") }
            videoCopy.input.mediaTimeScale = timescale

            var copies = [videoCopy]
            if options.includeAudio, let audioTrack = audio.first {
                if let audioCopy = try? await makeAudioTrackCopy(audioTrack, reader: reader, writer: writer) {
                    copies.append(audioCopy)
                }
            }

            let videoRange = try await video.load(.timeRange)
            guard videoRange.start.isNumeric, videoRange.start >= .zero, videoRange.start < effectiveDuration else {
                throw ConversionError("无法识别视频的起始画面。")
            }

            let requestedCoverTime: CMTime
            if let coverOffsetInWorkingAsset, coverOffsetInWorkingAsset > 0 {
                let candidate = CMTime(seconds: coverOffsetInWorkingAsset, preferredTimescale: timescale)
                requestedCoverTime = CMTimeMinimum(
                    CMTimeMaximum(videoRange.start, candidate),
                    effectiveDuration - CMTime(value: 1, timescale: max(timescale, 600))
                )
            } else {
                requestedCoverTime = videoRange.start
            }

            try Task.checkCancellation()
            let coverTime = try writeCover(
                asset: asset,
                at: requestedCoverTime,
                identifier: identifier,
                format: options.coverFormat,
                apertureMode: options.apertureMode,
                to: photoURL
            )
            guard coverTime >= .zero, coverTime < effectiveDuration else {
                throw ConversionError("封面时间不在视频有效范围内。")
            }

            writer.metadata = makeMovieMetadata(identifier: identifier, options: options)

            let adaptor = try makeMarkerInput(writer: writer)
            adaptor.assetWriterInput.mediaTimeScale = timescale
            let marker = AVMutableMetadataItem()
            marker.keySpace = .quickTimeMetadata
            marker.key = "com.apple.quicktime.still-image-time" as NSString
            marker.dataType = kCMMetadataBaseDataType_SInt8 as String
            marker.value = NSNumber(value: Int8(0))
            let frameDuration = try await video.load(.minFrameDuration)
            let markerDuration = frameDuration.isNumeric && frameDuration > .zero
                ? frameDuration
                : CMTime(value: 1, timescale: timescale)
            let markerLength = CMTimeMinimum(markerDuration, effectiveDuration - coverTime)
            let group = AVTimedMetadataGroup(
                items: [marker],
                timeRange: CMTimeRange(start: coverTime, duration: markerLength)
            )
            let transfer = MovieTransfer(
                reader: reader,
                writer: writer,
                copies: copies,
                adaptor: adaptor,
                marker: group
            )
            try await transfer.run()
            try Task.checkCancellation()

            return LivePhotoFiles(
                photoURL: photoURL,
                movieURL: movieURL,
                identifier: identifier,
                coverTimeSeconds: coverTime.seconds,
                outputDurationSeconds: effectiveDurationSeconds
            )
        } catch {
            try? fileManager.removeItem(at: photoURL)
            try? fileManager.removeItem(at: movieURL)
            throw error
        }
    }

    private static func makeMovieMetadata(identifier: String, options: ConversionOptions) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        let contentID = AVMutableMetadataItem()
        contentID.keySpace = .quickTimeMetadata
        contentID.key = "com.apple.quicktime.content.identifier" as NSString
        contentID.value = identifier as NSString
        contentID.dataType = kCMMetadataBaseDataType_UTF8 as String
        items.append(contentID)

        if options.disablePlaybackZoom {
            // Disables iOS PhotosPlayer's 1.075x playback zoom (`-[ISLivePhotoPlayer _updateScaleIfNeeded]`)
            // and PhotosUIPrivate's vitality perspective warp (`-[AVAsset pu_supportsVitality]`)
            // by signaling `PFMetadataMovie.hasVitality == false`.
            let vitalityDisabled = AVMutableMetadataItem()
            vitalityDisabled.keySpace = .quickTimeMetadata
            vitalityDisabled.key = "com.apple.quicktime.live-photo.vitality-disabled" as NSString
            vitalityDisabled.value = NSNumber(value: Int8(1))
            vitalityDisabled.dataType = kCMMetadataBaseDataType_SInt8 as String
            items.append(vitalityDisabled)

            let transitionScore = AVMutableMetadataItem()
            transitionScore.keySpace = .quickTimeMetadata
            transitionScore.key = "com.apple.quicktime.live-photo.transition-vitality-score.v1" as NSString
            transitionScore.value = NSNumber(value: Float(0.0))
            transitionScore.dataType = kCMMetadataBaseDataType_Float32 as String
            items.append(transitionScore)

            let vitalityScore = AVMutableMetadataItem()
            vitalityScore.keySpace = .quickTimeMetadata
            vitalityScore.key = "com.apple.quicktime.live-photo.vitality-score" as NSString
            vitalityScore.value = NSNumber(value: Float(0.0))
            vitalityScore.dataType = kCMMetadataBaseDataType_Float32 as String
            items.append(vitalityScore)

            let vitalityScoringVersion = AVMutableMetadataItem()
            vitalityScoringVersion.keySpace = .quickTimeMetadata
            vitalityScoringVersion.key = "com.apple.quicktime.live-photo.vitality-scoring-version" as NSString
            vitalityScoringVersion.value = NSNumber(value: Int64(4))
            vitalityScoringVersion.dataType = kCMMetadataBaseDataType_SInt64 as String
            items.append(vitalityScoringVersion)
        }

        if options.fullFrameRatePlaybackIntent {
            let fullFrameRate = AVMutableMetadataItem()
            fullFrameRate.keySpace = .quickTimeMetadata
            fullFrameRate.key = "com.apple.quicktime.full-frame-rate-playback-intent" as NSString
            fullFrameRate.value = NSNumber(value: Int8(1))
            fullFrameRate.dataType = kCMMetadataBaseDataType_SInt8 as String
            items.append(fullFrameRate)
        }

        return items
    }

    private static func passthroughTrim(asset: AVAsset, timeRange: CMTimeRange, outputURL: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ConversionError("无法初始化无损片段截取会话。")
        }
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.timeRange = timeRange
        await session.export()
        if session.status != .completed {
            throw session.error ?? ConversionError("无损截取视频区间失败。")
        }
    }

    private static func supportsCoverTransform(_ transform: CGAffineTransform) -> Bool {
        // AVAssetImageGenerator applies rotations in multiples of 90 degrees.
        (0..<4).contains { quarterTurns in
            let rotation = CGAffineTransform(rotationAngle: CGFloat(quarterTurns) * .pi / 2)
            let tolerance: CGFloat = 0.001
            return abs(transform.a - rotation.a) < tolerance
                && abs(transform.b - rotation.b) < tolerance
                && abs(transform.c - rotation.c) < tolerance
                && abs(transform.d - rotation.d) < tolerance
        }
    }

    private static func makeVideoTrackCopy(
        _ track: AVAssetTrack,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> TrackCopy {
        let descriptions = try await track.load(.formatDescriptions)
        guard descriptions.count == 1, let format = descriptions.first else {
            throw ConversionError("不支持片段中途切换视频编码格式。")
        }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        guard codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC else {
            throw ConversionError("原画视频直通仅支持 H.264 或 HEVC 编码。")
        }

        // Nil outputSettings on both reader and writer preserves compressed video samples bit-for-bit.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        guard reader.canAdd(output), writer.canAdd(input) else {
            throw ConversionError("视频轨道无法直通封装为 MOV。")
        }
        reader.add(output)
        writer.add(input)
        return TrackCopy(output: output, input: input)
    }

    private static func makeAudioTrackCopy(
        _ track: AVAssetTrack,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> TrackCopy {
        let descriptions = try await track.load(.formatDescriptions)
        guard let format = descriptions.first else {
            throw ConversionError("无法读取音频轨道格式。")
        }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        if descriptions.count == 1 && codec == kAudioFormatMPEG4AAC {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw ConversionError("AAC 音轨无法直通写入 MOV。")
            }
            reader.add(output)
            writer.add(input)
            return TrackCopy(output: output, input: input)
        } else {
            // Transcode non-AAC audio (such as Linear PCM) to high-bitrate AAC-LC while keeping video bit-exact.
            let readerSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let writerSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 192_000
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw ConversionError("音频轨道无法转换为 AAC。")
            }
            reader.add(output)
            writer.add(input)
            return TrackCopy(output: output, input: input)
        }
    }

    private static func writeCover(
        asset: AVAsset,
        at time: CMTime,
        identifier: String,
        format: CoverImageFormat,
        apertureMode: CoverApertureMode,
        to url: URL
    ) throws -> CMTime {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = apertureMode.avApertureMode
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var actualTime = CMTime.invalid
        let image = try generator.copyCGImage(at: time, actualTime: &actualTime)

        let targetType = format.utType.identifier as CFString
        let destination = CGImageDestinationCreateWithURL(url as CFURL, targetType, 1, nil)
            ?? CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)

        guard actualTime.isNumeric, let destination else {
            throw ConversionError("无法创建实况封面图像。")
        }
        let properties: [String: Any] = [
            kCGImagePropertyMakerAppleDictionary as String: [
                "17": identifier
            ],
            kCGImageDestinationLossyCompressionQuality as String: 1.0
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError("实况封面写入失败。")
        }
        return actualTime
    }

    private static func makeMarkerInput(writer: AVAssetWriter) throws -> AVAssetWriterInputMetadataAdaptor {
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8
        ]
        var format: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw ConversionError("无法创建封面时间元数据格式。") }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        guard writer.canAdd(input) else { throw ConversionError("无法添加封面时间元数据轨道。") }
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
        writer.add(input)
        return adaptor
    }

    private static func fourCharString(_ code: FourCharCode) -> String {
        let bytes: [CChar] = [
            CChar((code >> 24) & 0xFF),
            CChar((code >> 16) & 0xFF),
            CChar((code >> 8) & 0xFF),
            CChar(code & 0xFF),
            0
        ]
        let raw = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "Unknown" : raw.uppercased()
    }
}

private struct TrackCopy {
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
}

// All callbacks share a serial queue. Each input yields to AVFoundation's backpressure independently.
private final class MovieTransfer: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let copies: [TrackCopy]
    private let adaptor: AVAssetWriterInputMetadataAdaptor
    private let marker: AVTimedMetadataGroup
    private let queue = DispatchQueue(label: "LivePhotoPreserve.movie-copy")
    private var finished = Set<Int>()
    private var result: CheckedContinuation<Void, Error>?

    init(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        copies: [TrackCopy],
        adaptor: AVAssetWriterInputMetadataAdaptor,
        marker: AVTimedMetadataGroup
    ) {
        self.reader = reader
        self.writer = writer
        self.copies = copies
        self.adaptor = adaptor
        self.marker = marker
    }

    func run() async throws {
        defer { withExtendedLifetime(self) {} }
        guard reader.startReading() else { throw reader.error ?? ConversionError("无法读取原始媒体样本。") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? ConversionError("无法开始写入配对 MOV。")
        }
        writer.startSession(atSourceTime: .zero)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                result = continuation
                for (index, copy) in copies.enumerated() {
                    copy.input.requestMediaDataWhenReady(on: queue) { [weak self] in
                        guard let self else { return }
                        self.drain(self.copies[index], index: index)
                    }
                }
                adaptor.assetWriterInput.requestMediaDataWhenReady(on: queue) { [weak self] in
                    self?.writeMarker()
                }
            }
        }
    }

    private func writeMarker() {
        let index = copies.count
        guard result != nil, !finished.contains(index) else { return }
        guard adaptor.append(marker) else {
            fail(writer.error ?? ConversionError("封面时间写入失败。"))
            return
        }
        finish(adaptor.assetWriterInput, index: index)
    }

    private func drain(_ copy: TrackCopy, index: Int) {
        guard result != nil, !finished.contains(index) else { return }
        while copy.input.isReadyForMoreMediaData {
            guard let sample = copy.output.copyNextSampleBuffer() else {
                if reader.status == .failed || reader.status == .cancelled {
                    fail(reader.error ?? ConversionError("原始样本读取失败。"))
                } else {
                    finish(copy.input, index: index)
                }
                return
            }
            guard copy.input.append(sample) else {
                fail(writer.error ?? ConversionError("原始样本写入失败。"))
                return
            }
        }
        if writer.status == .failed {
            fail(writer.error ?? ConversionError("MOV 写入失败。"))
        }
    }

    private func finish(_ input: AVAssetWriterInput, index: Int) {
        finished.insert(index)
        input.markAsFinished()
        guard finished.count == copies.count + 1 else { return }
        writer.finishWriting { [self] in
            queue.async { [self] in
                guard let continuation = result else { return }
                result = nil
                if writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: writer.error ?? ConversionError("MOV 封装失败。"))
                }
            }
        }
    }

    private func fail(_ error: Error) {
        guard let continuation = result else { return }
        result = nil
        if reader.status == .reading { reader.cancelReading() }
        if writer.status == .writing { writer.cancelWriting() }
        continuation.resume(throwing: error)
    }
}
