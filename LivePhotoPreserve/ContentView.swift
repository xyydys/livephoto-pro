import AVKit
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var source: ImportedVideo?
    @State private var player: AVPlayer?
    @State private var showsPhotoPicker = false
    @State private var showsFilePicker = false
    @State private var isWorking = false
    @State private var feedback: Feedback?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let source, let player {
                        VideoPlayer(player: player)
                            .frame(height: 320)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .accessibilityLabel("原视频预览")

                        Label(source.name, systemImage: "film")
                            .lineLimit(2)
                    } else {
                        Text("导入预先剪好的 H.264 或 HEVC 短片（最长 3.1 秒，可含 AAC 音频）。实况以首帧为封面，保留原视频画幅和帧时序。")
                            .foregroundStyle(.secondary)
                    }

                    Menu {
                        Button {
                            showsPhotoPicker = true
                        } label: {
                            Label("从相册选视频", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showsFilePicker = true
                        } label: {
                            Label("从文件导入原视频", systemImage: "folder")
                        }
                    } label: {
                        Label(source == nil ? "选择视频" : "更换视频", systemImage: "plus.circle")
                    }
                    .disabled(isWorking)

                    Button {
                        Task { await convertAndSave() }
                    } label: {
                        Label("转换并存入相册", systemImage: "livephoto")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(source == nil || isWorking)

                    if isWorking {
                        ProgressView("处理中…")
                    }

                    if let feedback {
                        Label(feedback.text, systemImage: feedback.icon)
                            .foregroundStyle(feedback.color)
                    }
                }
                .frame(maxWidth: 540)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("视频转实况")
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showsPhotoPicker) {
            VideoPhotoPicker(
                didStart: {
                    showsPhotoPicker = false
                    feedback = nil
                    isWorking = true
                },
                didFinish: finishImport
            )
        }
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.movie]) { result in
            Task { @MainActor in
                let url: URL
                do {
                    url = try result.get()
                } catch {
                    finishImport(.failure(error))
                    return
                }
                feedback = nil
                isWorking = true
                let imported = await Task.detached(priority: .userInitiated) {
                    Result { try ImportedVideo.copyCoordinatedFile(at: url) }
                }.value
                finishImport(imported)
            }
        }
        .onDisappear { player?.pause() }
    }

    @MainActor
    private func finishImport(_ result: Result<ImportedVideo, Error>) {
        showsPhotoPicker = false
        isWorking = false
        switch result {
        case .success(let imported):
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            source?.remove()
            source = imported
            player = AVPlayer(url: imported.url)
        case .failure(let error):
            feedback = .error("无法导入视频。\(error.localizedDescription)")
        }
    }

    @MainActor
    private func convertAndSave() async {
        guard let source, !isWorking else { return }
        isWorking = true
        feedback = nil
        player?.pause()
        defer { isWorking = false }

        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                feedback = .error("请在 iPhone 设置中允许本 App 添加照片，然后重试。")
                return
            }

            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let result = try await LivePhotoConverter.convert(source.url, into: directory)
            let photoURL = result.photoURL
            let movieURL = result.movieURL
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: photoURL, options: nil)
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: nil)
            }
            feedback = .success("已保存到照片 App，可在「实况照片」中查看。")
        } catch {
            feedback = .error("转换或保存失败。\(error.localizedDescription)")
        }
    }

    private struct Feedback {
        let text: String
        let icon: String
        let color: Color

        static func success(_ text: String) -> Self {
            Self(text: text, icon: "checkmark.circle.fill", color: .primary)
        }

        static func error(_ text: String) -> Self {
            Self(text: text, icon: "exclamationmark.circle", color: .red)
        }
    }
}

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
