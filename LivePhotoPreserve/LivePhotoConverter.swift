import AVFoundation
import AudioToolbox
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct LivePhotoFiles {
    let photoURL: URL
    let movieURL: URL
}

private struct ConversionError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

struct LivePhotoConverter {
    static let maximumDurationSeconds = 3.1

    static func convert(_ url: URL, into directory: URL) async throws -> LivePhotoFiles {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0, duration.seconds <= maximumDurationSeconds else {
            throw ConversionError("请先截取约 3 秒以内的短片（最长 3.1 秒）。")
        }
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard videos.count == 1, let video = videos.first, audio.count <= 1 else {
            throw ConversionError("请选择带有一个视频轨道、最多一个音频轨道的短片。")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let files = LivePhotoFiles(
            photoURL: directory.appendingPathComponent(identifier + ".jpg"),
            movieURL: directory.appendingPathComponent(identifier + ".mov")
        )
        do {
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: files.movieURL, fileType: .mov)
            let videoCopy = try await makeTrackCopy(video, reader: reader, writer: writer)
            let transform = try await video.load(.preferredTransform)
            guard supportsCoverTransform(transform) else {
                throw ConversionError("视频带有非标准方向或缩放矩阵，无法保证封面与视频的构图一致。")
            }
            videoCopy.input.transform = transform
            let timescale = try await video.load(.naturalTimeScale)
            guard timescale > 0 else { throw ConversionError("无法读取视频时间刻度。") }
            videoCopy.input.mediaTimeScale = timescale
            var copies = [videoCopy]
            if let audioTrack = audio.first {
                copies.append(try await makeTrackCopy(audioTrack, reader: reader, writer: writer))
            }
            let videoRange = try await video.load(.timeRange)
            guard videoRange.start.isNumeric, videoRange.start >= .zero, videoRange.start < duration else {
                throw ConversionError("无法识别视频的起始画面。")
            }
            try Task.checkCancellation()
            let coverTime = try writeCover(asset: asset, at: videoRange.start, identifier: identifier, to: files.photoURL)
            guard coverTime >= .zero, coverTime < duration else {
                throw ConversionError("封面时间不在视频范围内。")
            }

            let contentID = AVMutableMetadataItem()
            contentID.keySpace = .quickTimeMetadata
            contentID.key = "com.apple.quicktime.content.identifier" as NSString
            contentID.value = identifier as NSString
            contentID.dataType = kCMMetadataBaseDataType_UTF8 as String
            writer.metadata = [contentID]

            let adaptor = try makeMarkerInput(writer: writer)
            adaptor.assetWriterInput.mediaTimeScale = timescale
            let marker = AVMutableMetadataItem()
            marker.keySpace = .quickTimeMetadata
            marker.key = "com.apple.quicktime.still-image-time" as NSString
            marker.dataType = kCMMetadataBaseDataType_SInt8 as String
            marker.value = NSNumber(value: Int8(0))
            let frameDuration = try await video.load(.minFrameDuration)
            let markerDuration = frameDuration.isNumeric && frameDuration > .zero ? frameDuration : CMTime(value: 1, timescale: timescale)
            let markerLength = CMTimeMinimum(markerDuration, duration - coverTime)
            let group = AVTimedMetadataGroup(items: [marker], timeRange: CMTimeRange(start: coverTime, duration: markerLength))
            let transfer = MovieTransfer(reader: reader, writer: writer, copies: copies, adaptor: adaptor, marker: group)
            try await transfer.run()
            try Task.checkCancellation()
            return files
        } catch {
            try? fileManager.removeItem(at: files.photoURL)
            try? fileManager.removeItem(at: files.movieURL)
            throw error
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

    private static func makeTrackCopy(_ track: AVAssetTrack, reader: AVAssetReader, writer: AVAssetWriter) async throws -> TrackCopy {
        let descriptions = try await track.load(.formatDescriptions)
        guard descriptions.count == 1, let format = descriptions.first else {
            throw ConversionError("不支持片段中途切换编码格式。")
        }
        let mediaType = track.mediaType
        let codec = CMFormatDescriptionGetMediaSubType(format)
        if mediaType == .video {
            guard codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC else {
                throw ConversionError("视频直通支持 H.264 和 HEVC。")
            }
        } else if codec != kAudioFormatMPEG4AAC {
            throw ConversionError("音频轨道需为 AAC-LC，或选择无声短片。")
        }

        // Both settings must be nil: the reader and writer exchange the existing compressed samples.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: nil, sourceFormatHint: format)
        guard reader.canAdd(output), writer.canAdd(input) else {
            throw ConversionError("此轨道无法直通封装为 MOV。")
        }
        reader.add(output)
        writer.add(input)
        return TrackCopy(output: output, input: input)
    }

    private static func writeCover(asset: AVAsset, at time: CMTime, identifier: String, to url: URL) throws -> CMTime {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .cleanAperture
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var actualTime = CMTime.invalid
        let image = try generator.copyCGImage(at: time, actualTime: &actualTime)
        guard actualTime.isNumeric, let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw ConversionError("无法创建首帧封面。")
        }
        let properties: [String: Any] = [
            kCGImagePropertyMakerAppleDictionary as String: ["17": identifier],
            kCGImageDestinationLossyCompressionQuality as String: 1.0
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError("封面写入失败。") }
        return actualTime
    }

    private static func makeMarkerInput(writer: AVAssetWriter) throws -> AVAssetWriterInputMetadataAdaptor {
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8
        ]
        var format: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw ConversionError("无法创建封面时间格式。") }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        guard writer.canAdd(input) else { throw ConversionError("无法添加封面时间轨道。") }
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
        writer.add(input)
        return adaptor
    }
}

private struct TrackCopy {
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
}

// All callbacks share a serial queue. Each input yields to AVFoundation's backpressure independently.
private final class MovieTransfer {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let copies: [TrackCopy]
    private let adaptor: AVAssetWriterInputMetadataAdaptor
    private let marker: AVTimedMetadataGroup
    private let queue = DispatchQueue(label: "LivePhotoPreserve.movie-copy")
    private var finished = Set<Int>()
    private var result: CheckedContinuation<Void, Error>?

    init(reader: AVAssetReader, writer: AVAssetWriter, copies: [TrackCopy], adaptor: AVAssetWriterInputMetadataAdaptor, marker: AVTimedMetadataGroup) {
        self.reader = reader
        self.writer = writer
        self.copies = copies
        self.adaptor = adaptor
        self.marker = marker
    }

    func run() async throws {
        defer { withExtendedLifetime(self) {} }
        guard reader.startReading() else { throw reader.error ?? ConversionError("无法读取原始样本。") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? ConversionError("无法开始写入 MOV。")
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
